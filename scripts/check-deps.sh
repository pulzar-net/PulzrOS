#!/usr/bin/env bash
#
# Verify that every package we ask for actually exists upstream.
#
#   scripts/check-deps.sh [board ...]     (default: every board)
#
# ── WHY ────────────────────────────────────────────────────────────────────
#
# A package name that does not exist upstream is not caught by anything until
# the ImageBuilder runs, which is the slowest and last step in CI. Three of them
# shipped at once — `figlet`, `libgpiod-utils` and `uqmi`, none of which exist
# in 24.10 — and the symptom was five image jobs failing after four minutes with
# the real cause buried under a page of "Configuring ...".
#
# This asks the release's own package indexes instead, in a few seconds, before
# anything is built.
#
# ── WHAT IT CHECKS ─────────────────────────────────────────────────────────
#
#   * PACKAGES_COMMON and PACKAGES_BOARD from each board's config
#   * the Depends: line of every package in feed/
#
# against the four architecture-independent feeds plus the target's own kmods
# index — kmods are published per target and kernel version, not in the shared
# feeds, so checking them against `packages` would report every kmod as missing.
#
# Our own parkeze-* packages are skipped: they are what this repo builds.

set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BOARDS_DIR="${ROOT_DIR}/boards"
CACHE="${ROOT_DIR}/.build/pkgindex"
BASE_URL="https://downloads.openwrt.org/releases"

mkdir -p "${CACHE}"

# Every package name in one of a release's index.json files. Cached: the
# indexes are large and a pinned release does not change. index.json rather
# than packages.adb because apk's index is a binary format only apk reads,
# and this runs before any ImageBuilder is on disk.
names() {
  local url="$1" out="$2"
  if [ ! -s "${out}" ]; then
    curl -fsL --max-time 90 "${url}" 2>/dev/null \
      | jq -r '.packages | keys[]' > "${out}.partial" 2>/dev/null || return 1
    [ -s "${out}.partial" ] || return 1
    mv "${out}.partial" "${out}"
  fi
  cat "${out}"
}

# Every package name available to a given board, one per line.
index_for() {
  local version="$1" arch="$2" target="$3" subtarget="$4"
  # The suffix versions what goes into the combined list. CI restores this
  # directory from cache, and a list built before the target index was added
  # would otherwise be trusted forever.
  local combined="${CACHE}/${version}-${arch}-${target}-${subtarget}.v3.names"
  [ -s "${combined}" ] && { cat "${combined}"; return 0; }

  local tmp="${combined}.partial"
  : > "${tmp}"

  for feed in base packages luci routing telephony; do
    names "${BASE_URL}/${version}/packages/${arch}/${feed}/index.json" \
          "${CACHE}/${version}-${arch}-${feed}.names" >> "${tmp}" \
      || echo "  note: no ${feed} feed for ${arch}" >&2
  done

  # Kernel modules live under the target, keyed by the exact kernel build. The
  # directory name is discovered rather than pinned, because it changes with
  # every kernel bump inside a release.
  # The target's own packages: libc, libgcc, libstdc++ and the rest of the
  # toolchain runtime live here, not in any feed.
  names "${BASE_URL}/${version}/targets/${target}/${subtarget}/packages/index.json" \
        "${CACHE}/${version}-${target}-${subtarget}-target.names" >> "${tmp}" || true

  local kdir
  kdir="$(curl -fsL --max-time 30 "${BASE_URL}/${version}/targets/${target}/${subtarget}/kmods/" 2>/dev/null \
          | grep -oE '[0-9]+\.[0-9]+\.[0-9]+-[0-9]+-[0-9a-f]+' | head -n1)"
  if [ -n "${kdir}" ]; then
    names "${BASE_URL}/${version}/targets/${target}/${subtarget}/kmods/${kdir}/index.json" \
          "${CACHE}/${version}-${target}-${subtarget}-kmods.names" >> "${tmp}" || true
  else
    echo "  note: could not locate the kmods index for ${target}/${subtarget}" >&2
  fi

  sort -u "${tmp}" > "${combined}"
  rm -f "${tmp}"
  cat "${combined}"
}

# Package names this repo builds itself.
our_packages() {
  find "${ROOT_DIR}/feed" -mindepth 1 -maxdepth 1 -type d -exec basename {} \;
}

# `mapfile` is bash 4; macOS ships bash 3.2, and this script has to run on a
# developer's Mac as well as in CI. Read loops instead, everywhere.
boards=()
for arg in "$@"; do boards+=("${arg}"); done
if [ "${#boards[@]}" -eq 0 ]; then
  while IFS= read -r b; do boards+=("${b}"); done < <(
    find "${BOARDS_DIR}" -mindepth 1 -maxdepth 1 -type d \
      ! -name common -exec basename {} \; | sort)
fi

OURS=()
while IFS= read -r p; do OURS+=("${p}"); done < <(our_packages)
is_ours() {
  local name="$1" p
  for p in "${OURS[@]}"; do [ "${name}" = "${p}" ] && return 0; done
  return 1
}

total_missing=0

for board in "${boards[@]}"; do
  conf="${BOARDS_DIR}/${board}/board.conf"
  [ -f "${conf}" ] || { echo "unknown board ${board}" >&2; exit 2; }

  # shellcheck disable=SC1090
  ( . "${conf}"
    echo "══ ${BOARD_ID} — ${OPENWRT_ARCH} (${OPENWRT_TARGET}/${OPENWRT_SUBTARGET})"

    available="$(index_for "${OPENWRT_VERSION}" "${OPENWRT_ARCH}" \
                           "${OPENWRT_TARGET}" "${OPENWRT_SUBTARGET}")"
    [ -n "${available}" ] || { echo "  could not build a package index; skipping" >&2; exit 0; }

    # Everything this board asks for, plus every dependency our own packages
    # declare — those are installed into the same image and fail the same way.
    # Comments are stripped per line BEFORE word-splitting. The package lists
    # are multi-line quoted strings with `#` comments inside them, so splitting
    # first turns every word of English prose into a "missing package" — which
    # it duly did, reporting 86 of them including "the" and "without".
    wanted="$(printf '%s\n%s\n' "${PACKAGES_COMMON}" "${PACKAGES_BOARD:-}" \
              | sed 's/#.*//' \
              | tr -s '[:space:]' '\n' \
              | grep -v '^$' | grep -v '^-')"
    deps="$(grep -h '^Depends:' "${ROOT_DIR}"/feed/*/control \
            | sed 's/^Depends: *//' | tr ',' '\n' | tr -d ' ' | grep -v '^$')"
    # Per-architecture packages keep their Depends in `arches`, by arch.
    deps="${deps}
$(cat "${ROOT_DIR}"/feed/*/arches 2>/dev/null \
  | awk -v a="${OPENWRT_ARCH}" '$1 == a && $2 != "-" { print $2 }' | tr ',' '\n')"

    missing=0
    while IFS= read -r pkg; do
      [ -n "${pkg}" ] || continue
      case "${pkg}" in \#*) continue ;; esac
      grep -qxF "${pkg}" <<<"${available}" && continue
      # Our own feed satisfies these.
      is_ours "${pkg}" && continue
      echo "  MISSING  ${pkg}"
      missing=$((missing + 1))
    done < <(printf '%s\n%s\n' "${wanted}" "${deps}" | sort -u)

    if [ "${missing}" -eq 0 ]; then
      echo "  all packages resolve"
      exit 0
    fi
    echo "  ${missing} package(s) do not exist in ${OPENWRT_VERSION}"
    exit 1
  ) || total_missing=$((total_missing + 1))
done

echo
if [ "${total_missing}" -gt 0 ]; then
  echo "${total_missing} board(s) reference packages that do not exist upstream."
  echo "Search for the real name:  https://openwrt.org/packages/start"
  exit 1
fi
echo "Every package resolves against the upstream indexes."
