#!/usr/bin/env bash
#
# Build the LoRa packages for one target with the OpenWrt SDK of the release
# the images are built from.
#
#   sdk/build.sh <target>/<subtarget> <out-dir>      (build.sh --sdk-targets lists them)
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
  # The SDK turns AUTOREMOVE on, and with it a finished host build deletes
  # everything in its build dir but the stamps: Rust's build/dist went with it
  # before it could be kept below, which cost a cold build its cache. Rust's
  # build dir is pruned by hand once its archives are kept.
  echo '# CONFIG_AUTOREMOVE is not set'
  grep -v '^#' "${HERE}/built" | sed 's/^\(.*\)$/CONFIG_PACKAGE_\1=m/'
  echo 'CONFIG_PACKAGE_pulzr-edge-bin=m'
} > .config
make defconfig
! grep -q '^CONFIG_AUTOREMOVE=y' .config || { echo "defconfig turned AUTOREMOVE back on" >&2; exit 1; }

# ── Rust ───────────────────────────────────────────────────────────────────
# The Rust compiler is two of a cold build's three hours: the release's recipe
# builds it and its LLVM from source (llvm.download-ci-llvm=false). Only the
# release and the target decide it, so prebuilt.yml keeps it apart from
# sdk/key (RUST_CACHE), and a change here rebuilds the packages, not Rust.
# What is kept is what the recipe's own Host/Install unpacks, build/dist/*.tar.gz,
# with the recipe's stamps, so OpenWrt installs it as it would have after
# compiling it.
#
# The prepared stamp's name hashes the recipe's files with their mtimes
# (find_md5), and a fresh clone of the feed dates them now. So on every build,
# cold or not, they are dated to the feed's commit first, and the name comes
# out the same each time.
rust_recipe="feeds/packages/lang/rust"
rust_version="$(sed -n 's/^PKG_VERSION:=//p' "${rust_recipe}/Makefile")"
[ -n "${rust_version}" ] || { echo "no PKG_VERSION in ${rust_recipe}/Makefile" >&2; exit 1; }
# A package's BUILD_DIR and STAGING_DIR are the target's (rules.mk), so the
# recipe builds in build_dir/<target>/host and installs to
# staging_dir/<target>/host, not build_dir/host or staging_dir/host: both were
# assumed once, and two cold builds lost their compiler to it.
target_dir="$(basename "$(compgen -G 'staging_dir/target-*' | head -n1)")"
[ "${target_dir}" != . ] && [ -n "${target_dir}" ] || { echo "the SDK has no staging_dir/target-*" >&2; exit 1; }
rust_build="build_dir/${target_dir}/host/rustc-${rust_version}-src"
find "${rust_recipe}" -exec touch -h -d "@$(git -C feeds/packages log -1 --format=%ct)" {} +
rust_restored=""
if [ -n "${RUST_CACHE:-}" ] && [ -f "${RUST_CACHE}/rustc-${rust_version}-src/.built" ]; then
  mkdir -p "$(dirname "${rust_build}")"
  rm -rf "${rust_build}"
  cp -a "${RUST_CACHE}/rustc-${rust_version}-src" "$(dirname "${rust_build}")/"
  # The source is a prerequisite of the prepared stamp (download.mk), so it is
  # fetched, and checked, before the stamps are dated after it, in the order
  # the recipe would have written them.
  make package/feeds/packages/rust/download
  touch "${rust_build}"/.prepared*
  touch "${rust_build}/.configured"
  touch "${rust_build}/.built"
  rust_restored=1
  echo "rust ${rust_version}: the release's build for ${TARGET}, from the cache"
fi
make -j"$(nproc)" package/feeds/packages/rust/host/compile
[ -x "staging_dir/${target_dir}/host/bin/rustc" ] \
  || { echo "the SDK has no rustc after rust/host/compile" >&2; exit 1; }
[ -f "${rust_build}/.built" ] || { echo "rust/host/compile left no ${rust_build}/.built" >&2; exit 1; }
if [ -n "${rust_restored}" ] && [ -d "${rust_build}/build/x86_64-unknown-linux-gnu" ]; then
  echo "::warning::the cached Rust ${rust_version} was not taken: OpenWrt compiled it again"
fi
# Kept now, not after the packages: two hours of compiler survive a package
# that fails to build (prebuilt.yml saves it either way).
if [ -n "${RUST_CACHE:-}" ] && [ -z "${rust_restored}" ]; then
  keep="${RUST_CACHE}/rustc-${rust_version}-src"
  rm -rf "${keep}"; mkdir -p "${keep}/build/dist"
  cp -a "${rust_build}"/.prepared* "${rust_build}/.configured" "${rust_build}/.built" "${keep}/"
  cp -a "${rust_build}"/build/dist/*.tar.gz "${keep}/build/dist/"
  du -sh "${keep}"
fi
# What AUTOREMOVE would have done: tens of GB of LLVM and rustc objects, no
# longer needed once Rust is installed into the SDK.
find "${rust_build}" -mindepth 1 -maxdepth 1 -not \( -type f -name '.*' -size 0 \) -exec rm -rf {} +

# OpenWrt's own sccache hook (lang/rust's Config.in) for the Rust packages,
# when prebuilt.yml hands a cache directory over. Only now: the hook wraps the
# compiler's own build too, and the compiler is cached whole above.
if [ -n "${SDK_SCCACHE_DIR:-}" ]; then
  command -v sccache >/dev/null || { echo "SDK_SCCACHE_DIR is set and sccache is not installed" >&2; exit 1; }
  { echo 'CONFIG_RUST_SCCACHE=y'; echo "CONFIG_RUST_SCCACHE_DIR=\"${SDK_SCCACHE_DIR}\""; } >> .config
  make defconfig
  grep -q '^CONFIG_RUST_SCCACHE=y' .config || { echo "defconfig dropped CONFIG_RUST_SCCACHE" >&2; exit 1; }
fi

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
sh "${HERE}/../scripts/busybox-quiet-config.sh" .config >> .config
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
for bin in pulzr-edge pulzr-edge-zigbee pulzr-edge-zwave pulzr-edge-matter pulzr-edge-ip pulzr-edge-ble pulzr-probe; do
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

if [ -n "${SDK_SCCACHE_DIR:-}" ]; then
  SCCACHE_DIR="${SDK_SCCACHE_DIR}" sccache --show-stats || true
  SCCACHE_DIR="${SDK_SCCACHE_DIR}" sccache --stop-server >/dev/null 2>&1 || true
fi
