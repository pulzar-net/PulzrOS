#!/usr/bin/env bash
#
# Build, for this machine, the OpenThread border router the release's
# openthread-br package is built from, and OpenThread's simulated radio and
# device, for scripts/test-thread.py.
#
#   scripts/thread-sim.sh <out-dir>
#
#   <out-dir>/otbr-agent, ot-ctl    ot-br-posix at the commit OpenWrt's
#                                   openthread-br pins, for OPENWRT_VERSION's
#                                   release branch, with its REST API
#   <out-dir>/ot-rcp, ot-cli-ftd    OpenThread's simulation platform, from the
#                                   OpenThread that commit carries
#   <out-dir>/ucode                 ucode at the release's commit, with fs
#
# The commit is read from OpenWrt's own recipe, never written here, so the one
# version line (OPENWRT_VERSION) moves this with everything else. Built with
# the recipe's options except mDNS, TREL and the border agent, which need an
# mDNS daemon per border router and are not what the test is about; the REST
# API, border routing, the commissioner and network diagnostics are the same
# code the gateways run.

set -euo pipefail

OUT="$(mkdir -p "${1:?usage: thread-sim.sh <out-dir>}" && cd "$1" && pwd)"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
. "${ROOT_DIR}/boards/common/board.conf"
branch="openwrt-${OPENWRT_VERSION%.*}"
WORK="${THREAD_SIM_WORK:-${ROOT_DIR}/.build/thread-sim}"
mkdir -p "${WORK}"

recipe="$(curl -fsSL --retry 3 "https://raw.githubusercontent.com/openwrt/packages/${branch}/net/openthread-br/Makefile")"
commit="$(sed -n 's/^PKG_SOURCE_VERSION:=//p' <<<"${recipe}")"
[[ "${commit}" =~ ^[0-9a-f]{40}$ ]] || { echo "no PKG_SOURCE_VERSION in ${branch}'s openthread-br recipe" >&2; exit 1; }
echo "openthread-br on ${branch}: ot-br-posix ${commit}" >&2
echo "${commit}" > "${OUT}/otbr-commit"

src="${WORK}/ot-br-posix-${commit}"
if [ ! -d "${src}/.git" ]; then
  rm -rf "${src}"
  git init -q "${src}"
  git -C "${src}" remote add origin https://github.com/openthread/ot-br-posix
  git -C "${src}" fetch -q --depth 1 origin "${commit}"
  git -C "${src}" checkout -q FETCH_HEAD
  git -C "${src}" submodule update -q --init --depth 1 --recursive
fi

jobs="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)"
# CMake 4 refuses projects that declare a minimum below 3.5, and the cJSON
# that ot-br-posix carries still does; OpenWrt's own host CMake is older.
export CMAKE_POLICY_VERSION_MINIMUM=3.5

if [ ! -x "${OUT}/otbr-agent" ]; then
  cmake -GNinja -S "${src}" -B "${WORK}/otbr" -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTING=OFF \
    -DOTBR_REST=ON -DOTBR_BORDER_ROUTING=ON -DOTBR_DBUS=OFF -DOTBR_WEB=OFF \
    -DOTBR_BORDER_AGENT=OFF -DOTBR_MDNS= -DOTBR_TREL=OFF -DOTBR_SRP_ADVERTISING_PROXY=OFF \
    -DOTBR_DNSSD_DISCOVERY_PROXY=OFF -DOTBR_BACKBONE_ROUTER=OFF -DOTBR_NAT64=OFF \
    -DOT_FIREWALL=OFF -DOT_CHANNEL_MANAGER=ON -DOT_CHANNEL_MONITOR=ON \
    -DOT_POSIX_SETTINGS_PATH='"/var/lib/thread"' >&2
  ninja -C "${WORK}/otbr" -j"${jobs}" otbr-agent ot-ctl >&2
  install -m 0755 "${WORK}/otbr/src/agent/otbr-agent" "${OUT}/otbr-agent"
  install -m 0755 "$(find "${WORK}/otbr" -name ot-ctl -type f -perm -u+x | head -n1)" "${OUT}/ot-ctl"
fi

if [ ! -x "${OUT}/ot-rcp" ]; then
  ot="${src}/third_party/openthread/repo"
  cmake -GNinja -S "${ot}" -B "${WORK}/sim" -DCMAKE_BUILD_TYPE=Release \
    -DOT_PLATFORM=simulation -DOT_COMPILE_WARNING_AS_ERROR=OFF \
    -DOT_FTD=ON -DOT_MTD=OFF -DOT_RCP=ON -DOT_APP_CLI=ON -DOT_APP_NCP=OFF -DOT_APP_RCP=ON \
    -DOT_JOINER=ON -DOT_COMMISSIONER=OFF >&2
  ninja -C "${WORK}/sim" -j"${jobs}" ot-rcp ot-cli-ftd >&2
  install -m 0755 "$(find "${WORK}/sim" -name ot-rcp -type f | head -n1)" "${OUT}/ot-rcp"
  install -m 0755 "$(find "${WORK}/sim" -name ot-cli-ftd -type f | head -n1)" "${OUT}/ot-cli-ftd"
fi

if [ ! -x "${OUT}/ucode" ]; then
  index="$(curl -fsSL --retry 3 "https://downloads.openwrt.org/releases/${OPENWRT_VERSION}/packages/aarch64_cortex-a53/base/index.json")"
  version="$(jq -r '.packages.ucode' <<<"${index}")"
  ucommit="${version#*~}"; ucommit="${ucommit%%-*}"
  usrc="${WORK}/ucode-${ucommit}"
  [ -d "${usrc}/.git" ] || { git clone -q https://github.com/jow-/ucode "${usrc}"; git -C "${usrc}" checkout -q "${ucommit}"; }
  cmake -S "${usrc}" -B "${WORK}/ucode" -DCMAKE_BUILD_TYPE=Release \
    -DFS_SUPPORT=ON -DMATH_SUPPORT=OFF -DUBUS_SUPPORT=OFF -DUCI_SUPPORT=OFF \
    -DRTNL_SUPPORT=OFF -DNL80211_SUPPORT=OFF -DRESOLV_SUPPORT=OFF \
    -DSTRUCT_SUPPORT=OFF -DULOOP_SUPPORT=OFF -DDEBUG_SUPPORT=OFF \
    -DLOG_SUPPORT=OFF -DSOCKET_SUPPORT=OFF -DZLIB_SUPPORT=OFF -DDIGEST_SUPPORT=OFF >&2
  cmake --build "${WORK}/ucode" -j"${jobs}" >&2
  mkdir -p "${OUT}/ucode-lib"
  install -m 0755 "${WORK}/ucode/fs.so" "${OUT}/ucode-lib/fs.so"
  install -m 0755 "${WORK}/ucode/ucode" "${OUT}/ucode.bin"
  cp -P "${WORK}"/ucode/libucode.so* "${OUT}/ucode-lib/"
  # A wrapper that finds the fs module and libucode where they were put.
  cat > "${OUT}/ucode" <<EOF
#!/bin/sh
LD_LIBRARY_PATH="${OUT}/ucode-lib" exec "${OUT}/ucode.bin" -L "${OUT}/ucode-lib/*.so" "\$@"
EOF
  chmod +x "${OUT}/ucode"
fi

ls -l "${OUT}" >&2
