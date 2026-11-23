#!/usr/bin/env bash
#
# Build a PulzrOS image for one board.
#
#   ./build.sh rpi4                 # one board
#   ./build.sh rpi3 rpi4            # several
#   ./build.sh --all                # every board in boards/
#   ./build.sh --list               # what is buildable
#   ./build.sh --list-json          # ...with targets, for CI
#   ./build.sh --sdk-targets        # the targets sdk/build.sh builds, for CI
#
#   ./build.sh --stage console      # just the web console
#   ./build.sh --stage feed         # just the packages
#   ./build.sh --stage image rpi4   # just the image, using what is on disk
#   ./build.sh --stage addons       # the signed add-on repository, from the staged feed
#
#   PULZR_DEV=1 ./build.sh rpi4   # a development image, for the bench
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
PULZR_VERSION="$(cat "${ROOT_DIR}/VERSION" 2>/dev/null || echo 0.0.0-dev)"

# A development image: what a production image locks away from whoever is
# standing at the gateway, left open for whoever is building it. The serial
# console's root shell, failsafe mode, the TUI's `!` for any signed-in
# session, site keys from the card, and every key in boards/common/ssh/dev/.
# Its version says -dev everywhere it is shown, Pulzr Cloud included, and CI
# refuses to build one, so a release can never be one. render_board_files
# records it in board.conf, which is what the gateway reads.
if [ "${PULZR_DEV:-0}" = 1 ]; then
  if [ "${GITHUB_ACTIONS:-}" = true ]; then
    echo "PULZR_DEV=1 is a bench build; CI builds releases, and a release is never one." >&2
    exit 1
  fi
  PULZR_VERSION="${PULZR_VERSION}-dev"
fi
# The build stamp, every package's revision. A CI run stages the feed in
# several jobs (build.yml) and passes the first job's stamp to the rest, so one
# release's packages carry one stamp.
PULZR_BUILD="${PULZR_BUILD:-$(date -u +%Y%m%d%H%M)}"
PULZR_COMMIT="$(git -C "${ROOT_DIR}" rev-parse --short HEAD 2>/dev/null || echo unknown)"

log()  { printf '\033[36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[33m warn\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31merror\033[0m %s\n' "$*" >&2; exit 1; }

# Every board directory, buildable or not.
all_boards() {
  find "${BOARDS_DIR}" -mindepth 1 -maxdepth 1 -type d ! -name common \
    -exec basename {} \; | sort
}

board_status() {
  ( . "${BOARDS_DIR}/${1}/board.conf" >/dev/null 2>&1
    echo "${BOARD_STATUS:-supported}" )
}

# Boards that can actually be built. `--all` and CI use this, so a board with
# no upstream device support does not turn the whole run red.
list_boards() {
  for board in $(all_boards); do
    [ "$(board_status "${board}")" = "supported" ] && echo "${board}"
  done
  return 0
}

# Every board with the fields CI needs, as JSON.
#
# The target and subtarget are what an ImageBuilder download is keyed on, not
# the board — several boards can share one. Emitting them here means the
# workflow never has to parse board.conf itself, and a board whose target
# changes updates its own cache key without anybody editing the workflow.
# The OpenWrt targets sdk/build.sh builds for, one <target>/<subtarget> per
# line: every board's, except a target only a board's own device support
# builds (boards/<board>/openwrt/graft: the GL-SFT1200's siflower), for which
# OpenWrt publishes no SDK. CI builds one SDK job per line (prebuilt.yml).
#
# These two lookups are here, not in sdk/: sdk/key hashes every file there,
# and which boards exist is not what the SDK builds. A board added, or one
# that takes an add-on, costs no SDK rebuild.
sdk_targets() {
  local conf
  for conf in "${BOARDS_DIR}"/*/board.conf; do
    [ "${conf}" = "${BOARDS_DIR}/common/board.conf" ] && continue
    # shellcheck disable=SC1090
    ( . "${conf}"
      [ -n "${OPENWRT_DEVICE_SUPPORT:-}" ] && [ -f "${BOARDS_DIR}/${OPENWRT_DEVICE_SUPPORT}/openwrt/graft" ] && exit 0
      echo "${OPENWRT_TARGET}/${OPENWRT_SUBTARGET}" )
  done | sort -u
}

# The SDK build a board on <arch> takes its binaries from (pulzr-probe,
# pulzr-edge, busybox): the sdk_targets target on that arch, and for the
# GL-SFT1200's mipsel_24kc_24kf the soft-float mipsel_24kc one, as
# feed/pulzr-probe/fetch takes.
sdk_target_for() {
  local arch="$1" t conf
  case "${arch}" in mipsel_24kc_24kf) arch=mipsel_24kc ;; esac
  for t in $(sdk_targets); do
    for conf in "${BOARDS_DIR}"/*/board.conf; do
      [ "${conf}" = "${BOARDS_DIR}/common/board.conf" ] && continue
      # shellcheck disable=SC1090
      if ( . "${conf}"; [ "${OPENWRT_TARGET}/${OPENWRT_SUBTARGET}" = "${t}" ] && [ "${OPENWRT_ARCH}" = "${arch}" ] ); then
        echo "${t}"; return 0
      fi
    done
  done
  return 1
}

list_boards_json() {
  local first=1
  printf '['
  for board in $(all_boards); do
    (
      # shellcheck disable=SC1090
      . "${BOARDS_DIR}/${board}/board.conf"
      # sdk: the SDK build its binaries come from (sdk_target_for), and
      # that build's cache key (sdk/key).
      local sdk; sdk="$(sdk_target_for "${OPENWRT_ARCH}")" || die "no SDK target builds ${OPENWRT_ARCH} (sdk_targets)"
      printf '{"board":"%s","name":"%s","status":"%s","target":"%s","subtarget":"%s","arch":"%s","imagebuilder":"%s","device":"%s","deviceKey":"%s","sdk":"%s","sdkKey":"%s"}' \
        "${BOARD_ID}" "${BOARD_NAME}" "${BOARD_STATUS:-supported}" \
        "${OPENWRT_TARGET}" "${OPENWRT_SUBTARGET}" \
        "${OPENWRT_ARCH}" "$(imagebuilder_id)" "${OPENWRT_DEVICE_SUPPORT:-}" \
        "$( [ -n "${OPENWRT_DEVICE_SUPPORT:-}" ] && device_key || true)" \
        "${sdk}" "$("${ROOT_DIR}/sdk/key" "${sdk}")"
    )
    [ "${first}" = 1 ] && first=0 || true
    [ "${board}" = "$(all_boards | tail -n1)" ] || printf ','
  done
  printf ']\n'
}

# ── ImageBuilder ────────────────────────────────────────────────────────────

# Where the ImageBuilder and its sha256sums come from: downloads.openwrt.org,
# or for a board OpenWrt does not support yet, the one built from its device
# support in boards/<OPENWRT_DEVICE_SUPPORT>/openwrt/ by
# scripts/device-imagebuilder.sh, into .build/device-ib/<that board>/. CI
# builds it once per change to those files (build.yml); a local build of such
# a board needs it built first, which takes Linux and a couple of hours.
imagebuilder_base() {
  if [ -n "${OPENWRT_DEVICE_SUPPORT:-}" ]; then
    echo "file://${BUILD_DIR}/device-ib/${OPENWRT_DEVICE_SUPPORT}"
  else
    echo "https://downloads.openwrt.org/releases/${OPENWRT_VERSION}/targets/${OPENWRT_TARGET}/${OPENWRT_SUBTARGET}"
  fi
}

# What a board's device-support ImageBuilder is built from: the release, its
# boards/<board>/openwrt/ and the scripts that build it. The CI cache key for
# that build, and part of the id below, so a change to any of them is a new
# ImageBuilder everywhere.
device_key() {
  local dir="${BOARDS_DIR}/${OPENWRT_DEVICE_SUPPORT}/openwrt"
  { echo "${OPENWRT_VERSION}"
    ( cd "${ROOT_DIR}" && find "boards/${OPENWRT_DEVICE_SUPPORT}/openwrt" scripts/device-imagebuilder.sh \
        scripts/device-imagebuilder-graft.sh -type f | LC_ALL=C sort | xargs sha256sum ); } \
    | sha256sum | cut -c1-12
  [ -d "${dir}" ] || return 1
}

# Distinct per source, so the stock and a device-support ImageBuilder for the
# same target sit side by side rather than one shadowing the other, and the
# RAK7268CV2's and RAK7289CV2's, both ramips/mt76x8, do not shadow each other.
imagebuilder_id() {
  local source=""
  if [ -n "${OPENWRT_DEVICE_SUPPORT:-}" ]; then
    source="${OPENWRT_DEVICE_SUPPORT}-$(device_key)"
  fi
  echo "${OPENWRT_VERSION}-${OPENWRT_TARGET}-${OPENWRT_SUBTARGET}${source:+-${source}}"
}

imagebuilder_dir() {
  echo "${BUILD_DIR}/imagebuilder/$(imagebuilder_id)"
}

fetch_imagebuilder() {
  local dir; dir="$(imagebuilder_dir)"
  [ -d "${dir}" ] && { log "ImageBuilder cached: ${OPENWRT_TARGET}/${OPENWRT_SUBTARGET}"; return; }

  local name="openwrt-imagebuilder-${OPENWRT_VERSION}-${OPENWRT_TARGET}-${OPENWRT_SUBTARGET}.Linux-x86_64"
  local url="$(imagebuilder_base)/${name}.tar.zst"
  local tarball="${BUILD_DIR}/${name}.tar.zst"

  log "Fetching ImageBuilder ${OPENWRT_VERSION} ${OPENWRT_TARGET}/${OPENWRT_SUBTARGET}"
  mkdir -p "${BUILD_DIR}/imagebuilder"
  if ! curl -fL --retry 3 -o "${tarball}" "${url}"; then
    [ -z "${OPENWRT_DEVICE_SUPPORT:-}" ] || die "no ImageBuilder for ${OPENWRT_DEVICE_SUPPORT}'s device support in ${BUILD_DIR}/device-ib/${OPENWRT_DEVICE_SUPPORT}; build it with scripts/device-imagebuilder.sh ${OPENWRT_DEVICE_SUPPORT} ${BUILD_DIR}/device-ib/${OPENWRT_DEVICE_SUPPORT}"
    die "could not download ${url}"
  fi

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
  local sums="${BUILD_DIR}/sha256sums-$(imagebuilder_id)"
  curl -fsL -o "${sums}" "$(imagebuilder_base)/sha256sums" \
    || die "could not fetch checksum list"

  local want got
  want="$(awk -v n="*${name}" '$2==n {print $1}' "${sums}")"
  [ -n "${want}" ] || die "no checksum published for ${name}"
  got="$(sha256sum "${file}" | cut -d' ' -f1)"
  [ "${want}" = "${got}" ] || die "checksum mismatch for ${name}"
  log "Checksum verified"
}

# ── Running the assembly step on a Mac ──────────────────────────────────────

# The tag for the assembly container. Bumped only when assembly_dockerfile
# changes; docker's own layer cache handles everything finer-grained.
DOCKER_IMAGE="pulzr-os-build:1"

# The image-assembly container, only needed on macOS. OpenWrt's ImageBuilder is
# a tree of prebuilt x86_64 ELF binaries with no macOS build, so the parts that
# work natively (the console, the feed) run on the host and only the final
# assembly re-execs in here. A Dockerfile rather than `docker run debian
# apt-get ...` so the install is cached: the first build takes a minute and
# every one after starts at once. No Node: the console is built on the host by
# then, and its node_modules hold darwin binaries that would not run here.
#
# GNU awk and distutils because ImageBuilder's prereq check wants both
# (bookworm-slim ships mawk); libncurses for the menuconfig machinery `make
# image` touches. The remaining prereq, a case-sensitive filesystem, cannot
# hold on a macOS bind mount, so make gets FORCE=1.
assembly_dockerfile() {
  cat <<'EOF'
FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential libncurses-dev zstd unzip gzip file wget curl \
        ca-certificates git python3 python3-distutils gawk rsync binutils \
        openssl perl \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /src
EOF
}

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
  [ "${PULZR_IN_CONTAINER:-0}" = "1" ]
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
  # console sits in the package payload, the staged feed and any cached
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
    assembly_dockerfile | docker build --platform linux/amd64 -t "${DOCKER_IMAGE}" - \
      || die "could not build the assembly container"
  fi

  log "Assembling in Docker (linux/amd64)"
  case "$(uname -m)" in
    arm64|aarch64)
      warn "Apple silicon: this runs x86_64 under emulation and is slow."
      warn "  Expect several minutes per board on the first run." ;;
  esac

  # PULZR_IN_CONTAINER stops the container re-entering this branch, and
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
    -e PULZR_IN_CONTAINER=1 \
    -e PULZR_RECOVERY_PUBKEY \
    -e PULZR_DEV \
    "${DOCKER_IMAGE}" \
    ./build.sh --stage image "${boards[@]}" \
    || die "assembly failed inside the container"

  log "Images: out/"
  exit 0
}

# ── The console ─────────────────────────────────────────────────────────────

CONSOLE_PAYLOAD="${ROOT_DIR}/feed/pulzr-console/files/www/pulzr"

build_console() {
  # The console is a React app built to static files. There is no Node on a
  # gateway — uhttpd serves the output and everything dynamic goes through the
  # ucode API — so this runs here, on the build host, and the result becomes
  # the pulzr-console package's payload.
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

  # `npm ci` when there is a lockfile to honor, `npm install` on a fresh tree.
  # ci is the right default: a gateway image should not pick up a different
  # dependency tree than the one that was tested because somebody built it on a
  # Tuesday.
  if [ -f "${src}/package-lock.json" ]; then
    ( cd "${src}" && npm ci --silent --no-audit --no-fund )
  else
    warn "no package-lock.json — dependency versions are not pinned for this build"
    ( cd "${src}" && npm install --silent --no-audit --no-fund )
  fi

  ( cd "${src}" && PULZR_CONSOLE_OUT="${CONSOLE_PAYLOAD}" npm run build )

  [ -f "${CONSOLE_PAYLOAD}/index.html" ] \
    || die "the console build produced no index.html"

  # uhttpd has no gzip support of its own — checked the binary, nothing there
  # for Content-Encoding or a .gz sidecar. assets.uc serves these directly
  # when the browser sends Accept-Encoding: gzip, and falls back to the plain
  # file otherwise, so shipping the .gz costs nothing on a client that can't
  # use it. -k keeps the original; -f overwrites a stale .gz from a previous
  # build of the same file.
  if command -v gzip >/dev/null 2>&1; then
    find "${CONSOLE_PAYLOAD}/assets" -type f \( -name '*.js' -o -name '*.css' \) \
      -exec gzip -9 -k -f {} \;
  else
    warn "no gzip on this host — the console will ship without precompressed assets"
  fi

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
  # recovery-service.
  #
  # Without it, an image can still be adopted online (where TLS is the
  # provenance) but a gateway that never reaches the internet can only be
  # adopted by trusting an unsigned blob, which we will not do. So the build
  # warns loudly rather than failing: a lab image with no key is a legitimate
  # thing to want, and a production one without it is not.
  local dest="${ROOT_DIR}/boards/common/files/etc/pulzr"
  local key="${PULZR_RECOVERY_PUBKEY:-${ROOT_DIR}/recovery_ed25519.pub}"

  # `--stage image` runs in a fresh CI job: the overlay arrived as an artifact
  # from the feed stage, which already put the anchor in it, and the secret is
  # deliberately not in that job's environment. Deleting it there and then
  # warning is how a build that HAS the anchor still ships images without one
  # — which is what every rpi3/rpi4 job did until this check existed.
  if [ ! -f "${key}" ] && [ -f "${dest}/recovery.pub" ]; then
    log "Fleet recovery anchor already in the overlay"
    return 0
  fi

  rm -f "${dest}/recovery.pub"

  if [ ! -f "${key}" ]; then
    warn "No fleet recovery public key found at ${key}."
    warn "  Images from this build CANNOT be adopted offline, and gateways"
    warn "  adopted from them have no recovery anchor until they are online."
    warn "  Generate an Ed25519 pair, keep the private half in your platform,"
    warn "  and point PULZR_RECOVERY_PUBKEY at the .pub half."
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

install_firmware_key() {
  # The firmware signing *public* key, baked into the image.
  #
  # What makes a gateway able to answer "did Pulzr build this image" before
  # it writes one over itself. The private half lives in Actions secrets and
  # signs a manifest beside each released image — tools/sign-firmware.sh —
  # and pulzr-firmware verifies it on the device.
  #
  # A separate key from the recovery anchor above, on purpose: that one's
  # whole value is that its private half never leaves recovery-service, and
  # firmware signing needs a key CI can reach. See
  # tools/generate-firmware-key.sh for the reasoning.
  #
  # Warns rather than failing, same as the recovery anchor and for the same
  # reason: a lab image built without it is a legitimate thing to want. What
  # it cannot do is silently produce images that *look* verifiable — a
  # gateway with no key refuses to verify rather than waving images through.
  local dest="${ROOT_DIR}/boards/common/files/etc/pulzr"
  local key="${PULZR_FIRMWARE_PUBKEY:-${ROOT_DIR}/firmware_ed25519.pub}"

  # Same reconstruction rule as the recovery anchor: `--stage image` runs in a
  # fresh job whose overlay arrived as an artifact that already has this.
  if [ ! -f "${key}" ] && [ -f "${dest}/firmware.pub" ]; then
    log "Firmware signing key already in the overlay"
    return 0
  fi

  rm -f "${dest}/firmware.pub"

  if [ ! -f "${key}" ]; then
    warn "No firmware signing public key found at ${key}."
    warn "  Gateways from this build CANNOT check whether an image is ours,"
    warn "  and will refuse to verify rather than trust one."
    warn "  Generate one with tools/generate-firmware-key.sh and point"
    warn "  PULZR_FIRMWARE_PUBKEY at the .pub half."
    return 0
  fi

  if command -v openssl >/dev/null 2>&1; then
    openssl pkey -pubin -in "${key}" -noout 2>/dev/null \
      || die "${key} is not a valid public key"
  fi

  mkdir -p "${dest}"
  cp "${key}" "${dest}/firmware.pub"
  chmod 0644 "${dest}/firmware.pub"
  log "Firmware signing key installed"
}

install_ops_keys() {
  # The fleet SSH public key, baked into the image.
  #
  # So that a freshly flashed gateway is reachable immediately, with no step at
  # the bench: no password to read off the card, no key to copy, nothing to
  # type. Flash it, power it, ssh in.
  #
  # These are PUBLIC keys. There is nothing sensitive in the image.
  #
  # The private half belongs to the platform operator, not to a person, and
  # is held by the cloud. So access follows whoever operates the platform rather
  # than whoever happened to build the firmware, and no laptop key ever ships
  # in a firmware image.
  #
  # ── THE TRADE, STATED PLAINLY ──────────────────────────────────────────────
  #
  # This is a fleet-wide credential, which is the same shape of risk as the
  # pulzr/pulzr default the previous PulzrOS shipped: whoever holds a
  # private half is root on every gateway built with its public half.
  #
  # It is a much better version of that trade, not an escape from it. A private
  # key does not leak the way a password in a README leaks — it is never typed,
  # never pasted into a ticket, never read aloud over a phone — and rotating it
  # is a rebuild rather than a fleet-wide password change. But it is still one
  # secret standing in front of every unit, so:
  #
  #   - keep ssh/fleet/ to the platform key, not to individuals
  #   - rotating is cheap and deliberate so: new pair, rebuild, push the new
  #     authorized_keys over the management tunnel with the old key. Unlike the fleet
  #     recovery key this needs no re-adoption
  #   - PULZR_OPS_KEYS=0 omits the file entirely for a build that should
  #     have no fleet access at all
  #   - it is not a substitute for the per-unit password, which is what an
  #     installer in the field uses; both exist because they answer to
  #     different people
  local keydir="${PULZR_OPS_KEYS_DIR:-${ROOT_DIR}/boards/common/ssh/fleet}"
  # NOT /etc/dropbear/authorized_keys. A file shipped under /etc is a package
  # conffile, and sysupgrade keeps conffiles — so the key a gateway was
  # flashed with survived every upgrade that carried a new one, and rotating
  # the fleet key silently did nothing to the fleet. This lands on /usr, which
  # sysupgrade replaces whole, and pulzr-fleet-keys composes the real
  # authorized_keys from it at boot.
  local sharedir="${ROOT_DIR}/boards/common/files/usr/share/pulzr"
  local fleet="${sharedir}/fleet-keys"

  rm -f "${fleet}"

  if [ "${PULZR_OPS_KEYS:-1}" != "1" ]; then
    log "Fleet SSH key omitted (PULZR_OPS_KEYS=0)"
    return 0
  fi

  local found=0 ca_blob=""
  ca_blob="$(awk '{ print $2; exit }' "${PULZR_SSH_CA_PUBKEY:-${ROOT_DIR}/boards/common/ssh/pulzr_user_ca.pub}" 2>/dev/null || true)"
  mkdir -p "${sharedir}"
  for pub in "${keydir}"/*.pub; do
    [ -f "${pub}" ] || continue
    # Checked before it goes in an image. A truncated key here does not fail,
    # it silently produces gateways nobody can log into — found out at the
    # bench, or worse, in the field.
    if ! grep -qE '^(ssh-(rsa|ed25519)|ecdsa-sha2-)' "${pub}"; then
      warn "${pub} holds no recognisable public key; skipped"
      continue
    fi
    # The SSH CA is not a login key. In authorized_keys its private half would
    # open every gateway directly, which is the one thing certificates exist
    # to stop; Pulzr Cloud's generator once said to copy it here.
    if [ -n "${ca_blob}" ] && awk '{ print $2 }' "${pub}" | grep -qxF "${ca_blob}"; then
      die "${pub} is the SSH CA, not a login key. It belongs in ${ROOT_DIR}/boards/common/ssh/."
    fi
    cat "${pub}" >> "${fleet}"
    found=$((found + 1))
  done

  if [ "${found}" -eq 0 ]; then
    rm -f "${fleet}"
    warn "No fleet SSH key in ${keydir}."
    warn "  Root on gateways from this build takes a certificate from your"
    warn "  platform's SSH CA: root has no password. Put the operator's"
    warn "  fleet .pub in ${keydir} to have them accept it straight from a flash."
    return 0
  fi

  chmod 0600 "${fleet}"
  log "Fleet SSH key installed (${found})"
}

install_dev_keys() {
  # A development image's own keys: every boards/common/ssh/dev/*.pub, for the
  # people at the bench. Added to the fleet keys, so root's authorized_keys
  # takes them as it takes Pulzr's. Ignored in .gitignore, because they are people's,
  # and never read for a production image.
  [ "${PULZR_DEV:-0}" = 1 ] || return 0
  local fleet="${ROOT_DIR}/boards/common/files/usr/share/pulzr/fleet-keys" found=0 pub ca_blob
  ca_blob="$(awk '{ print $2; exit }' "${PULZR_SSH_CA_PUBKEY:-${ROOT_DIR}/boards/common/ssh/pulzr_user_ca.pub}" 2>/dev/null || true)"
  for pub in "${ROOT_DIR}/boards/common/ssh/dev"/*.pub; do
    [ -f "${pub}" ] || continue
    grep -qE '^(ssh-(rsa|ed25519)|ecdsa-sha2-)' "${pub}" || { warn "${pub} holds no public key; skipped"; continue; }
    # As install_ops_keys refuses it: the CA in authorized_keys is every gateway.
    if [ -n "${ca_blob}" ] && awk '{ print $2 }' "${pub}" | grep -qxF "${ca_blob}"; then
      die "${pub} is the SSH CA, not a login key."
    fi
    mkdir -p "$(dirname "${fleet}")"
    cat "${pub}" >> "${fleet}"
    found=$((found + 1))
  done
  [ -f "${fleet}" ] && chmod 0600 "${fleet}"
  log "Development image: ${found} key(s) from boards/common/ssh/dev"
}

install_ssh_ca() {
  # The SSH certificate authority's *public* line, baked into the image.
  #
  # Pulzr Cloud reaches a gateway's shell with a certificate it signs for that
  # one gateway, for five minutes; a gateway accepts it because it trusts this
  # line (pulzr-ssh-setup). Public, and committed beside the fleet key for
  # the same reason the fleet key is: which key opens a gateway is part of
  # what an image is. Its private half is recovery-service's.
  #
  # On /usr, as the fleet key is, so a rotated CA reaches a gateway with the
  # firmware rather than being kept as a conffile from the image before.
  #
  # Warns rather than failing: an image without it is reached with the fleet
  # key, as every image before it was.
  local key="${PULZR_SSH_CA_PUBKEY:-${ROOT_DIR}/boards/common/ssh/pulzr_user_ca.pub}"
  local dest="${ROOT_DIR}/boards/common/files/usr/share/pulzr/ssh"

  rm -f "${dest}/pulzr_user_ca.pub"

  if [ ! -f "${key}" ]; then
    warn "No SSH CA public key at ${key}."
    warn "  Gateways from this build accept no certificates, only the fleet key."
    warn "  Copy your platform's SSH CA public line there."
    return 0
  fi

  # One ssh-ed25519 line: that is all recovery-service signs with, and a
  # second line would be a second CA every gateway trusts.
  if [ "$(grep -c . "${key}")" != 1 ] \
     || ! grep -qE '^ssh-ed25519 [A-Za-z0-9+/]+=* ?' "${key}"; then
    die "${key} is not one ssh-ed25519 public key line"
  fi

  mkdir -p "${dest}"
  cp "${key}" "${dest}/pulzr_user_ca.pub"
  chmod 0644 "${dest}/pulzr_user_ca.pub"
  log "SSH CA installed"
}

# ── Our own packages ────────────────────────────────────────────────────────

pack_feed() {
  # Pack the staged feed into .apk files with this ImageBuilder's own apk, into
  # its packages/ directory.
  #
  # `make image` indexes that directory and signs the index with the
  # ImageBuilder's local key, generated on first use and kept in its keys/,
  # which is also where it looks for the keys it trusts. So every repository
  # stays signature-checked, ours included, and nothing is switched off to let
  # our packages in. The key never reaches an image: only ADD_LOCAL_KEY=1
  # copies it into /etc/apk/keys, and nothing on a gateway installs from this
  # feed.
  #
  # Under the ImageBuilder's fakeroot, as OpenWrt packs its own: apk records
  # each file's owner, and outside it every file would belong to whoever ran
  # the build. sshd refuses an authorized_keys it does not trust the owner of.
  local ib="$1"
  local stage="${BUILD_DIR}/feed"
  local host="${ib}/staging_dir/host"
  local apk="${host}/bin/apk"
  [ -x "${apk}" ] || die "this ImageBuilder has no apk; OpenWrt ${OPENWRT_VERSION} is not an apk release"

  local tar name arch tmp
  for tar in "${stage}"/*.tar; do
    [ -f "${tar}" ] || die "no staged feed in ${stage}; run ./build.sh --stage feed"
    name="$(basename "${tar}" .tar)"; arch="${name#*_}"; name="${name%%_*}"
    [ "${arch}" = noarch ] || [ "${arch}" = "${OPENWRT_ARCH}" ] || continue

    # An ImageBuilder is cached between builds, and a stale build of one of
    # ours beside a new one is two candidates for the same name.
    rm -f "${ib}/packages/${name}"-[0-9]*.apk

    tmp="$(mktemp -d)"
    tar -xf "${tar}" -C "${tmp}"
    local info=()
    while IFS= read -r line; do info+=(--info "${line}"); done < "${tmp}/info"
    PATH="${host}/bin:${PATH}" "${host}/bin/fakeroot" \
      -l "${host}/lib/libfakeroot.so" -f "${host}/bin/faked" -- \
      "${apk}" mkpkg "${info[@]}" --files "${tmp}/data" \
        --output "${ib}/packages/${name}-$(sed -n 's/^version://p' "${tmp}/info").apk" \
      || die "apk could not pack ${name}"
    rm -rf "${tmp}"
  done

  # The LoRa packages and busybox, built already with the OpenWrt SDK
  # (sdk/build.sh). busybox first and on every board the SDK built for: it is
  # OpenWrt's own, with the shell's login banner compiled out, and takes the
  # place of the release's (verify_rootfs checks it did). A board the SDK does
  # not build for, the GL-SFT1200, builds the same busybox in its own tree
  # (scripts/device-imagebuilder-graft.sh), which is already in packages/.
  # The LoRa packages are there for pulzr-lorawan's Depends, so a board that
  # carries it built in must have them.
  local sdk="${BUILD_DIR}/sdk/${OPENWRT_ARCH}" apk
  if ls "${sdk}"/busybox-[0-9]*.apk >/dev/null 2>&1; then
    rm -f "${ib}/packages"/busybox-[0-9]*.apk
    cp "${sdk}"/busybox-[0-9]*.apk "${ib}/packages/"
  fi
  rm -f "${ib}/packages"/chirpstack-*.apk "${ib}/packages"/libloragw-*.apk
  addon_builtin pulzr-lorawan || return 0
  ls "${sdk}"/chirpstack-*.apk >/dev/null 2>&1 \
    || die "no LoRa packages for ${OPENWRT_ARCH} in ${sdk}; build them with sdk/build.sh ${OPENWRT_TARGET}/${OPENWRT_SUBTARGET} ${BUILD_DIR}/sdk"
  for apk in "${sdk}"/*.apk; do
    case "$(basename "${apk}")" in busybox-[0-9]*) continue ;; esac
    cp "${apk}" "${ib}/packages/"
  done
}


build_feed() {
  # Staged, not packed: see build-feed.sh for why the packing waits for an
  # ImageBuilder. Nearly everything is noarch, so one stage serves every board;
  # ChirpStack's binaries are staged once per architecture.
  local stage="${BUILD_DIR}/feed"
  mkdir -p "${stage}"

  # Anything that is not a bench build ships compiled ucode, which needs a
  # compiler at the gateway's exact ucode version. See scripts/harden-payload.sh.
  local ucode=""
  if [ "${PULZR_DEV:-0}" != 1 ]; then
    ucode="$("${ROOT_DIR}/scripts/host-ucode.sh")" \
      || die "no host ucode to compile the feed with (needs cmake and json-c)"
  fi

  log "Staging Pulzr feed${PULZR_FEED_ARCHES:+ (${PULZR_FEED_ARCHES})}"
  UCODE="${ucode}" "${ROOT_DIR}/scripts/build-feed.sh" "${FEED_DIR}" "${stage}" \
    "${PULZR_VERSION}" "${PULZR_BUILD}"
  echo "${PULZR_BUILD}" > "${stage}/BUILD"
}

# The add-on repository for this release. It needs an ImageBuilder only for the
# apk inside it, which is the same binary in every one of them, so rpi4's is
# used: the cache for it is already warm from that board's image job.
# PULZR_ADDONS_TAG names the release the repository is for; a push that is not
# a tag builds under the version, which the workflow never uploads.
build_addons() {
  local out="${OUT_DIR}/addons"
  (
    # shellcheck disable=SC1091
    . "${BOARDS_DIR}/rpi4/board.conf"
    fetch_imagebuilder
    "${ROOT_DIR}/scripts/build-addons.sh" "$(imagebuilder_dir)" "${BUILD_DIR}/feed" \
      "${out}" "${PULZR_ADDONS_TAG:-v${PULZR_VERSION}}"
  )
  log "Done. Add-on repository: out/addons/"
}

# ── Per-board image ─────────────────────────────────────────────────────────

render_board_files() {
  # The `files/` tree ImageBuilder overlays onto the rootfs. Board values are
  # written as a single sourced config rather than substituted into a dozen
  # scripts, so that a running gateway can be inspected: `cat
  # /etc/pulzr/board.conf` tells you exactly what the image was built with.
  local files="$1"
  mkdir -p "${files}/etc/pulzr"

  {
    echo "# Generated by build.sh — do not edit on the device."
    echo "# Changing a value here does not reconfigure anything already applied;"
    echo "# it is a record of what this image was built as."
    echo "BOARD_ID='${BOARD_ID}'"
    echo "BOARD_NAME='${BOARD_NAME}'"
    echo "PULZR_VERSION='${PULZR_VERSION}'"
    echo "PULZR_BUILD='${PULZR_BUILD}'"
    echo "PULZR_COMMIT='${PULZR_COMMIT}'"
    echo "OPENWRT_VERSION='${OPENWRT_VERSION}'"
    for var in $(compgen -v | grep '^PULZR_' | sort); do
      case "${var}" in
        PULZR_VERSION|PULZR_BUILD|PULZR_COMMIT) continue ;;
      esac
      printf "%s='%s'\n" "${var}" "${!var}"
    done
  } > "${files}/etc/pulzr/board.conf"

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
    pulzr_check_features || exit 1

    if [ "${BOARD_STATUS:-supported}" != "supported" ]; then
      cat >&2 <<EOF
error: ${BOARD_ID} cannot be built from a stock OpenWrt ImageBuilder.

       OpenWrt ${OPENWRT_VERSION} has no device profile for it, so there is nothing for
       \`make image\` to assemble — it would fail with
       'Profile "${OPENWRT_PROFILE}" does not exist!'.

       See the header of the board's config for what it would take.
EOF
      exit 1
    fi
    log "Building ${BOARD_NAME} (${BOARD_ID}) — ${OPENWRT_TARGET}/${OPENWRT_SUBTARGET}"

    fetch_imagebuilder

    local ib files
    ib="$(imagebuilder_dir)"
    pack_feed "${ib}"
    files="${BUILD_DIR}/files-${BOARD_ID}"
    rm -rf "${files}"; mkdir -p "${files}"
    render_board_files "${files}"

    # Package list: shared, each feature's group, then board, then the removals as `-name` entries,
    # all flattened onto one line because ImageBuilder wants it that way.
    #
    # COMMENTS ARE STRIPPED FIRST, AND THAT IS NOT COSMETIC.
    #
    # The lists in board.conf are multi-line quoted strings with `#` comments
    # inside them. Flattening one without stripping those puts a `#` into the
    # PACKAGES variable, make passes it to a shell, and the shell treats the
    # rest of the line as a comment — silently discarding everything after it,
    # OpenWrt's own DEFAULT_PACKAGES included.
    #
    # The image then builds and boots with no base-files, no busybox and no
    # procd, and dies with:
    #
    #   Kernel panic - not syncing: No working init found
    #
    # Nothing in the build reports a problem; the only trace is ImageBuilder
    # echoing a "Packages:" line that stops mid-sentence.
    local packages
    packages="$(pulzr_packages \
                | sed 's/#.*//' \
                | tr -s '[:space:]' ' ')"
    for pkg in ${PACKAGES_REMOVE}; do packages="${packages} -${pkg}"; done

    # Belt and braces: a stray `#` from anywhere must never reach make.
    case "${packages}" in
      *"#"*) die "the package list contains '#', which would truncate it" ;;
    esac

    mkdir -p "${OUT_DIR}/${BOARD_ID}"

    make -C "${ib}" image \
      PROFILE="${OPENWRT_PROFILE}" \
      PACKAGES="${packages}" \
      FILES="${files}" \
      EXTRA_IMAGE_NAME="pulzr-${PULZR_VERSION}" \
      BIN_DIR="${OUT_DIR}/${BOARD_ID}" \
      -j"$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)"

    verify_rootfs "${ib}"

    log "Images: out/${BOARD_ID}/"
    ls -1 "${OUT_DIR}/${BOARD_ID}"/*.img.gz 2>/dev/null || true
  )
}

# Confirm our packages actually put files in the image.
#
# This exists because they once did not. Our hand-built opkg packages were ar
# archives where opkg only reads gzipped tar; it recorded all eight as
# installed and extracted nothing. The build succeeded, the image booted, and
# it contained no part of PulzrOS. apk is less forgiving of a bad package,
# but the packing is still ours rather than OpenWrt's.
#
# Nothing in the build reported a problem, so the check is here: look in the
# rootfs ImageBuilder actually assembled and insist a file we ship is present.
verify_rootfs() {
  local ib="$1"
  local root
  root="$(find "${ib}/build_dir" -maxdepth 2 -type d -name 'root-*' 2>/dev/null | head -n1)"

  if [ -z "${root}" ]; then
    warn "could not find the staging rootfs; skipping the payload check"
    return 0
  fi

  # First: can this image boot at all? The kernel execs /sbin/init, and an
  # image without one panics with "No working init found" — which is what a
  # truncated package list produces, and which is invisible until a board is
  # on the bench refusing to start.
  local essential="/sbin/init /bin/busybox /sbin/procd /etc/preinit"
  local path missing=""
  for path in ${essential}; do
    [ -e "${root}${path}" ] || missing="${missing} ${path}"
  done
  if [ -n "${missing}" ]; then
    cat >&2 <<EOF
error: the image is missing part of the base system:${missing}

       It would build, flash, and then panic on boot with
       "Kernel panic - not syncing: No working init found".

       The usual cause is a truncated package list — check ImageBuilder's
       "Packages:" line for a '#', which comments out everything after it.
EOF
    exit 1
  fi

  # Then: did our own packages actually put files down? One file from a package
  # with no dependencies of its own, so a failure here means the packaging is
  # broken rather than a dependency being unavailable.
  local witness="${root}/usr/sbin/pulzr-motd"
  if [ ! -f "${witness}" ]; then
    cat >&2 <<EOF
error: the image built, but contains none of our files.

       ${witness} is missing from the assembled rootfs, which means the
       pulzr-* packages installed their metadata and no payload.

       Compare what was staged with what was packed:

         tar -tf .build/feed/pulzr-base_noarch.tar | grep pulzr-motd
         $(imagebuilder_dir)/staging_dir/host/bin/apk adbdump \\
           $(imagebuilder_dir)/packages/pulzr-base-*.apk
EOF
    exit 1
  fi

  # And the shell: our busybox, built with FEATURE_SH_EXTRA_QUIET (sdk/build.sh),
  # not the release's, whose ash prints "BusyBox v... built-in shell (ash)" over
  # the PulzrOS banner at every login. The string is in the binary only when
  # the banner is; a release busybox that won the install has it.
  if grep -q 'built-in shell (ash)' "${root}/bin/busybox"; then
    cat >&2 <<EOF
error: the image carries OpenWrt's busybox, not the one built with its login
       banner compiled out. packages/ holds:
$(ls "${ib}/packages"/busybox-* 2>/dev/null | sed 's/^/         /')
EOF
    exit 1
  fi

  local count
  count="$(find "${root}" -path '*pulzr*' -type f | wc -l | tr -d ' ')"
  log "Payload check: ${count} Pulzr files in the rootfs"
}

# ── Entry point ─────────────────────────────────────────────────────────────

main() {
  local boards=()
  # all | console | feed | image. CI runs them as separate jobs so the console
  # and the packages are built once and shared by every board, rather than
  # rebuilt five times; a developer runs them together and never sees this.
  local stage=all

  if [ "${1:-}" = "--stage" ]; then
    stage="${2:?--stage needs a name: console, feed, image or addons}"
    case "${stage}" in
      console|feed|image|addons) ;;
      *) die "unknown stage '${stage}' (console, feed, image, addons)" ;;
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
    --sdk-targets) sdk_targets; exit 0 ;;
    # `mapfile` is bash 4 and macOS ships bash 3.2, so --all silently did
    # nothing there. A read loop works on both.
    --all)       while IFS= read -r b; do boards+=("${b}"); done < <(list_boards) ;;
    -h|--help)
      sed -n '2,25p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    '')
      # No board is fine for the stages that do not need one.
      case "${stage}" in
        console|feed|addons) ;;
        *) sed -n '2,25p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
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
      install_firmware_key
      install_ops_keys
      install_dev_keys
      install_ssh_ca
      build_feed
      log "Done. Feed only."
      return 0 ;;
    addons)
      build_addons
      return 0 ;;
    image)
      # Re-run in a fresh CI job, so the overlay has to be reconstructed even
      # though the console and packages arrived as artifacts.
      install_fleet_key
      install_firmware_key
      install_ops_keys
      install_dev_keys
      install_ssh_ca ;;
    all)
      build_console
      install_fleet_key
      install_firmware_key
      install_ops_keys
      install_dev_keys
      install_ssh_ca
      build_feed ;;
  esac

  [ "${#boards[@]}" -gt 0 ] || die "no board given"

  # On a Mac the console and the feed are done; hand the rest to a container
  # and do not come back.
  if ! can_assemble_here && ! in_container; then
    reexec_for_assembly "${boards[@]}"
  fi

  for board in "${boards[@]}"; do build_board "${board}"; done

  log "Done. PulzrOS ${PULZR_VERSION} (${PULZR_COMMIT})"
}

main "$@"
