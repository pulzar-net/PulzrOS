#!/usr/bin/env bash
#
# Collect everything needed to port a board to OpenWrt, from a running unit.
#
#   scripts/harvest-device.sh root@192.168.230.1 rak7268c
#
# ── WHY THIS EXISTS ────────────────────────────────────────────────────────
#
# Adding a device to OpenWrt needs a device tree, a flash partition map, and an
# image recipe. Published specifications give you the SoC and roughly nothing
# else — not the partition offsets, not the GPIO assignments, not which pin the
# LoRa reset line is on.
#
# Guessing the partition map is the one that matters. Write an image with the
# wrong offsets and the unit does not boot and does not recover without a
# serial console and, on some boards, a clip-on SPI flasher. It is not a
# mistake worth making twice, and it is entirely avoidable: the running vendor
# firmware already knows, because it is OpenWrt underneath.
#
# So this asks the device. Everything it collects is fact rather than
# inference, and the output goes into devices/<board>/ as the raw material for
# the DTS.
#
# ── WHAT TO DO WITH THE OUTPUT ─────────────────────────────────────────────
#
# devices/<board>/devicetree.dts is the prize — reconstructed from the DTB the
# running kernel booted with, so it is exactly what the hardware is. It needs
# editing before OpenWrt will take it (vendor trees carry out-of-tree bindings
# and hardcoded paths), but every address in it is real.
#
# docs/src/content/docs/boards.md has the rest of the port: boards/<maker>/<board>/openwrt/.

set -uo pipefail

TARGET="${1:?usage: harvest-device.sh <user@host> <board-id>}"
BOARD="${2:?usage: harvest-device.sh <user@host> <board-id>}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${ROOT_DIR}/devices/${BOARD}"
mkdir -p "${OUT}"

say() { printf '\033[36m==>\033[0m %s\n' "$*"; }

# Run a command on the device, saving stdout. A missing tool on the far end is
# information too, so failures are recorded rather than aborting the harvest.
grab() {
  local name="$1"; shift
  local file="${OUT}/${name}"
  if ssh -o BatchMode=yes -o ConnectTimeout=10 "${TARGET}" "$*" > "${file}" 2>"${file}.err"; then
    [ -s "${file}" ] && rm -f "${file}.err" || { mv "${file}.err" "${file}.empty"; rm -f "${file}"; }
    printf '    %-24s %s\n' "${name}" "$( [ -s "${file}" ] && wc -c < "${file}" | tr -d ' ' || echo 'empty' )"
  else
    printf '    %-24s failed (see %s.err)\n' "${name}" "${name}"
  fi
}

say "Harvesting ${BOARD} from ${TARGET}"
ssh -o BatchMode=yes -o ConnectTimeout=10 "${TARGET}" true 2>/dev/null \
  || { echo "cannot reach ${TARGET} over SSH with key auth" >&2; exit 1; }

# ── identity ────────────────────────────────────────────────────────────────
say "Identity"
grab board.json      'ubus call system board 2>/dev/null'
grab cpuinfo         'cat /proc/cpuinfo'
grab model           'cat /proc/device-tree/model 2>/dev/null | tr -d "\\0"'
grab compatible      'cat /proc/device-tree/compatible 2>/dev/null | tr "\\0" "\\n"'
grab os-release      'cat /etc/os-release 2>/dev/null'
grab kernel          'uname -a'

# ── the device tree ─────────────────────────────────────────────────────────
#
# The single most valuable artifact. `dtc -I fs` walks the live
# /sys/firmware/devicetree and reconstructs source from it, so this is the
# hardware's own description rather than anybody's reading of a datasheet.
say "Device tree"
if ssh "${TARGET}" 'command -v dtc' >/dev/null 2>&1; then
  grab devicetree.dts 'dtc -I fs -O dts /sys/firmware/devicetree/base 2>/dev/null'
else
  echo "    dtc is not on the device — pulling the raw tree instead"
  # Fall back to tarring the sysfs tree and decompiling on this machine.
  ssh "${TARGET}" 'tar -cf - /sys/firmware/devicetree/base 2>/dev/null' \
    > "${OUT}/devicetree-base.tar" 2>/dev/null
  if command -v dtc >/dev/null 2>&1 && [ -s "${OUT}/devicetree-base.tar" ]; then
    tmp="$(mktemp -d)"
    tar -xf "${OUT}/devicetree-base.tar" -C "${tmp}" 2>/dev/null
    dtc -I fs -O dts "${tmp}/sys/firmware/devicetree/base" > "${OUT}/devicetree.dts" 2>/dev/null \
      && echo "    decompiled locally -> devicetree.dts"
    rm -rf "${tmp}"
  else
    echo "    install dtc locally (brew install dtc) and decompile devicetree-base.tar"
  fi
fi

# ── flash ───────────────────────────────────────────────────────────────────
#
# The partition map. Getting this wrong is what bricks a unit, so it is
# collected three ways and they should agree.
say "Flash layout"
grab mtd             'cat /proc/mtd'
grab mtd-sysfs       'for m in /sys/class/mtd/mtd[0-9]*; do echo "== $m"; for f in name size erasesize offset type; do [ -f "$m/$f" ] && echo "  $f=$(cat $m/$f)"; done; done'
grab partitions      'cat /proc/partitions'
grab flash-dmesg     'dmesg 2>/dev/null | grep -iE "spi|flash|mtd|partition|nand" | head -60'

# ── peripherals ─────────────────────────────────────────────────────────────
say "Peripherals"
grab leds            'ls -1 /sys/class/leds 2>/dev/null'
grab leds-detail     'for l in /sys/class/leds/*; do echo "== $(basename $l)"; cat "$l/trigger" 2>/dev/null | tr " " "\\n" | grep "\\[" ; done'
grab gpio            'cat /sys/kernel/debug/gpio 2>/dev/null'
grab gpiochips       'ls -1 /sys/class/gpio 2>/dev/null; command -v gpiodetect >/dev/null && gpiodetect'
grab buttons         'cat /etc/config/system 2>/dev/null | grep -A6 button'
grab spi             'ls -l /dev/spidev* 2>/dev/null; ls -1 /sys/class/spi_master 2>/dev/null'
grab tty             'ls -l /dev/tty[A-Z]* /dev/ttyUSB* /dev/ttyACM* 2>/dev/null'
grab i2c             'ls -1 /sys/class/i2c-dev 2>/dev/null'
grab usb             'cat /sys/kernel/debug/usb/devices 2>/dev/null | head -60; lsusb 2>/dev/null'
grab network         'ip -o link 2>/dev/null; swconfig list 2>/dev/null'
grab wireless        'iw dev 2>/dev/null; iw phy 2>/dev/null | head -40'

# ── the vendor's own configuration ──────────────────────────────────────────
#
# Not for copying — it is theirs — but it says which GPIO drives which LED and
# where the concentrator lives, which is exactly what the board file needs.
say "Vendor configuration"
grab uci-all         'uci show 2>/dev/null'
grab lora-config     'find / -name "global_conf*.json" -o -name "local_conf.json" 2>/dev/null | head -20'
grab lora-detail     'for f in $(find / -name "global_conf*.json" 2>/dev/null | head -3); do echo "== $f"; head -40 "$f"; done'
grab modules         'lsmod 2>/dev/null'
grab kernel-config   'zcat /proc/config.gz 2>/dev/null | grep -vE "^#|^$" | head -200'

# ── summary ─────────────────────────────────────────────────────────────────
say "Collected into devices/${BOARD}/"
ls -la "${OUT}" | tail -n +2 | awk '{printf "    %-28s %s\n", $NF, $5}'

cat <<EOF

Next:

  1. Check devices/${BOARD}/mtd against devicetree.dts — the partition map has
     to match exactly, and it is what bricks a unit if it does not.
  2. Read devices/${BOARD}/devicetree.dts for the LoRa reset GPIO, the LED
     pins and the SPI chip selects, and put them in boards/<maker>/${BOARD}/board.conf.
  3. Put the DTS and an OpenWrt patch in boards/<maker>/${BOARD}/openwrt/ (https://oss.pulzr.net/PulzrOS/boards.html).
EOF
