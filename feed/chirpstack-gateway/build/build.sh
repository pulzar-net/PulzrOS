#!/usr/bin/env bash
#
# Build ChirpStack Concentratord and the ChirpStack MQTT Forwarder from source
# for one target, as static musl binaries: the LoRa gateway half of every
# PulzarOS board with a concentrator (feed/chirpstack-gateway/fetch).
#
#   build.sh <target> <out-dir>
#
#   aarch64-unknown-linux-musl   Raspberry Pi 3/4/5 and other arm64 gateways
#   mipsel-unknown-linux-musl    MediaTek MT7628 gateways (RAK WisGate Edge, ...);
#                                the SX1302 HAL is built half-duplex for its SPI
#   mips-unknown-linux-musl      Atheros AR9331 gateways (Dragino LPS8N, ...)
#
# Built once per pin set: CI's "LoRa stack" job builds every target and caches
# them by build/key, so an image build only compiles when this directory
# changes.
#
# Needs Docker, rustup and cross (https://github.com/cross-rs/cross). Each
# project is built with its own rust-toolchain.toml, or for the tier 3 MIPS
# targets the nightly its own Makefile uses (versions), with std built from
# source. Concentratord builds in an image with the HALs in its sysroot
# (Dockerfile.concentratord); the forwarder in its own cross images.

set -euo pipefail

TARGET="${1:?usage: build.sh <target> <out-dir>}"
OUT="${2:?usage: build.sh <target> <out-dir>}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "${HERE}/versions"

case "${TARGET}" in
  aarch64-unknown-linux-musl)
    MUSL_PREFIX=aarch64-linux-musl HAL_ARCH=arm SPI_HALF_DUPLEX=0 TIER3=0
    CONCENTRATORD_BINS="chirpstack-concentratord-sx1302 chirpstack-concentratord-sx1301" ;;
  mipsel-unknown-linux-musl)
    MUSL_PREFIX=mipsel-linux-muslsf HAL_ARCH=mips SPI_HALF_DUPLEX=1 TIER3=1
    CONCENTRATORD_BINS="chirpstack-concentratord-sx1302" ;;
  mips-unknown-linux-musl)
    MUSL_PREFIX=mips-linux-muslsf HAL_ARCH=mips SPI_HALF_DUPLEX=0 TIER3=1
    CONCENTRATORD_BINS="chirpstack-concentratord-sx1302" ;;
  *) echo "unknown target ${TARGET}" >&2; exit 1 ;;
esac

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
mkdir -p "${OUT}"

get() {  # get <owner/repo> <tag> <sha256> <dir>
  curl -fsSL --retry 3 -o "${WORK}/src.tgz" "https://codeload.github.com/$1/tar.gz/$2"
  echo "$3  ${WORK}/src.tgz" | sha256sum -c - >/dev/null
  mkdir -p "$4"
  tar -xzf "${WORK}/src.tgz" -C "$4" --strip-components=1
  rm "${WORK}/src.tgz"
}

static() {  # static <binary>: refuse anything that would need the gateway's libraries
  file "$1" | grep -Eq 'statically linked|static-pie linked' \
    || { file "$1"; echo "$1 is not static" >&2; exit 1; }
}

# cross <toolchain-or-empty> <dir> <args...>
build() {
  local nightly="$1" dir="$2"; shift 2
  if [ "${TIER3}" = 1 ]; then
    rustup toolchain install --profile minimal --component rust-src "${nightly}" >/dev/null
    (cd "${dir}" && cross "+${nightly}" build --release --target "${TARGET}" \
       -Z build-std=std,panic_abort "$@")
  else
    (cd "${dir}" && cross build --release --target "${TARGET}" "$@")
  fi
}

# ── Concentratord ──────────────────────────────────────────────────────────
C="${WORK}/concentratord"
get chirpstack/chirpstack-concentratord "v${CONCENTRATORD_VERSION}" "${CONCENTRATORD_SHA256}" "${C}"
cp "${HERE}/Dockerfile.concentratord" "${C}/cross/Dockerfile.pulzr"
cat > "${C}/Cross.toml" <<EOF
[target.${TARGET}.dockerfile]
file = "cross/Dockerfile.pulzr"
build-args = { BASE = "ghcr.io/cross-rs/${TARGET}:main", MUSL_PREFIX = "${MUSL_PREFIX}", HAL_ARCH = "${HAL_ARCH}", SPI_HALF_DUPLEX = "${SPI_HALF_DUPLEX}", SX1302_HAL_REPO = "${SX1302_HAL_REPO}", SX1302_HAL_VERSION = "${SX1302_HAL_VERSION}", SX1302_HAL_SHA256 = "${SX1302_HAL_SHA256}", SX1301_HAL_VERSION = "${SX1301_HAL_VERSION}", SX1301_HAL_SHA256 = "${SX1301_HAL_SHA256}" }
EOF
# The static link concentratord's own config gives its other targets, for the
# MIPS ones it does not list.
if ! grep -q "^\[target.${TARGET}\]" "${C}/.cargo/config.toml"; then
  cat >> "${C}/.cargo/config.toml" <<EOF

[target.${TARGET}]
rustflags = ["-C", "target-feature=+crt-static", "-C", "link-arg=-s", "-C", "link-arg=-lc", "-C", "link-arg=-lgcc", "-L", "native=/usr/local/${MUSL_PREFIX}-target/lib", "-l", "static=stdc++"]
EOF
fi
packages=()
for bin in ${CONCENTRATORD_BINS}; do packages+=(-p "${bin}"); done
build "${CONCENTRATORD_NIGHTLY}" "${C}" "${packages[@]}"
for bin in ${CONCENTRATORD_BINS}; do
  static "${C}/target/${TARGET}/release/${bin}"
  cp "${C}/target/${TARGET}/release/${bin}" "${OUT}/${bin}-${TARGET}"
done

# ── MQTT Forwarder ─────────────────────────────────────────────────────────
# Default features: the concentratord backend (ZeroMQ, vendored) as well as
# Semtech UDP. Static, as concentratord is.
F="${WORK}/forwarder"
get chirpstack/chirpstack-mqtt-forwarder "v${MQTT_FORWARDER_VERSION}" "${MQTT_FORWARDER_SHA256}" "${F}"
mkdir -p "${F}/.cargo"
cat >> "${F}/.cargo/config.toml" <<EOF

[target.${TARGET}]
rustflags = ["-C", "target-feature=+crt-static", "-C", "link-arg=-s"]
EOF
build "${MQTT_FORWARDER_NIGHTLY}" "${F}"
static "${F}/target/${TARGET}/release/chirpstack-mqtt-forwarder"
cp "${F}/target/${TARGET}/release/chirpstack-mqtt-forwarder" "${OUT}/chirpstack-mqtt-forwarder-${TARGET}"

ls -l "${OUT}"
