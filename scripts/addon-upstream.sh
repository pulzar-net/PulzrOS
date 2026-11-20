#!/usr/bin/env bash
#
# Fetch the OpenWrt packages an add-on brings, unchanged, from the release's
# own signed feeds.
#
#   addon-upstream.sh <apk> <keys-dir> <arch> <target/subtarget> <out-dir> <package>...
#
# An add-on whose work is an OpenWrt package (pulzr-thread brings
# openthread-br) names it in feed/<name>/upstream. Its package and every
# dependency the image may lack are fetched here for one architecture, with
# apk checking each one against OpenWrt's signed index, and go into the add-on
# repository as they are: built by OpenWrt's buildbots from OpenWrt's recipe,
# never rebuilt or repacked by us. A gateway installs them from our signed
# index, which carries each one's hash.
#
# Prints, one per line, the names written to <out-dir>. Kernel modules and
# the toolchain's libc are resolved but not kept: a kmod is built for one
# kernel, and a gateway's comes with its image, so a module an upstream
# package needs must be in every image (PACKAGES_COMMON); the names of those
# are printed to stderr as `kmod <name>` for the caller to check.

set -euo pipefail

APK="${1:?apk}"
KEYS="${2:?keys dir}"
ARCH="${3:?arch}"
TARGET="${4:?target/subtarget}"
OUT="${5:?out dir}"
shift 5
[ "$#" -gt 0 ] || { echo "addon-upstream.sh: no packages named" >&2; exit 2; }

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="$(sed -n 's/^OPENWRT_VERSION="\(.*\)"/\1/p' "${ROOT_DIR}/boards/common/board.conf")"
[ -n "${VERSION}" ] || { echo "no OPENWRT_VERSION in boards/common/board.conf" >&2; exit 1; }
DL="https://downloads.openwrt.org/releases/${VERSION}"

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

# A target OpenWrt does not build (siflower/sf19a2890 is ours until it is
# mainline) has no feeds of its own, but its arch has: OpenWrt builds the arch
# feeds for some other target on it. That target's kernel, modules and libc
# resolve the dependencies and are dropped below, as every target's are, and
# what is kept is checked to come from the arch feeds alone.
arch_only=""
if ! curl -fsS --retry 3 -o /dev/null "${DL}/targets/${TARGET}/profiles.json"; then
  ours="${TARGET}"
  TARGET="$(curl -fsSL --retry 3 "${DL}/.targets.json" \
    | jq -r --arg a "${ARCH}" '[to_entries[] | select(.value == $a) | .key] | sort | first // empty')"
  [ -n "${TARGET}" ] || { echo "OpenWrt ${VERSION} builds ${ours} on no target of its own, and nothing on ${ARCH}" >&2; exit 1; }
  echo "OpenWrt ${VERSION} does not build ${ours}; resolving against ${TARGET}, the same arch" >&2
  arch_only=1
fi

# The kmods feed is named for the kernel the release ships on this target.
kernel="$(curl -fsSL --retry 3 "${DL}/targets/${TARGET}/profiles.json" \
  | jq -r '.linux_kernel | "\(.version)-\(.release)-\(.vermagic)"')"
case "${kernel}" in *null*|'') echo "no kernel in ${DL}/targets/${TARGET}/profiles.json" >&2; exit 1 ;; esac

repos=(
  --repository "${DL}/targets/${TARGET}/packages/packages.adb"
  --repository "${DL}/targets/${TARGET}/kmods/${kernel}/packages.adb"
  --repository "${DL}/packages/${ARCH}/base/packages.adb"
  --repository "${DL}/packages/${ARCH}/packages/packages.adb"
)

# apk-tools 3 will not open a root without an initialised database.
root="${WORK}/root"
mkdir -p "${root}/lib/apk/db" "${root}/etc/apk" "${WORK}/fetched"
: > "${root}/lib/apk/db/installed"
: > "${root}/etc/apk/world"

# --no-cache: apk-tools 3 reads a remote index from its cache unless told not
# to, and this root has none, so without it every feed is "No such file".
#
# OpenWrt signs its indexes, not its packages: fetch refuses an index whose
# signature is not one of KEYS, and checks each package it writes against
# the digest that index gives it, failing on any mismatch. That is the whole
# check, and the one a gateway makes; `apk verify` wants a signature on the
# package file itself, which no OpenWrt package has.
"${APK}" --root "${root}" --keys-dir "${KEYS}" --no-cache --no-interactive \
  --repositories-file /dev/null "${repos[@]}" --arch "${ARCH}" \
  fetch --recursive --output "${WORK}/fetched" "$@" >&2

kept=()
for f in "${WORK}/fetched"/*.apk; do
  name="$("${APK}" adbdump "${f}" | sed -n 's/^  name: //p' | head -n1)"
  [ -n "${name}" ] || { echo "cannot read the name of $(basename "${f}")" >&2; exit 1; }
  case "${name}" in
    kmod-*) echo "kmod ${name}" >&2; continue ;;
    kernel|libc|libgcc|libgcc1|libatomic|libatomic1|libpthread|librt) continue ;;
  esac
  kept+=("${f}:${name}")
done

# Resolved against another target: each kept package must be in the arch
# feeds, or it was that target's own build and is not ours to ship.
if [ -n "${arch_only}" ] && [ "${#kept[@]}" -gt 0 ]; then
  mkdir -p "${WORK}/arch"
  "${APK}" --root "${root}" --keys-dir "${KEYS}" --no-cache --no-interactive \
    --repositories-file /dev/null --arch "${ARCH}" \
    --repository "${DL}/packages/${ARCH}/base/packages.adb" \
    --repository "${DL}/packages/${ARCH}/packages/packages.adb" \
    fetch --output "${WORK}/arch" "${kept[@]#*:}" >&2 \
    || { echo "a package ${TARGET} resolved is not in the ${ARCH} feeds" >&2; exit 1; }
  for k in "${kept[@]}"; do
    cmp -s "${k%%:*}" "${WORK}/arch/$(basename "${k%%:*}")" \
      || { echo "${k#*:} from ${TARGET} is not the ${ARCH} feeds' build" >&2; exit 1; }
  done
fi

mkdir -p "${OUT}"
for k in "${kept[@]}"; do
  cp "${k%%:*}" "${OUT}/"
  echo "${k#*:}"
done
