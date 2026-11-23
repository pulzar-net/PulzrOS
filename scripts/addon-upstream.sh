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
# Prints, one per line, the names written to <out-dir>. The toolchain's libc
# is resolved but never kept: it is the image's. Each kernel module is printed
# to stderr as `kmod <name>` as well, for the caller to check: a kmod is built
# for one kernel, so it is kept only with KEEP_KMODS=1, which the caller sets
# when every board that may install the add-on on this architecture runs the
# one target fetched from here. Its kmods are then that target's own, built
# with the release's kernel (the kmods feed is named for it), and apk holds
# each to the gateway's installed kernel package. Otherwise a module an
# upstream package needs must be in every image (PACKAGES_COMMON).
#
# TARGET_PACKAGES, when set, is the directory of a source-only target's own
# packages (the GL-SFT1200's siflower, which OpenWrt does not build): its
# kernel, kmods and toolchain libraries, from that board's ImageBuilder, which
# its image is built from too (build-addons.sh checks it). They stand in for
# the target's feeds; the arch's are OpenWrt's as for every target. A
# toolchain library an upstream package needs (openthread-br's libstdcpp6) is
# then that build's, the same one the image's libc and libgcc are.
#
# SDK_PACKAGES, when set, is this release's SDK build for the arch
# (sdk/build.sh's <out>/<arch>): ChirpStack Concentratord and the MQTT
# Forwarder, which pulzr-lorawan brings. They are built from ChirpStack's
# OpenWrt recipes against this release, and are the packages the images that
# carry pulzr-lorawan install; OpenWrt's feeds have no ChirpStack. busybox is
# left out: it is the image's own (sdk/build.sh), never an add-on's to bring.

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

# apk resolves only from a signed index. TARGET_PACKAGES and SDK_PACKAGES are
# this build's own files, checked by the caller, so the index over each is
# signed here with a key made for this run and trusted for this run only,
# beside OpenWrt's.
trusted="${WORK}/keys"; mkdir -p "${trusted}"
cp "${KEYS}"/*.pem "${trusted}/"
openssl ecparam -name prime256v1 -genkey -noout -out "${WORK}/local.pem"
openssl ec -in "${WORK}/local.pem" -pubout -out "${trusted}/local-build.pem" 2>/dev/null
KEYS="${trusted}"
local_index() {
  local dir="$1"
  ls "${dir}"/*.apk >/dev/null 2>&1 || { echo "no packages in ${dir}" >&2; exit 1; }
  rm -f "${dir}/packages.adb"
  ( cd "${dir}" && "${APK}" mkndx --keys-dir "${trusted}" --sign "${WORK}/local.pem" \
      --allow-untrusted --output packages.adb ./*.apk ) >&2
  repos+=(--repository "${dir}/packages.adb")
}

repos=()
if [ -n "${SDK_PACKAGES:-}" ]; then
  sdk="${WORK}/sdk"; mkdir -p "${sdk}"
  for f in "${SDK_PACKAGES}"/*.apk; do
    case "$(basename "${f}")" in busybox-[0-9]*) continue ;; esac
    if [ -f "${f}" ]; then cp "${f}" "${sdk}/"; fi
  done
  local_index "${sdk}"
fi
if [ -n "${TARGET_PACKAGES:-}" ]; then
  local_index "${TARGET_PACKAGES}"
else
  # The kmods feed is named for the kernel the release ships on this target.
  kernel="$(curl -fsSL --retry 3 "${DL}/targets/${TARGET}/profiles.json" \
    | jq -r '.linux_kernel | "\(.version)-\(.release)-\(.vermagic)"')"
  case "${kernel}" in *null*|'') echo "no kernel in ${DL}/targets/${TARGET}/profiles.json" >&2; exit 1 ;; esac
  repos+=(
    --repository "${DL}/targets/${TARGET}/packages/packages.adb"
    --repository "${DL}/targets/${TARGET}/kmods/${kernel}/packages.adb"
  )
fi
repos+=(
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

mkdir -p "${OUT}"
for f in "${WORK}/fetched"/*.apk; do
  name="$("${APK}" adbdump "${f}" | sed -n 's/^  name: //p' | head -n1)"
  [ -n "${name}" ] || { echo "cannot read the name of $(basename "${f}")" >&2; exit 1; }
  case "${name}" in
    kmod-*) echo "kmod ${name}" >&2; [ "${KEEP_KMODS:-0}" = 1 ] || continue ;;
    kernel|libc|libgcc|libgcc1|libatomic|libatomic1|libpthread|librt) continue ;;
  esac
  cp "${f}" "${OUT}/"
  echo "${name}"
done
