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
# So this picks the one that belongs on a blank card, renames it to something
# legible, and emits the metadata Raspberry Pi Imager needs to offer ParkezeOS
# as a selectable OS rather than making anybody hunt for a file at all.
#
# ── FORMATS ────────────────────────────────────────────────────────────────
#
# Both .img.gz and .img.xz, because the tools disagree:
#
#   .img.gz   what OpenWrt produced. Etcher, Rufus and dd all take it.
#   .img.xz   roughly 40% smaller, and what Pi Imager's own OS list uses.
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

cp "${factory}" "${DEST}/${base}.img.gz"

# Pi Imager wants the uncompressed size and checksum, so the image is expanded
# once here rather than by every consumer.
tmp="$(mktemp -d)"
gunzip -c "${factory}" > "${tmp}/${base}.img"
extract_size="$(wc -c < "${tmp}/${base}.img" | tr -d ' ')"
extract_sha="$(sha "${tmp}/${base}.img")"

log "  compressing xz (this is the slow part)"
xz -T0 -6 -c "${tmp}/${base}.img" > "${DEST}/${base}.img.xz"
rm -rf "${tmp}"

download_size="$(wc -c < "${DEST}/${base}.img.xz" | tr -d ' ')"
download_sha="$(sha "${DEST}/${base}.img.xz")"

[ -n "${sysupgrade}" ] && cp "${sysupgrade}" "${DEST}/${base}-sysupgrade.img.gz"

# ── the Pi Imager entry ─────────────────────────────────────────────────────
#
# One fragment per board; the release job concatenates them into os_list.json.
# Written here because this is where the checksums are already computed.
#
# ONLY WHEN THERE IS SOMEWHERE PUBLIC TO SERVE THE IMAGES FROM.
#
# Raspberry Pi Imager fetches the OS list and the images with no credentials,
# so every URL in this file has to be reachable anonymously. This repository is
# private and its release assets are not — pointing Imager at a GitHub release
# URL gets a 404 and an empty OS menu, with nothing on screen saying why.
#
# So the base URL is required rather than defaulted. Set it to wherever the
# images are actually published:
#
#   PARKEZE_IMAGE_BASE_URL=https://downloads.parkeze.net/os/v0.1.0
#
# With it unset we emit no fragment at all, and the release simply carries the
# image files — which is the honest outcome, and still works with every SD
# writer including Imager's "Use custom".
#
# `init_format: none` matters: without it Pi Imager offers to preset a hostname,
# WiFi and SSH keys, writes them into a Raspberry Pi OS-shaped config that
# OpenWrt does not read, and the user concludes the image is broken.
if [ -z "${PARKEZE_IMAGE_BASE_URL:-}" ]; then
  log "  no PARKEZE_IMAGE_BASE_URL — skipping the Pi Imager entry"
  log "  (Imager needs anonymously-reachable URLs; this repo is private)"
elif [ -n "${BOARD_PI_IMAGER_DEVICES:-}" ]; then
  devices="$(printf '%s' "${BOARD_PI_IMAGER_DEVICES}" \
             | tr ' ' '\n' | grep -v '^$' | sed 's/.*/"&"/' | paste -sd, -)"
  cat > "${DEST}/${base}.oslist.json" <<EOF
{
  "name": "ParkezeOS ${VERSION} (${BOARD_NAME})",
  "description": "Parkeze LoRaWAN gateway — ${BOARD_NAME}. Adopts itself into parkeze.net; scan the code it shows on first boot.",
  "icon": "${PARKEZE_IMAGER_ICON_URL:-${PARKEZE_IMAGE_BASE_URL%/}/parkeze.png}",
  "url": "${PARKEZE_IMAGE_BASE_URL%/}/${base}.img.xz",
  "release_date": "$(date -u +%Y-%m-%d)",
  "extract_size": ${extract_size},
  "extract_sha256": "${extract_sha}",
  "image_download_size": ${download_size},
  "image_download_sha256": "${download_sha}",
  "devices": [${devices}],
  "init_format": "none"
}
EOF
fi

( cd "${DEST}" && for f in "${base}"*; do
    case "${f}" in *.sha256|*.oslist.json) continue ;; esac
    sha "${f}" > "${f}.sha256"
  done )

log "  $(cd "${DEST}" && ls -la "${base}"* | awk '{printf "%s (%s) ", $NF, $5}')"
