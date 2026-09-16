#!/usr/bin/env bash
#
# Build an OpenWrt ImageBuilder from source, with our device support added.
#
#   scripts/build-imagebuilder.sh <version> <target> <subtarget> <dest>
#
# For boards OpenWrt does not support yet (OPENWRT_IMAGEBUILDER=source). Every
# devices/*/openwrt/ directory holds a DTS and a patch against the OpenWrt
# tree; both are applied, only those devices are enabled, and the resulting
# ImageBuilder is extracted to <dest> for build.sh to use like a downloaded one.
#
# ── WHY THE KMODS STILL COME FROM downloads.openwrt.org ────────────────────
#
# A kmod only installs against the exact kernel it was built for, identified by
# a hash of the kernel config (the "vermagic"). The build starts from the
# release's own config.buildinfo, and adding a device changes a DTS and an
# image recipe but not the kernel config, so the hash matches the release and
# every upstream kmod still installs. That is checked at the end rather than
# assumed: a mismatch builds fine and fails at `make image` with an opaque
# dependency error for every kmod in the package list.
#
# Linux only, on a case-sensitive filesystem. On a Mac build.sh runs this in a
# container with the tree on a Docker volume.

set -euo pipefail

VERSION="${1:?usage: build-imagebuilder.sh <version> <target> <subtarget> <dest>}"
TARGET="${2:?}" SUBTARGET="${3:?}" DEST="${4:?}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${PARKEZE_OPENWRT_SRC:-${ROOT_DIR}/.build/openwrt}"
RELEASE="https://downloads.openwrt.org/releases/${VERSION}/targets/${TARGET}/${SUBTARGET}"

log() { printf '\033[36m==>\033[0m %s\n' "$*"; }
die() { printf '\033[31merror\033[0m %s\n' "$*" >&2; exit 1; }

# OpenWrt's configure scripts refuse root without this, and the container is root.
[ "$(id -u)" = 0 ] && export FORCE_UNSAFE_CONFIGURE=1

if [ ! -d "${SRC}/.git" ]; then
  log "Cloning OpenWrt v${VERSION}"
  git clone --depth 1 --branch "v${VERSION}" https://github.com/openwrt/openwrt.git "${SRC}"
fi
cd "${SRC}"
[ "$(git describe --tags --exact-match 2>/dev/null)" = "v${VERSION}" ] \
  || die "${SRC} is not a checkout of v${VERSION}"

# Back to the pristine tag, keeping dl/ and the build dirs so a rebuild is
# incremental.
git checkout -q -- .
git clean -fdq -- target package

devices=""
for dir in "${ROOT_DIR}"/devices/*/openwrt; do
  [ -f "${dir}/openwrt.patch" ] || continue
  log "Applying $(basename "$(dirname "${dir}")")"
  cp "${dir}"/*.dts "target/linux/${TARGET}/dts/"
  git apply "${dir}/openwrt.patch"
  devices="${devices} $(sed -n 's/^+define Device\/\(.*\)$/\1/p' "${dir}/openwrt.patch")"
done
[ -n "${devices// }" ] || die "no device support found under devices/*/openwrt"

log "Configuring from the release's config.buildinfo"
curl -fsSL -o .config "${RELEASE}/config.buildinfo"
# Only our devices, not the whole target. The release config names every one
# of the target's ~110 devices explicitly, so they are removed rather than
# overridden.
sed -i '/^CONFIG_TARGET_DEVICE_/d; /^CONFIG_TARGET_DEVICE_PACKAGES_/d' .config
{
  echo "# CONFIG_TARGET_ALL_PROFILES is not set"
  echo "CONFIG_TARGET_MULTI_PROFILE=y"
  for d in ${devices}; do
    echo "CONFIG_TARGET_DEVICE_${TARGET}_${SUBTARGET}_DEVICE_${d}=y"
  done
  # An ImageBuilder, and nothing else the release server builds.
  echo "CONFIG_IB=y"
  echo "# CONFIG_IB_STANDALONE is not set"
  echo "# CONFIG_SDK is not set"
  echo "# CONFIG_MAKE_TOOLCHAIN is not set"
  echo "# CONFIG_ALL_KMODS is not set"
  echo "# CONFIG_ALL_NONSHARED is not set"
  echo "# CONFIG_COLLECT_KERNEL_DEBUG is not set"
} >> .config
make defconfig >/dev/null

for d in ${devices}; do
  grep -qx "CONFIG_TARGET_DEVICE_${TARGET}_${SUBTARGET}_DEVICE_${d}=y" .config \
    || die "device ${d} did not survive defconfig — is the recipe in the patch valid?"
done

log "Building (first run: about an hour)"
make download -j8 >/dev/null
make -j"$(nproc)" || make -j1 V=s

# The check promised above.
vermagic="$(cat build_dir/target-*/linux-${TARGET}_${SUBTARGET}/linux-*/.vermagic)"
kmods="$(curl -fsSL "${RELEASE}/kmods/" | sed -n 's/.*href="\([0-9][^"/]*\)\/".*/\1/p' | head -n1)"
case "${kmods}" in
  *"-${vermagic}") log "vermagic ${vermagic} matches the release's kmods" ;;
  *) die "vermagic ${vermagic} does not match the release's kmods (${kmods}); upstream kmods will not install" ;;
esac

ib="$(ls bin/targets/"${TARGET}"/"${SUBTARGET}"/openwrt-imagebuilder-*.tar.zst)"
log "Extracting $(basename "${ib}")"
rm -rf "${DEST}"; mkdir -p "${DEST}"
tar --use-compress-program=unzstd -xf "${ib}" -C "${DEST}" --strip-components=1
