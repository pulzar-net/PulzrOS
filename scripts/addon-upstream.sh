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
# apk checking each one against OpenWrt's signature, and go into the add-on
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
"${APK}" --root "${root}" --keys-dir "${KEYS}" --no-cache --no-interactive \
  --repositories-file /dev/null "${repos[@]}" --arch "${ARCH}" \
  fetch --recursive --output "${WORK}/fetched" "$@" >&2

# Every fetched file must carry OpenWrt's signature: fetch checks the index,
# and this checks each package against the keys again, as a gateway would.
"${APK}" --root "${root}" --keys-dir "${KEYS}" verify "${WORK}/fetched"/*.apk >&2

mkdir -p "${OUT}"
for f in "${WORK}/fetched"/*.apk; do
  name="$("${APK}" adbdump "${f}" | sed -n 's/^  name: //p' | head -n1)"
  [ -n "${name}" ] || { echo "cannot read the name of $(basename "${f}")" >&2; exit 1; }
  case "${name}" in
    kmod-*) echo "kmod ${name}" >&2; continue ;;
    kernel|libc|libgcc|libgcc1|libatomic|libatomic1|libpthread|librt) continue ;;
  esac
  cp "${f}" "${OUT}/"
  echo "${name}"
done
