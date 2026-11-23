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
./scripts/feeds install -p pulzr pulzr-edge-bin
# OpenWrt's own BusyBox recipe, from the release's base feed: see BusyBox below.
./scripts/feeds install busybox
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
  echo 'CONFIG_PACKAGE_pulzr-edge-bin=m'
} > .config
make defconfig

# ── BusyBox ────────────────────────────────────────────────────────────────
# OpenWrt's busybox, built from its own recipe at the release's commit with the
# release's configuration and one option changed: FEATURE_SH_EXTRA_QUIET, so
# the shell does not open every login with "BusyBox v1.37.0 (...) built-in
# shell (ash)" above the PulzrOS banner (owner, 23 Nov 2026). The option is
# compile-time only, which is why there is a build at all.
#
# Proved, not assumed: the recipe's configuration is generated once as the
# release ships it and once with the option, and the two must differ in that
# line and nothing else. Every image then checks it carries this busybox, not
# OpenWrt's (build.sh, verify_rootfs).
busybox_config() { find build_dir -path '*/busybox-*/.config' -newer "$1" | head -n1; }
# Clean first: the SDK is cached between runs, and a recipe configured already
# is not configured again.
make package/feeds/base/busybox/clean >/dev/null
touch .busybox-mark
make package/feeds/base/busybox/configure >/dev/null
stock="$(busybox_config .busybox-mark)"
[ -n "${stock}" ] || { echo "busybox configured no .config" >&2; exit 1; }
cp "${stock}" .busybox-stock.config
make package/feeds/base/busybox/clean >/dev/null
{
  echo 'CONFIG_BUSYBOX_CUSTOM=y'
  echo 'CONFIG_BUSYBOX_CONFIG_FEATURE_SH_EXTRA_QUIET=y'
} >> .config
make defconfig
touch .busybox-mark
make package/feeds/base/busybox/configure >/dev/null
ours="$(busybox_config .busybox-mark)"
[ -n "${ours}" ] || { echo "busybox configured no .config" >&2; exit 1; }
# Both files open with a generated header and a date; only settings count.
changed="$(diff <(grep -E '^(CONFIG_|# CONFIG_)' .busybox-stock.config) \
                <(grep -E '^(CONFIG_|# CONFIG_)' "${ours}") | grep '^[<>]' || true)"
[ "${changed}" = "< # CONFIG_FEATURE_SH_EXTRA_QUIET is not set
> CONFIG_FEATURE_SH_EXTRA_QUIET=y" ] || {
  echo "busybox's configuration changed in more than FEATURE_SH_EXTRA_QUIET:" >&2
  echo "${changed}" >&2
  exit 1
}
echo "busybox: the release's configuration, with FEATURE_SH_EXTRA_QUIET"
make -j"$(nproc)" package/feeds/chirpstack/chirpstack-concentratord/compile \
                  package/feeds/chirpstack/chirpstack-mqtt-forwarder/compile \
                  package/feeds/pulzr/pulzr-edge/compile \
                  package/feeds/base/busybox/compile \
  || make -j1 V=s package/feeds/chirpstack/chirpstack-concentratord/compile \
                  package/feeds/chirpstack/chirpstack-mqtt-forwarder/compile \
                  package/feeds/pulzr/pulzr-edge/compile \
                  package/feeds/base/busybox/compile

# ── Collect ────────────────────────────────────────────────────────────────
arch="$(ls bin/packages)"
mkdir -p "${OUT}/${arch}"
rm -f "${OUT}/${arch}"/*.apk
grep -v '^#' "${HERE}/built" | while IFS= read -r name; do
  apk="$(find bin/packages -name "${name}-[0-9]*.apk" | head -n1)"
  [ -n "${apk}" ] || { echo "the SDK built no ${name}" >&2; exit 1; }
  cp "${apk}" "${OUT}/${arch}/"
done
# pulzr-edge's binaries, one per module, for the add-ons' and pulzr-probe's fetch.
for bin in pulzr-edge pulzr-edge-zigbee pulzr-edge-zwave pulzr-edge-matter pulzr-edge-ble pulzr-probe; do
  # Bluetooth is little-endian only (bt-hci): no pulzr-edge-ble on mips.
  case "${bin}:${arch}" in pulzr-edge-ble:mips_*) continue ;; esac
  found="$(find build_dir -path "*pulzr-edge-bin/usr/sbin/${bin}" -type f | head -n1)"
  [ -n "${found}" ] || { echo "the SDK built no ${bin}" >&2; exit 1; }
  install -m 0755 "${found}" "${OUT}/${arch}/${bin}"
done
# pulzr-probe is in every image: held to 500 KB on flash, which is squashfs and
# so xz, as pulzr-edge's release holds it.
flash="$(xz -9e -c "${OUT}/${arch}/pulzr-probe" | wc -c)"
[ "${flash}" -le 512000 ] || { echo "pulzr-probe is ${flash} bytes on flash on ${arch}, over 500 KB" >&2; exit 1; }
ls -l "${OUT}/${arch}"
