#!/usr/bin/env bash
#
# Build, once, a ucode for this machine at exactly the commit the target
# OpenWrt release ships, and print the path to it.
#
#   UCODE="$(scripts/host-ucode.sh)"
#
# Release images ship ucode precompiled (scripts/harden-payload.sh), and a
# gateway's libucode refuses bytecode from any other format version. The
# version is not pinned here: it is read from the release's own package index,
# so moving OPENWRT_VERSION moves the compiler with it and the two cannot
# drift. The bytecode itself is portable across boards: fixed-width,
# big-endian fields, so one compile serves the 64-bit Pis and the 32-bit RAKs.
#
# Only the compiler is needed, so every native module is off and json-c is the
# one dependency (libjson-c-dev, or `brew install json-c cmake` on a Mac).

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
. "${ROOT_DIR}/boards/common/board.conf"

CACHE="${ROOT_DIR}/.build/host-ucode"
mkdir -p "${CACHE}"

# Any architecture's base feed: ucode is the same commit on all of them.
index="${CACHE}/${OPENWRT_VERSION}-base.json"
if [ ! -s "${index}" ]; then
  curl -fsL --max-time 90 -o "${index}.partial" \
    "https://downloads.openwrt.org/releases/${OPENWRT_VERSION}/packages/aarch64_cortex-a53/base/index.json"
  mv "${index}.partial" "${index}"
fi

# "2026.01.16~85922056-r2" -> 85922056
version="$(jq -r '.packages.ucode // empty' "${index}")"
commit="${version#*~}"; commit="${commit%%-*}"
[ -n "${commit}" ] && [ "${commit}" != "${version}" ] \
  || { echo "error: no ucode commit in ${OPENWRT_VERSION}'s index (got '${version}')" >&2; exit 1; }

dir="${CACHE}/${commit}"
bin="${dir}/build/ucode"
if [ ! -x "${bin}" ]; then
  rm -rf "${dir}"
  git clone -q https://github.com/jow-/ucode "${dir}" >&2
  git -C "${dir}" checkout -q "${commit}"
  cmake -S "${dir}" -B "${dir}/build" -DCMAKE_BUILD_TYPE=Release \
        -DFS_SUPPORT=OFF -DMATH_SUPPORT=OFF -DUBUS_SUPPORT=OFF -DUCI_SUPPORT=OFF \
        -DRTNL_SUPPORT=OFF -DNL80211_SUPPORT=OFF -DRESOLV_SUPPORT=OFF \
        -DSTRUCT_SUPPORT=OFF -DULOOP_SUPPORT=OFF -DDEBUG_SUPPORT=OFF \
        -DLOG_SUPPORT=OFF -DSOCKET_SUPPORT=OFF -DZLIB_SUPPORT=OFF \
        -DDIGEST_SUPPORT=OFF >&2
  cmake --build "${dir}/build" -j"$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)" >&2
fi

"${bin}" -e 'print("")' >/dev/null 2>&1 || { echo "error: ${bin} does not run" >&2; exit 1; }
echo "${bin}"
