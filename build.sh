#!/usr/bin/env bash
#
# Build a ParkezeOS image for one board.
#
#   ./build.sh rpi4                 # one board
#   ./build.sh rpi3 rpi4            # several
#   ./build.sh --all                # every board in boards/
#   ./build.sh --list               # what is buildable
#   ./build.sh --list-json          # ...with targets, for CI
#
#   ./build.sh --stage console      # just the web console
#   ./build.sh --stage feed         # just the packages
#   ./build.sh --stage image rpi4   # just the image, using what is on disk
#
# The stages exist so CI can build the console and the packages once and share
# them across every board. Running without --stage does all three, which is
# what you want locally.
#
# On macOS the last step runs in a Linux container automatically — see
# reexec_for_assembly. You need Docker installed; nothing else changes.
#
# The heavy lifting is OpenWrt's ImageBuilder: it takes prebuilt packages for a
# pinned release and assembles a rootfs, which takes minutes rather than the
# hour a from-source buildroot run costs. Our own packages come from
# feed/ — built once per architecture into a local package repository that the
# ImageBuilder is pointed at.
#
# Nothing here is board-aware. Everything a board needs lives in
# boards/<id>/board.conf; if this script grows an `if [ "$BOARD" = ... ]` then
# the board abstraction has sprung a leak and the fix belongs there, not here.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOARDS_DIR="${ROOT_DIR}/boards"
FEED_DIR="${ROOT_DIR}/feed"
BUILD_DIR="${ROOT_DIR}/.build"
OUT_DIR="${ROOT_DIR}/out"

# Version stamped into the image so a running gateway can say what it is.
PARKEZE_VERSION="$(cat "${ROOT_DIR}/VERSION" 2>/dev/null || echo 0.0.0-dev)"
PARKEZE_BUILD="$(date -u +%Y%m%d%H%M)"
PARKEZE_COMMIT="$(git -C "${ROOT_DIR}" rev-parse --short HEAD 2>/dev/null || echo unknown)"

log()  { printf '\033[36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[33m warn\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31merror\033[0m %s\n' "$*" >&2; exit 1; }

list_boards() {
  find "${BOARDS_DIR}" -mindepth 1 -maxdepth 1 -type d ! -name common \
    -exec basename {} \; | sort
}

# Every board with the fields CI needs, as JSON.
#
# The target and subtarget are what an ImageBuilder download is keyed on, not
# the board — several boards can share one. Emitting them here means the
# workflow never has to parse board.conf itself, and a board whose target
# changes updates its own cache key without anybody editing the workflow.
list_boards_json() {
  local first=1
  printf '['
  for board in $(list_boards); do
    (
      # shellcheck disable=SC1090
      . "${BOARDS_DIR}/${board}/board.conf"
      printf '{"board":"%s","name":"%s","target":"%s","subtarget":"%s","arch":"%s","imagebuilder":"%s-%s-%s"}' \
        "${BOARD_ID}" "${BOARD_NAME}" "${OPENWRT_TARGET}" "${OPENWRT_SUBTARGET}" \
        "${OPENWRT_ARCH}" "${OPENWRT_VERSION}" "${OPENWRT_TARGET}" "${OPENWRT_SUBTARGET}"
    )
    [ "${first}" = 1 ] && first=0 || true
    [ "${board}" = "$(list_boards | tail -n1)" ] || printf ','
  done
  printf ']\n'
}

# ── ImageBuilder ────────────────────────────────────────────────────────────

imagebuilder_dir() {
  echo "${BUILD_DIR}/imagebuilder/${OPENWRT_VERSION}-${OPENWRT_TARGET}-${OPENWRT_SUBTARGET}"
}

fetch_imagebuilder() {
  local dir; dir="$(imagebuilder_dir)"
  [ -d "${dir}" ] && { log "ImageBuilder cached: ${OPENWRT_TARGET}/${OPENWRT_SUBTARGET}"; return; }

  local name="openwrt-imagebuilder-${OPENWRT_VERSION}-${OPENWRT_TARGET}-${OPENWRT_SUBTARGET}.Linux-x86_64"
  local url="https://downloads.openwrt.org/releases/${OPENWRT_VERSION}/targets/${OPENWRT_TARGET}/${OPENWRT_SUBTARGET}/${name}.tar.zst"
  local tarball="${BUILD_DIR}/${name}.tar.zst"

  log "Fetching ImageBuilder ${OPENWRT_VERSION} ${OPENWRT_TARGET}/${OPENWRT_SUBTARGET}"
  mkdir -p "${BUILD_DIR}/imagebuilder"
  curl -fL --retry 3 -o "${tarball}" "${url}" \
    || die "could not download ${url}"

  # Verify against the release's signed checksum list. An ImageBuilder is a
  # tree of executables that will run on this machine; taking it unverified
  # off a plain HTTP redirect is not acceptable even when the URL is https.
  verify_download "${tarball}" "${name}.tar.zst"

  mkdir -p "${dir}"
  tar --use-compress-program=unzstd -xf "${tarball}" -C "${dir}" --strip-components=1
  rm -f "${tarball}"
}

verify_download() {
  local file="$1" name="$2"
  local sums="${BUILD_DIR}/sha256sums-${OPENWRT_TARGET}-${OPENWRT_SUBTARGET}"
  curl -fsL -o "${sums}" \
    "https://downloads.openwrt.org/releases/${OPENWRT_VERSION}/targets/${OPENWRT_TARGET}/${OPENWRT_SUBTARGET}/sha256sums" \
    || die "could not fetch checksum list"

  local want got
  want="$(awk -v n="*${name}" '$2==n {print $1}' "${sums}")"
  [ -n "${want}" ] || die "no checksum published for ${name}"
  got="$(sha256sum "${file}" | cut -d' ' -f1)"
  [ "${want}" = "${got}" ] || die "checksum mismatch for ${name}"
  log "Checksum verified"
}

# ── Running the assembly step on a Mac ──────────────────────────────────────

# The tag for the assembly container. Bumped only when docker/Dockerfile
# changes; docker's own layer cache handles everything finer-grained.
DOCKER_IMAGE="parkeze-os-build:1"

can_assemble_here() {
  [ "$(uname -s)" = "Linux" ]
}

# Run a command with a deadline, and fail if it overruns.
#
# macOS has no `timeout(1)` — that is GNU coreutils, which is not installed by
# default — so this is the portable version. It matters here because
# `docker info` against a Docker Desktop that is installed but not running does
# not fail: the socket exists, nothing answers, and the CLI waits indefinitely.
# Without a deadline, `./build.sh` on a Mac with Docker stopped hangs after a
# successful console and feed build, which looks like the build itself wedged.
with_timeout() {
  local seconds="$1"; shift
  "$@" &
  local pid=$!
  local waited=0

  while kill -0 "${pid}" 2>/dev/null; do
    [ "${waited}" -ge "${seconds}" ] && {
      kill -TERM "${pid}" 2>/dev/null
      # A moment to exit cleanly before insisting.
      sleep 1
      kill -KILL "${pid}" 2>/dev/null
      wait "${pid}" 2>/dev/null
      return 124
    }
    sleep 1
    waited=$((waited + 1))
  done

  wait "${pid}"
}

# True when we are already the containerised half of a re-exec, so the
# container does not try to start another container.
in_container() {
  [ "${PARKEZE_IN_CONTAINER:-0}" = "1" ]
}

reexec_for_assembly() {
  # Hand the image assembly to a Linux container and come back.
  #
  # WHY ONLY THIS STEP
  #
  # The console build and the package feed run fine on macOS and have already
  # run by the time we get here. Re-execing the *whole* script would mean
  # rebuilding the console inside the container against a node_modules full of
  # darwin binaries — esbuild and rollup ship platform-specific executables —
  # which fails in a confusing way. So the host does what it can and the
  # container does only what it must.
  #
  # Everything the container needs is already on disk in the repo: the built
  # console sits in the package payload, the .ipk files and any cached
  # ImageBuilder in .build/. One bind mount covers all of it.
  local boards=("$@")

  command -v docker >/dev/null 2>&1 || {
    cat >&2 <<'EOF'
error: image assembly needs Linux, and Docker is not installed.

       OpenWrt's ImageBuilder ships prebuilt x86_64 ELF binaries with no macOS
       build, so the last step has to run in a Linux container.

       Install Docker Desktop, or run this script on a Linux machine. The
       console and the package feed built successfully either way — only the
       final assembly is blocked.
EOF
    exit 1
  }

  # Bounded, for the reason in with_timeout: an installed-but-stopped Docker
  # Desktop makes this wait forever rather than failing.
  if ! with_timeout 20 docker info >/dev/null 2>&1; then
    cat >&2 <<'EOF'
error: Docker is installed but its daemon is not responding.

       Start Docker Desktop and run this again. The console and the package
       feed have already been built, so a re-run picks up where this stopped.
EOF
    exit 1
  fi

  # Built, not pulled. Cached after the first run, so this is a no-op
  # afterwards and there is no registry to depend on.
  if ! docker image inspect "${DOCKER_IMAGE}" >/dev/null 2>&1; then
    log "Building the assembly container (one time, ~1 min)"
    # No timeout on this one: it genuinely takes a minute or two on a slow
    # connection, and a deadline long enough to be safe is not a useful
    # deadline. It fails loudly on its own if it cannot proceed.
    docker build --platform linux/amd64 \
      -t "${DOCKER_IMAGE}" -f "${ROOT_DIR}/docker/Dockerfile" "${ROOT_DIR}/docker" \
      || die "could not build the assembly container"
  fi

  log "Assembling in Docker (linux/amd64)"
  case "$(uname -m)" in
    arm64|aarch64)
      warn "Apple silicon: this runs x86_64 under emulation and is slow."
      warn "  Expect several minutes per board on the first run." ;;
  esac

  # PARKEZE_IN_CONTAINER stops the container re-entering this branch, and
  # --assemble-only skips the host-side steps that have already happened.
  #
  # Bind-mounting the repo means the .build cache and the out/ directory are
  # shared, so a second run reuses the downloaded ImageBuilder and the images
  # land where a native build would put them. On Docker Desktop for Mac the
  # files come back owned by the host user, so nothing needs chowning after.
  docker run --rm \
    --platform linux/amd64 \
    -v "${ROOT_DIR}:/src" \
    -w /src \
    -e PARKEZE_IN_CONTAINER=1 \
    -e PARKEZE_RECOVERY_PUBKEY \
    "${DOCKER_IMAGE}" \
    ./build.sh --stage image "${boards[@]}" \
    || die "assembly failed inside the container"

  log "Images: out/"
  exit 0
}

# ── The console ─────────────────────────────────────────────────────────────

CONSOLE_PAYLOAD="${ROOT_DIR}/feed/parkeze-console/files/www/parkeze"

build_console() {
  # The console is a React app built to static files. There is no Node on a
  # gateway — uhttpd serves the output and everything dynamic goes through the
  # ucode API — so this runs here, on the build host, and the result becomes
  # the parkeze-console package's payload.
  #
  # The payload directory is generated and gitignored. Building into the
  # package tree rather than into console/dist and copying afterwards means
  # there is exactly one place the packager can pick it up from, and no way to
  # ship a stale copy because the copy step was skipped.
  local src="${ROOT_DIR}/console"

  command -v node >/dev/null 2>&1 || die "node is required to build the console
       (v20 or newer). Install it, or build in the container the Linux check
       below prints."

  log "Building console"
  rm -rf "${CONSOLE_PAYLOAD}"
  mkdir -p "${CONSOLE_PAYLOAD}"

  # `npm ci` when there is a lockfile to honour, `npm install` on a fresh tree.
  # ci is the right default: a gateway image should not pick up a different
  # dependency tree than the one that was tested because somebody built it on a
  # Tuesday.
  if [ -f "${src}/package-lock.json" ]; then
    ( cd "${src}" && npm ci --silent --no-audit --no-fund )
  else
    warn "no package-lock.json — dependency versions are not pinned for this build"
    ( cd "${src}" && npm install --silent --no-audit --no-fund )
  fi

  ( cd "${src}" && PARKEZE_CONSOLE_OUT="${CONSOLE_PAYLOAD}" npm run build )

  [ -f "${CONSOLE_PAYLOAD}/index.html" ] \
    || die "the console build produced no index.html"

  log "Console: $(du -sh "${CONSOLE_PAYLOAD}" | cut -f1)"
}

# ── The fleet recovery anchor ───────────────────────────────────────────────

install_fleet_key() {
  # The fleet recovery *public* key, baked into the image.
  #
  # This is what lets a gateway verify a signed adoption bundle before it has
  # ever been adopted — the offline provisioning path — and it is why that path
  # is not simply "trust whatever somebody pastes in". It is a public key: there
  # is nothing sensitive about shipping it, and its private half never leaves
  # tailscale-service.
  #
  # Without it, an image can still be adopted online (where TLS is the
  # provenance) but a gateway that never reaches the internet can only be
  # adopted by trusting an unsigned blob, which we will not do. So the build
  # warns loudly rather than failing: a lab image with no key is a legitimate
  # thing to want, and a production one without it is not.
  local dest="${ROOT_DIR}/boards/common/files/etc/parkeze"
  local key="${PARKEZE_RECOVERY_PUBKEY:-${ROOT_DIR}/recovery_ed25519.pub}"

  rm -f "${dest}/recovery.pub"

  if [ ! -f "${key}" ]; then
    warn "No fleet recovery public key found at ${key}."
    warn "  Images from this build CANNOT be adopted offline, and gateways"
    warn "  adopted from them have no recovery anchor until they are online."
    warn "  Generate one with parkeze.net/tools/generate-recovery-key.sh and"
    warn "  point PARKEZE_RECOVERY_PUBKEY at the .pub half."
    return 0
  fi

  # Sanity-check it is what it claims to be before it goes in an image. A
  # truncated or wrong-algorithm key here produces gateways that fail
  # verification in the field, which is the worst place to find out.
  if command -v openssl >/dev/null 2>&1; then
    openssl pkey -pubin -in "${key}" -noout 2>/dev/null \
      || die "${key} is not a valid public key"
  fi

  mkdir -p "${dest}"
  cp "${key}" "${dest}/recovery.pub"
  chmod 0644 "${dest}/recovery.pub"
  log "Fleet recovery anchor installed"
}

# ── Our own packages ────────────────────────────────────────────────────────

wire_local_feed() {
  # Point this ImageBuilder at the repository build_feed just produced.
  #
  # The line is added idempotently and *before* the upstream `src` lines, so
  # that a Parkeze package always wins over a same-named package from
  # downloads.openwrt.org rather than losing a coin toss to it.
  #
  # `option check_signature` is then dropped, which turns signature checking
  # off for *every* repo in this file, upstream included — opkg has no
  # per-repo form of it. That is acceptable only because of what this file is:
  # a throwaway build tree, extracted from a tarball whose sha256 we already
  # verified against the release's published list in fetch_imagebuilder. The
  # integrity guarantee comes from that check, not from this one.
  #
  # The alternative is signing our own feed with usign and adding the key to
  # the ImageBuilder keyring, which keeps the option on. Worth doing if we ever
  # serve this feed over the network to real gateways — at that point the
  # packages are crossing a wire and a local checksum no longer covers them.
  local ib="$1"
  local conf="${ib}/repositories.conf"
  local line="src parkeze file:${BUILD_DIR}/packages"

  grep -qxF "${line}" "${conf}" && return 0
  sed -i.bak '/^src parkeze /d; /^option check_signature/d' "${conf}"
  printf '%s\n%s\n' "${line}" "$(cat "${conf}")" > "${conf}.new"
  mv "${conf}.new" "${conf}"
  rm -f "${conf}.bak"
}


build_feed() {
  # Every package in feed/ is architecture-independent shell, ucode and static
  # assets, so one build serves every board and the "all" architecture is
  # honest rather than a shortcut. A package that ever needs compiling must
  # declare its own arch and this function grows a per-arch loop.
  local repo="${BUILD_DIR}/packages"
  mkdir -p "${repo}"

  log "Building Parkeze feed"
  "${ROOT_DIR}/scripts/build-feed.sh" "${FEED_DIR}" "${repo}" \
    "${PARKEZE_VERSION}" "${PARKEZE_BUILD}" "${PARKEZE_COMMIT}"
}

# ── Per-board image ─────────────────────────────────────────────────────────

render_board_files() {
  # The `files/` tree ImageBuilder overlays onto the rootfs. Board values are
  # written as a single sourced config rather than substituted into a dozen
  # scripts, so that a running gateway can be inspected: `cat
  # /etc/parkeze/board.conf` tells you exactly what the image was built with.
  local files="$1"
  mkdir -p "${files}/etc/parkeze"

  {
    echo "# Generated by build.sh — do not edit on the device."
    echo "# Changing a value here does not reconfigure anything already applied;"
    echo "# it is a record of what this image was built as."
    echo "BOARD_ID='${BOARD_ID}'"
    echo "BOARD_NAME='${BOARD_NAME}'"
    echo "PARKEZE_VERSION='${PARKEZE_VERSION}'"
    echo "PARKEZE_BUILD='${PARKEZE_BUILD}'"
    echo "PARKEZE_COMMIT='${PARKEZE_COMMIT}'"
    echo "OPENWRT_VERSION='${OPENWRT_VERSION}'"
    for var in $(compgen -v | grep '^PARKEZE_' | sort); do
      case "${var}" in
        PARKEZE_VERSION|PARKEZE_BUILD|PARKEZE_COMMIT) continue ;;
      esac
      printf "%s='%s'\n" "${var}" "${!var}"
    done
  } > "${files}/etc/parkeze/board.conf"

  # A board may ship literal files of its own; they win over anything shared.
  [ -d "${BOARDS_DIR}/common/files" ] && cp -a "${BOARDS_DIR}/common/files/." "${files}/"
  [ -d "${BOARDS_DIR}/${BOARD_ID}/files" ] && cp -a "${BOARDS_DIR}/${BOARD_ID}/files/." "${files}/"
  return 0
}

build_board() {
  local board="$1"
  local conf="${BOARDS_DIR}/${board}/board.conf"
  [ -f "${conf}" ] || die "unknown board '${board}' (try --list)"

  # Each board is read in a subshell so one board's overrides cannot leak into
  # the next when several are built in one invocation.
  (
    # shellcheck disable=SC1090
    . "${conf}"

    : "${OPENWRT_PROFILE:?board.conf must set OPENWRT_PROFILE}"
    log "Building ${BOARD_NAME} (${BOARD_ID}) — ${OPENWRT_TARGET}/${OPENWRT_SUBTARGET}"

    fetch_imagebuilder

    local ib files
    ib="$(imagebuilder_dir)"
    wire_local_feed "${ib}"
    files="${BUILD_DIR}/files-${BOARD_ID}"
    rm -rf "${files}"; mkdir -p "${files}"
    render_board_files "${files}"

    # Package list: shared, then board, then the removals as `-name` entries,
    # all flattened onto one line because ImageBuilder wants it that way.
    local packages
    packages="$(echo "${PACKAGES_COMMON} ${PACKAGES_BOARD:-}" | tr -s '[:space:]' ' ')"
    for pkg in ${PACKAGES_REMOVE}; do packages="${packages} -${pkg}"; done

    mkdir -p "${OUT_DIR}/${BOARD_ID}"

    make -C "${ib}" image \
      PROFILE="${OPENWRT_PROFILE}" \
      PACKAGES="${packages}" \
      FILES="${files}" \
      EXTRA_IMAGE_NAME="parkeze-${PARKEZE_VERSION}" \
      BIN_DIR="${OUT_DIR}/${BOARD_ID}" \
      -j"$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)"

    log "Images: out/${BOARD_ID}/"
    ls -1 "${OUT_DIR}/${BOARD_ID}"/*.img.gz 2>/dev/null || true
  )
}

# ── Entry point ─────────────────────────────────────────────────────────────

main() {
  local boards=()
  # all | console | feed | image. CI runs them as separate jobs so the console
  # and the packages are built once and shared by every board, rather than
  # rebuilt five times; a developer runs them together and never sees this.
  local stage=all

  if [ "${1:-}" = "--stage" ]; then
    stage="${2:?--stage needs a name: console, feed or image}"
    case "${stage}" in
      console|feed|image) ;;
      *) die "unknown stage '${stage}' (console, feed, image)" ;;
    esac
    shift 2
  elif [ "${1:-}" = "--assemble-only" ]; then
    # The name reexec_for_assembly used before stages existed. Kept because a
    # container started by an older checkout may still invoke it.
    stage=image
    shift
  fi

  case "${1:-}" in
    --list)      list_boards; exit 0 ;;
    --list-json) list_boards_json; exit 0 ;;
    # `mapfile` is bash 4 and macOS ships bash 3.2, so --all silently did
    # nothing there. A read loop works on both.
    --all)       while IFS= read -r b; do boards+=("${b}"); done < <(list_boards) ;;
    -h|--help)
      sed -n '2,24p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    '')
      # No board is fine for the stages that do not need one.
      case "${stage}" in
        console|feed) ;;
        *) sed -n '2,24p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
      esac ;;
    *) boards=("$@") ;;
  esac

  command -v curl >/dev/null || die "curl is required"
  command -v unzstd >/dev/null || die "zstd is required (brew install zstd)"


  mkdir -p "${BUILD_DIR}" "${OUT_DIR}"
  export BOARDS_DIR

  case "${stage}" in
    console)
      build_console
      log "Done. Console only."
      return 0 ;;
    feed)
      # The fleet key is part of the rootfs overlay, not the packages, but it
      # costs nothing and keeps `--stage feed` a complete "everything that is
      # not assembly" step for a CI job that has the secret.
      install_fleet_key
      build_feed
      log "Done. Feed only."
      return 0 ;;
    image)
      # Re-run in a fresh CI job, so the overlay has to be reconstructed even
      # though the console and packages arrived as artifacts.
      install_fleet_key ;;
    all)
      build_console
      install_fleet_key
      build_feed ;;
  esac

  [ "${#boards[@]}" -gt 0 ] || die "no board given"

  # On a Mac the console and the feed are done; hand the rest to a container
  # and do not come back.
  if ! can_assemble_here && ! in_container; then
    reexec_for_assembly "${boards[@]}"
  fi

  for board in "${boards[@]}"; do build_board "${board}"; done

  log "Done. ParkezeOS ${PARKEZE_VERSION} (${PARKEZE_COMMIT})"
}

main "$@"
