#!/usr/bin/env bash
#
# Turn a board's raw ImageBuilder output into something a person can use.
#
#   scripts/package-images.sh <board> <version>
#
# ── WHY ────────────────────────────────────────────────────────────────────
#
# ImageBuilder produces four files per board with names like
#
#   openwrt-24.10.0-parkeze-0.1.0-bcm27xx-bcm2711-rpi-4-squashfs-factory.img.gz
#
# which tells you everything except which one to write to a card. Downloading a
# CI artifact and being handed four of those is not a usable release.
#
# So this picks the one that belongs on a blank card and renames it to something
# legible, alongside the sysupgrade image and checksums.
#
# ── FORMATS ────────────────────────────────────────────────────────────────
#
# Both .img.gz and .img.xz, because the tools disagree:
#
#   .img.gz   what OpenWrt produced. Etcher, Rufus and dd all take it.
#   .img.xz   roughly 40% smaller. Raspberry Pi Imager, Etcher and Rufus all
#             decompress it inline, so there is nothing to unzip first.
#
# Not an ISO. An ISO is an optical-disc filesystem with no partition table; a
# Pi will not boot one. These are raw disk images, which is what every SD
# writer actually wants.

set -euo pipefail

BOARD="${1:?usage: package-images.sh <board> <version>}"
VERSION="${2:?usage: package-images.sh <board> <version>}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BOARDS_DIR="${ROOT_DIR}/boards"
SRC="${ROOT_DIR}/out/${BOARD}"
DEST="${ROOT_DIR}/out/release"

log() { printf '\033[36m==>\033[0m %s\n' "$*"; }
die() { printf '\033[31merror\033[0m %s\n' "$*" >&2; exit 1; }

[ -d "${SRC}" ] || die "no images in out/${BOARD}"
mkdir -p "${DEST}"

# shellcheck disable=SC1090
. "${BOARDS_DIR}/${BOARD}/board.conf"

# The image for a blank card. squashfs-factory, for the reasons in
# boards/common/board.conf — the overlay is what factory reset needs.
factory="$(find "${SRC}" -maxdepth 1 -name '*squashfs-factory.img.gz' | head -n1)"
[ -n "${factory}" ] || die "no squashfs-factory image for ${BOARD}"

# And the one for a gateway already running ParkezeOS.
sysupgrade="$(find "${SRC}" -maxdepth 1 -name '*squashfs-sysupgrade.img.gz' | head -n1)"

base="ParkezeOS-${VERSION}-${BOARD}"

sha() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
  else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

log "Packaging ${BOARD}"

# ── the flashable image ─────────────────────────────────────────────────────
#
# Padded out to the end of the last partition before it is compressed.
#
# ImageBuilder truncates the .img the moment the squashfs ends, so the file is
# ~90MB while its own partition table declares a 176MB layout. Everything past
# that point — which is exactly where OpenWrt puts rootfs_data, the overlay
# holding all device config — is simply absent from the file, and writing the
# image leaves whatever was there before untouched.
#
# On a card that has run ParkezeOS before, that means a re-flash silently keeps
# the old overlay: old passwords, old identity, old /etc/config, and
# /etc/uci-defaults still marked as already-run, so the new image's first-boot
# scripts never execute. The device boots the new squashfs wearing the old
# config and looks like the build did not take. Observed on a Pi 3.
#
# Padding with zeros fixes it for *every* writer — Pi Imager, Etcher, Rufus,
# dd — rather than only for our own flash.sh, and costs nothing in download
# size because a run of zeros is what compression is best at.
image_extent() {
  # The largest (first_lba + sector_count) across the four MBR primary entries,
  # in bytes. Entries live at offset 446, 16 bytes each, with the LBA at +8 and
  # the count at +12, both 32-bit little-endian.
  local img="$1" e off start count end max=0
  for e in 0 1 2 3; do
    off=$(( 446 + e * 16 ))
    start="$(od -An -tu4 -j "$(( off + 8 ))"  -N 4 "${img}" | tr -d ' ')"
    count="$(od -An -tu4 -j "$(( off + 12 ))" -N 4 "${img}" | tr -d ' ')"
    [ -n "${start}" ] && [ -n "${count}" ] && [ "${count}" -gt 0 ] || continue
    end=$(( start + count ))
    [ "${end}" -gt "${max}" ] && max="${end}"
  done
  echo $(( max * 512 ))
}

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
raw="${tmp}/${base}.img"

log "  padding to the full partition extent"
gunzip -c "${factory}" > "${raw}"
extent="$(image_extent "${raw}")"
actual="$(wc -c < "${raw}" | tr -d ' ')"

[ "${extent}" -gt 0 ] || die "could not read a partition table from ${factory}"

if [ "${extent}" -gt "${actual}" ]; then
  # A sparse extend: seek past the end and write nothing. The file reads back
  # as zeros without ever allocating the blocks, so this is instant.
  dd if=/dev/zero of="${raw}" bs=1 count=0 seek="${extent}" 2>/dev/null
  log "    ${actual} -> ${extent} bytes ($(( (extent - actual) / 1024 / 1024 ))MB of zeros)"
else
  log "    already full-length"
fi

# Re-assert it, because silently shipping a short image is the whole bug.
padded="$(wc -c < "${raw}" | tr -d ' ')"
[ "${padded}" -ge "${extent}" ] \
  || die "padding failed: ${padded} < ${extent}. A re-flash would keep the old overlay."

gzip -c -9 "${raw}" > "${DEST}/${base}.img.gz"

# xz as well: about 40% smaller than gz, which matters when somebody is
# fetching this over a hotel connection. Every SD writer takes either.
log "  compressing xz (this is the slow part)"
xz -T0 -6 -c "${raw}" > "${DEST}/${base}.img.xz"

[ -n "${sysupgrade}" ] && cp "${sysupgrade}" "${DEST}/${base}-sysupgrade.img.gz"

( cd "${DEST}" && for f in "${base}"*; do
    case "${f}" in *.sha256) continue ;; esac
    sha "${f}" > "${f}.sha256"
  done )

log "  $(cd "${DEST}" && ls -la "${base}"* | awk '{printf "%s (%s) ", $NF, $5}')"
