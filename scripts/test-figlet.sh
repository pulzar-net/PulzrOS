#!/usr/bin/env bash
#
# Verify parkeze-figlet against the real thing.
#
#   UCODE=/path/to/ucode scripts/test-figlet.sh
#
# The renderer exists because OpenWrt does not package figlet (see the script's
# own header). A reimplementation of somebody else's format is only trustworthy
# if it is checked against the original, so this diffs the two over inputs that
# exercise every smushing rule the slant font asks for.
#
# `-w 9999` disables figlet's line wrapping, which is the one behaviour
# parkeze-figlet deliberately does not implement.
#
# Skips itself if figlet is not installed, so it can live in CI without making
# figlet a build requirement: `brew install figlet` / `apt-get install figlet`.

set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UCODE="${UCODE:-ucode}"
FONT="${ROOT_DIR}/feed/parkeze-base/files/usr/share/parkeze/fonts/slant.flf"
RENDERER="${ROOT_DIR}/feed/parkeze-base/files/usr/sbin/parkeze-figlet"

command -v figlet >/dev/null 2>&1 || {
  echo "figlet is not installed — skipping the renderer comparison."
  echo "  brew install figlet   /   apt-get install figlet"
  exit 0
}
command -v "${UCODE}" >/dev/null 2>&1 || {
  echo "ucode not found; set UCODE=/path/to/ucode" >&2
  exit 2
}

# The native modules live beside the ucode binary in a source build.
MODULES="$(dirname "$(command -v "${UCODE}")")/*.so"

CASES=(
  'Parkeze'
  'Parkeze Gateway'
  'parkeze-a1b2c3d4'
  'rpi3'
  'rpi5'
  'RAK7289CV2'
  'AB'
  'Hello, World!'
  'iii'
  'WWW'
  '|/\[]{}()<>_'
  '0123456789'
  'The quick brown fox jumps'
  'a'
  ' '
)

pass=0; fail=0
for text in "${CASES[@]}"; do
  expected="$(figlet -f "${FONT}" -w 9999 -- "${text}" 2>/dev/null)"
  actual="$("${UCODE}" -R -L "${MODULES}" "${RENDERER}" -f "${FONT}" -- "${text}" 2>&1)"
  if [ "${expected}" = "${actual}" ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "FAIL: ${text}"
    diff <(printf '%s\n' "${expected}") <(printf '%s\n' "${actual}") | sed 's/^/    /'
  fi
done

echo
if [ "${fail}" -gt 0 ]; then
  echo "${fail} of $((pass + fail)) cases differ from figlet"
  exit 1
fi
echo "${pass} cases render identically to figlet"
