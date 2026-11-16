#!/usr/bin/env bash
#
# Build the LoRa packages for one target with the OpenWrt SDK of the release
# the images are built from.
#
#   sdk/build.sh <target>/<subtarget> <out-dir>      (sdk/targets lists them)
#
# ChirpStack Concentratord and the MQTT Forwarder are built by ChirpStack's own
# OpenWrt recipes (their feed, pinned in feeds), with OpenWrt's Rust, so they
# link against the libc, libstdc++ and OpenSSL the image already has, and an
# OpenWrt release that patches those patches them. The only recipe here is
# packages/libloragw-sx1302: the SX1302 HAL from pulzar-net/sx1302_hal, built
# half-duplex for the MT7628's SPI.
#
# Slow the first time on a target: the SDK builds the Rust compiler (and its
# LLVM) from source. out-dir gets <package arch>/<name>-<version>.apk for every
# name in built.
#
# Needs OpenWrt's build prerequisites (https://openwrt.org/docs/guide-developer/toolchain/install-buildsystem)
# and clang, which bindgen uses for the HAL headers.

set -euo pipefail

TARGET="${1:?usage: sdk/build.sh <target>/<subtarget> <out-dir>}"
OUT="$(mkdir -p "${2:?usage: sdk/build.sh <target>/<subtarget> <out-dir>}" && cd "$2" && pwd)"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION="$(sed -n 's/^OPENWRT_VERSION="\(.*\)"/\1/p' "${HERE}/../boards/common/board.conf")"

WORK="${SDK_WORK:-${HERE}/../.build/sdk-work}/${TARGET//\//-}"
mkdir -p "${WORK}"

# ── The SDK ────────────────────────────────────────────────────────────────
# Verified against the release's checksum list, as build.sh verifies the
# ImageBuilder. The SDK's name carries the release's GCC version, so it is
# read from that list rather than written down.
url="https://downloads.openwrt.org/releases/${VERSION}/targets/${TARGET}"
read -r sha file < <(curl -fsSL --retry 3 "${url}/sha256sums" \
  | awk '$2 ~ /^\*openwrt-sdk-.*\.Linux-x86_64\.tar\.zst$/ { sub(/^\*/, "", $2); print $1, $2 }')
[ -n "${file:-}" ] || { echo "${url}/sha256sums lists no SDK" >&2; exit 1; }
if [ ! -f "${WORK}/${file}" ]; then
  curl -fsSL --retry 3 -o "${WORK}/${file}.part" "${url}/${file}"
  mv "${WORK}/${file}.part" "${WORK}/${file}"
fi
echo "${sha}  ${WORK}/${file}" | sha256sum -c -
sdk="${WORK}/sdk"
rm -rf "${sdk}"; mkdir -p "${sdk}"
tar --zstd -xf "${WORK}/${file}" -C "${sdk}" --strip-components=1

# ── Feeds ──────────────────────────────────────────────────────────────────
{
  grep -v '^#' "${HERE}/feeds" | sed "s|@SDK_PACKAGES@|${HERE}/packages|"
  cat "${sdk}/feeds.conf.default"
} > "${sdk}/feeds.conf"
cd "${sdk}"
./scripts/feeds update -a
# The HAL from ours, explicitly, before anything that depends on it is
# installed and pulls in ChirpStack's.
./scripts/feeds install -p pulzr libloragw-sx1302
./scripts/feeds install libloragw-sx1301 libloragw-2g4 chirpstack-concentratord chirpstack-mqtt-forwarder
[ "$(readlink -f package/feeds/pulzr/libloragw-sx1302)" = "$(readlink -f feeds/pulzr/libloragw-sx1302)" ] \
  && [ ! -e package/feeds/chirpstack/libloragw-sx1302 ] \
  || { echo "libloragw-sx1302 is not ours" >&2; exit 1; }

# ── Build ──────────────────────────────────────────────────────────────────
# Only what is asked for: the SDK otherwise builds every package in every feed.
{
  echo '# CONFIG_ALL is not set'
  echo '# CONFIG_ALL_NONSHARED is not set'
  echo '# CONFIG_ALL_KMODS is not set'
  echo '# CONFIG_SIGNED_PACKAGES is not set'
  grep -v '^#' "${HERE}/built" | sed 's/^\(.*\)$/CONFIG_PACKAGE_\1=m/'
} > .config
make defconfig
make -j"$(nproc)" package/feeds/chirpstack/chirpstack-concentratord/compile \
                  package/feeds/chirpstack/chirpstack-mqtt-forwarder/compile \
  || make -j1 V=s package/feeds/chirpstack/chirpstack-concentratord/compile \
                  package/feeds/chirpstack/chirpstack-mqtt-forwarder/compile

# ── Collect ────────────────────────────────────────────────────────────────
arch="$(ls bin/packages)"
mkdir -p "${OUT}/${arch}"
rm -f "${OUT}/${arch}"/*.apk
grep -v '^#' "${HERE}/built" | while IFS= read -r name; do
  apk="$(find bin/packages -name "${name}-[0-9]*.apk" | head -n1)"
  [ -n "${apk}" ] || { echo "the SDK built no ${name}" >&2; exit 1; }
  cp "${apk}" "${OUT}/${arch}/"
done
ls -l "${OUT}/${arch}"
