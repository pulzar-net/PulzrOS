#!/usr/bin/env bash
#
# pulzr-hwdesc, pulzr-hwline and 20-pulzr-lora against fakes.
#
#   scripts/test-hwdesc.sh
#
# The descriptor reader decides, per unit, how many LoRa cards a RAK left the
# factory with and what it reports to Pulzr Cloud, and it must never let the
# unit's default passwords out; the line driver is what resets a modem, a card
# or a receiver. None of it can be checked on a bench without the one unit
# that has each fault, so it runs here: a factory partition laid out the way
# RAK writes it, a sysfs of named lines, and the hotplug events a card's
# re-enumeration sends.
#
# Run under bash, standing in for busybox ash.

set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HWDESC="${ROOT_DIR}/feed/pulzr-base/files/usr/sbin/pulzr-hwdesc"
HWLINE="${ROOT_DIR}/feed/pulzr-base/files/usr/sbin/pulzr-hwline"
LORA_HOTPLUG="${ROOT_DIR}/feed/pulzr-concentrator/files/etc/hotplug.d/tty/20-pulzr-lora"

command -v python3 >/dev/null 2>&1 || { echo "python3 is required (for the jsonfilter stub)" >&2; exit 2; }

SANDBOX="$(mktemp -d)"
trap 'rm -rf "${SANDBOX}"' EXIT
STUBS="${SANDBOX}/bin"
mkdir -p "${STUBS}"
export PATH="${STUBS}:${PATH}"

# jsonfilter -i <file> -e '@.A.B[*].c': dotted keys, [n] and [*].
cat > "${STUBS}/jsonfilter" <<'EOF'
#!/usr/bin/env python3
import json, re, sys
args = sys.argv[1:]
expr = args[args.index('-e') + 1]
src = open(args[args.index('-i') + 1]) if '-i' in args else sys.stdin
try:
    values = [json.load(src)]
except Exception:
    sys.exit(1)
for part in filter(None, expr[2:].split('.')):
    m = re.fullmatch(r'([^\[]*)(?:\[(\*|\d+)\])?', part)
    key, index = m.group(1), m.group(2)
    nxt = []
    for v in values:
        if key:
            if not isinstance(v, dict) or key not in v:
                continue
            v = v[key]
        if index == '*':
            nxt.extend(v if isinstance(v, list) else [])
        elif index is not None:
            if isinstance(v, list) and int(index) < len(v):
                nxt.append(v[int(index)])
        else:
            nxt.append(v)
    values = nxt
if not values:
    sys.exit(1)
for v in values:
    print(json.dumps(v) if isinstance(v, (dict, list)) else v)
EOF
printf '#!/bin/sh\nexit 0\n' > "${STUBS}/logger"
chmod +x "${STUBS}/jsonfilter" "${STUBS}/logger"

failures=0
check() {
    local what="$1" want="$2" got="$3"
    if [ "${got}" = "${want}" ]; then
        echo "ok   ${what}"
    else
        echo "FAIL ${what}: want '${want}', got '${got}'"
        failures=$((failures + 1))
    fi
}

# factory <json> [md5-override]: a factory partition with the descriptor at
# 0x2000, as RAK's 00_einfo reads it.
factory() {
    local json="$1" md5 len
    md5="${2:-$(printf '%s' "${json}" | md5sum | cut -c1-32)}"
    len="$(printf '%04x' "${#json}")"
    { head -c 8192 /dev/zero | tr '\0' '\377'; printf 'RAK%s0%s%s' "${md5}" "${len}" "${json}"; } \
        > "${SANDBOX}/factory"
    rm -f "${SANDBOX}/hwdesc.json"
}
export PULZR_HWDESC_MTD="${SANDBOX}/factory"
export PULZR_HWDESC_CACHE="${SANDBOX}/hwdesc.json"

# The bench RAK7289CV2's, with its serials and passwords replaced.
PRO='{"DEV_CORE": "RAK636", "DEV_NAME": "RAK7289CV2", "DEV_SERIAL_NUMBER": "TESTSERIAL1", "DEV_ROOT_DEFPW": "rootsecret", "DEV_WIFI_DEFPW": "wifisecret", "MAC_ADDRESS": "AC:1F:09:00:00:01", "LORA": {"band": "US915", "module": "RAK5146", "concentrator": [{"intf_type": "usb", "intf_path": "/dev/ttyACM0", "reset_pin": "17"}]}, "GPS": {"model": "ubx", "reset_pin": "16", "intf_path": "/dev/ttyS1"}, "WWAN": {"type": "2", "power_pin": "41", "reset_pin": "2"}, "DEV_CAPS": "dying_gasp solar_battery hwwdg lbt"}'

factory "${PRO}"
out="$(sh "${HWDESC}")"
check "the descriptor reads" 0 "$?"
check "the default passwords are not in it" "" "$(echo "${out}" | grep -o -E 'DEFPW|rootsecret|wifisecret')"
check "nor in the cache" "" "$(grep -o -E 'DEFPW|rootsecret|wifisecret' "${PULZR_HWDESC_CACHE}")"
check "what is left is still JSON" "RAK7289CV2" "$(jsonfilter -i "${PULZR_HWDESC_CACHE}" -e '@.DEV_NAME')"
check "caps" "dying_gasp solar_battery hwwdg lbt" "$(sh "${HWDESC}" caps)"
sh "${HWDESC}" has hwwdg; check "has hwwdg" 0 "$?"
sh "${HWDESC}" has breathing_light; check "has not breathing_light" 1 "$?"
check "get a nested value" "ubx" "$(sh "${HWDESC}" get GPS.model)"
check "one card fitted" 1 "$(sh "${HWDESC}" get 'LORA.concentrator[*].intf_type' | grep -c .)"

rm -f "${SANDBOX}/factory"
check "the cache answers once the partition is gone" "RAK7289CV2" "$(sh "${HWDESC}" get DEV_NAME)"

factory "${PRO}" 00000000000000000000000000000000
sh "${HWDESC}" >/dev/null 2>&1; check "a bad md5 is refused" 1 "$?"
check "and nothing is cached" no "$([ -e "${PULZR_HWDESC_CACHE}" ] && echo yes || echo no)"

head -c 9000 /dev/zero > "${SANDBOX}/factory"; rm -f "${PULZR_HWDESC_CACHE}"
sh "${HWDESC}" >/dev/null 2>&1; check "a board without one exits 1" 1 "$?"

factory '{"DEV_NAME": "RAK7268CV2", "DEV_CAPS": "breathing_light", "DEV_WIFI_DEFPW": "w", "DEV_ROOT_DEFPW": "r"}'
check "passwords as the last keys go too" '{"DEV_NAME": "RAK7268CV2", "DEV_CAPS": "breathing_light"}' "$(sh "${HWDESC}")"
check "no concentrators listed reads as none" 0 "$(sh "${HWDESC}" get 'LORA.concentrator[*].intf_type' 2>/dev/null | grep -c .)"

# ── pulzr-hwline ──────────────────────────────────────────────────────────
export PULZR_GPIO_SYSFS="${SANDBOX}/gpio"
mkdir -p "${PULZR_GPIO_SYSFS}/modem-reset"
echo 0 > "${PULZR_GPIO_SYSFS}/modem-reset/value"
# What the line holds while the pulse sleeps.
printf '#!/bin/sh\ncat "%s/modem-reset/value" >> "%s/during"\n' "${PULZR_GPIO_SYSFS}" "${SANDBOX}" > "${STUBS}/sleep"
chmod +x "${STUBS}/sleep"

sh "${HWLINE}" modem-reset; check "a board's line is there" 0 "$?"
sh "${HWLINE}" lora-reset; check "another board's is not" 1 "$?"
sh "${HWLINE}" lora-reset pulse; check "and pulsing it fails" 1 "$?"
sh "${HWLINE}" modem-reset pulse
check "a pulse asserts the line while it holds" 1 "$(cat "${SANDBOX}/during")"
check "and releases it after" 0 "$(cat "${PULZR_GPIO_SYSFS}/modem-reset/value")"
sh "${HWLINE}" modem-reset assert; check "assert" 1 "$(cat "${PULZR_GPIO_SYSFS}/modem-reset/value")"
sh "${HWLINE}" modem-reset release; check "release" 0 "$(cat "${PULZR_GPIO_SYSFS}/modem-reset/value")"

# ── 20-pulzr-lora ─────────────────────────────────────────────────────────
export PULZR_DEV_DIR="${SANDBOX}/dev"
mkdir -p "${PULZR_DEV_DIR}"
echo 'PULZR_LORA_USB_PORTS="1-1.2:1.0 1-1.3:1.0"' > "${SANDBOX}/board.conf"
export PULZR_BOARD_CONF="${SANDBOX}/board.conf"
hub=/devices/platform/101c0000.ehci/usb1/1-1

event() { ACTION="$1" DEVNAME="$2" DEVPATH="$3" sh "${LORA_HOTPLUG}"; }

event add ttyACM1 "${hub}/1-1.2/1-1.2:1.0/tty/ttyACM1"
check "slot 0's card is lora0 whatever its ttyACM" /dev/ttyACM1 "$(readlink "${PULZR_DEV_DIR}/lora0")"
event add ttyACM0 "${hub}/1-1.3/1-1.3:1.0/tty/ttyACM0"
check "slot 1's is lora1" /dev/ttyACM0 "$(readlink "${PULZR_DEV_DIR}/lora1")"
event remove ttyACM9 "${hub}/1-1.2/1-1.2:1.0/tty/ttyACM9"
check "a stale remove leaves the link" /dev/ttyACM1 "$(readlink "${PULZR_DEV_DIR}/lora0")"
event remove ttyACM1 "${hub}/1-1.2/1-1.2:1.0/tty/ttyACM1"
check "its own remove takes it away" no "$([ -L "${PULZR_DEV_DIR}/lora0" ] && echo yes || echo no)"
event add ttyACM2 "${hub}/1-1.4/1-1.4:1.0/tty/ttyACM2"
event add ttyUSB0 "${hub}/1-1.2/1-1.2:1.0/ttyUSB0/tty/ttyUSB0"
check "other ports and other ttys are left alone" "lora1" "$(ls "${PULZR_DEV_DIR}")"

[ "${failures}" -eq 0 ] || { echo "${failures} failed"; exit 1; }
echo "all passed"
