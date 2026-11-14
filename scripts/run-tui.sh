#!/usr/bin/env bash
#
# Run the terminal UI on a developer machine, against canned gateway state.
#
#   UCODE=/path/to/ucode scripts/run-tui.sh [--console]
#
# The TUI's pages are the real ones from feed/pulzr-tui; only api.uc is
# swapped for scripts/tui-fixture/api.uc, because the console's lib/ modules
# need uci and ubus, which a Mac does not have. Build ucode as the README's
# Development section describes.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UCODE="${UCODE:-ucode}"
command -v "${UCODE}" >/dev/null 2>&1 || { echo "ucode not found; set UCODE (see README, Development)." >&2; exit 2; }

TUI="${ROOT_DIR}/feed/pulzr-tui/files/usr/share/pulzr/tui"
SHARE="${ROOT_DIR}/feed/pulzr-base/files/usr/share/pulzr"

# A tree shaped like /usr/share/pulzr, with the fixture in place of api.uc.
DEV="$(mktemp -d)"
trap 'rm -rf "${DEV}"' EXIT
mkdir -p "${DEV}/tui"
for f in "${TUI}"/*.uc; do
  [ "$(basename "${f}")" = api.uc ] || ln -s "${f}" "${DEV}/tui/"
done
ln -s "${TUI}/pages" "${DEV}/tui/pages"
ln -s "${ROOT_DIR}/scripts/tui-fixture/api.uc" "${DEV}/tui/api.uc"
ln -s "${SHARE}/logo.uc" "${DEV}/logo.uc"
ln -s "${SHARE}/logo.txt" "${DEV}/logo.txt"

# -L beside the binary: a source build keeps fs.so and friends next to it.
PULZR_TUI_LIB="${DEV}/tui" "${UCODE}" -L "$(dirname "$(command -v "${UCODE}")")" -R \
  "${ROOT_DIR}/feed/pulzr-tui/files/usr/sbin/pulzr-tui" "$@"
