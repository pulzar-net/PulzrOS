#!/usr/bin/env bash
#
# Every board's facts, as JSON, read from boards/<id>/board.conf.
#
#   scripts/board-facts.sh            # a JSON array, one object per board
#
# The docs site's Hardware pages are generated from this (docs/.vitepress/),
# so what a page says about a board is what its image is built from. A table
# written by hand beside board.conf was out of date within a week: the
# features table listed four boards when there were fourteen.
#
# Sourced the way build.sh sources a board, one subshell each, so a board's
# values never leak into the next one's.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BOARDS_DIR="${ROOT_DIR}/boards"
export BOARDS_DIR

command -v jq >/dev/null || { echo "jq is required" >&2; exit 1; }

for dir in "${BOARDS_DIR}"/*/; do
  board="$(basename "${dir}")"
  [ "${board}" = common ] && continue
  (
    # shellcheck disable=SC1090
    . "${dir}board.conf" >/dev/null 2>&1

    # The comment block at the top of board.conf: what the board is, what has
    # been seen on a unit and what has not.
    header="$(awk '/^#/ { sub(/^# ?/, ""); print; next } { exit }' "${dir}board.conf")"

    readme=""
    [ -f "${dir}openwrt/README.md" ] && readme="boards/${board}/openwrt/README.md"

    jq -n \
      --arg id "${BOARD_ID}" \
      --arg name "${BOARD_NAME}" \
      --arg status "${BOARD_STATUS:-supported}" \
      --arg install "${BOARD_INSTALL:-}" \
      --arg openwrt "${OPENWRT_VERSION:-}" \
      --arg target "${OPENWRT_TARGET:-}" \
      --arg subtarget "${OPENWRT_SUBTARGET:-}" \
      --arg profile "${OPENWRT_PROFILE:-}" \
      --arg arch "${OPENWRT_ARCH:-}" \
      --arg deviceSupport "${OPENWRT_DEVICE_SUPPORT:-}" \
      --arg features "${PULZR_FEATURES:-}" \
      --arg slots "${PULZR_CONCENTRATOR_SLOTS:-}" \
      --arg part "${PULZR_CONCENTRATOR_PART:-}" \
      --arg model "${PULZR_CONCENTRATOR_MODEL:-}" \
      --arg configurable "${PULZR_CONCENTRATOR_CONFIGURABLE:-}" \
      --arg gps "${PULZR_GPS:-}" \
      --arg bt "${PULZR_BT:-}" \
      --arg display "${PULZR_DISPLAY:-}" \
      --arg usbGadget "${PULZR_USB_GADGET:-}" \
      --arg lanPorts "${PULZR_LAN_PORTS:-}" \
      --arg cellWan "${PULZR_WAN_CELL_ENABLED:-}" \
      --arg addons "${PULZR_ADDONS_BUILTIN:-}" \
      --arg leds "${PULZR_LEDS:-}" \
      --arg header "${header}" \
      --arg readme "${readme}" \
      'def words: split(" ") | map(select(. != ""));
       {
         id: $id, name: $name, status: $status, install: $install,
         openwrt: $openwrt, target: $target, subtarget: $subtarget,
         profile: $profile, arch: $arch, deviceSupport: $deviceSupport,
         features: ($features | words),
         slots: ($slots | words),
         part: $part, model: $model, configurable: ($configurable == "1"),
         gps: $gps, bluetooth: $bt, display: $display, usbGadget: $usbGadget,
         lanPorts: ($lanPorts | words),
         cellularWan: ($cellWan == "1"),
         builtinAddons: ($addons | words),
         leds: ($leds | split("\n") | map(gsub("^\\s+|\\s+$"; "")) | map(select(. != ""))
                | map(capture("^(?<sysfs>\\S+)\\s+(?<colour>\\S+)\\s+(?<role>\\S+)\\s+(?<label>.*)$"))),
         header: $header, readme: $readme
       }'
  )
done | jq -s 'sort_by(.id)'
