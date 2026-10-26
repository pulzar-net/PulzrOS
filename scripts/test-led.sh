#!/usr/bin/env bash
#
# Drive parkeze-led's RGB light against a fake /sys/class/leds.
#
#   scripts/test-led.sh
#
# The RAK7268's light breathes through the pattern trigger: hw_pattern when the
# driver can do it in the chip, the software pattern when it cannot, a steady
# light when the trigger module is missing. Which of the three a gateway gets
# depends on its kernel, and the only RAK7268 on a bench is not always there,
# so each is checked here against directories laid out the way the kernel lays
# them out.
#
# Run under bash, standing in for busybox ash.

set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LED="${ROOT_DIR}/feed/parkeze-io/files/usr/sbin/parkeze-led"

SANDBOX="$(mktemp -d)"
trap 'rm -rf "${SANDBOX}"' EXIT
export PARKEZE_LEDS="${SANDBOX}/leds"
export PARKEZE_LED_CACHE="${SANDBOX}/run"
export PARKEZE_BOARD_CONF="${SANDBOX}/board.conf"

cat > "${PARKEZE_BOARD_CONF}" <<'EOF'
PARKEZE_LED_LORA="green:lora"
PARKEZE_LED_CLOUD="rgb:status"
EOF

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

# fresh <hw|sw|none>: a light whose driver has hardware patterns, one that only
# gets the software pattern, or one with no pattern trigger at all. The kernel
# only shows pattern files while the pattern trigger is selected; a fake cannot
# make them appear on that write, so they are there from the start and the
# trigger file is what the checks read.
fresh() {
    rm -rf "${PARKEZE_LEDS}" "${PARKEZE_LED_CACHE}"
    local c
    for c in red green blue; do
        local d="${PARKEZE_LEDS}/${c}:status"
        mkdir -p "${d}"
        echo 255 > "${d}/max_brightness"
        echo 0 > "${d}/brightness"
        echo none > "${d}/trigger"
        case "$1" in
            hw) : > "${d}/pattern"; : > "${d}/hw_pattern" ;;
            sw) : > "${d}/pattern" ;;
        esac
    done
    mkdir -p "${PARKEZE_LEDS}/green:lora"
    echo 1 > "${PARKEZE_LEDS}/green:lora/max_brightness"
    echo 0 > "${PARKEZE_LEDS}/green:lora/brightness"
    echo none > "${PARKEZE_LEDS}/green:lora/trigger"
}

val() { cat "${PARKEZE_LEDS}/$1" 2>/dev/null; }

BREATH="0 2080 255 130 255 2080 0 260"

fresh hw
sh "${LED}" cloud path wired
check "wired breathes blue in hardware" "${BREATH}" "$(val blue:status/hw_pattern)"
check "the pattern trigger is selected" pattern "$(val blue:status/trigger)"
check "the software pattern is left alone" "" "$(val blue:status/pattern)"
check "red stays dark" "none 0" "$(val red:status/trigger) $(val red:status/brightness)"

fresh sw
sh "${LED}" cloud path cellular
check "cellular breathes red in software" "${BREATH}" "$(val red:status/pattern)"
check "and green in software" "${BREATH}" "$(val green:status/pattern)"
check "blue stays dark" "0" "$(val blue:status/brightness)"

fresh none
sh "${LED}" cloud breathe b
check "no pattern trigger: steady instead of dark" "255" "$(val blue:status/brightness)"

fresh hw
sh "${LED}" cloud path none
check "no backhaul is steady red" "none 255" "$(val red:status/trigger) $(val red:status/brightness)"
check "and nothing else" "0 0" "$(val green:status/brightness) $(val blue:status/brightness)"

fresh hw
sh "${LED}" cloud path wired
echo restarted > "${PARKEZE_LEDS}/blue:status/hw_pattern"
sh "${LED}" cloud path wired
check "the same state does not restart the breath" restarted "$(val blue:status/hw_pattern)"
sh "${LED}" cloud path cellular
check "a new state does" "${BREATH}" "$(val red:status/hw_pattern)"
check "and clears the old colour" "none 0" "$(val blue:status/trigger) $(val blue:status/brightness)"

PARKEZE_LED_BREATHE="1040 260 1040 130" sh "${LED}" cloud solid w
PARKEZE_LED_BREATHE="1040 260 1040 130" sh "${LED}" cloud breathe g
check "breath timing comes from PARKEZE_LED_BREATHE" "0 1040 255 260 255 1040 0 130" \
    "$(val green:status/hw_pattern)"

fresh hw
sh "${LED}" --has cloud; check "--has finds all three channels" 0 "$?"
rm -rf "${PARKEZE_LEDS}/green:status"
sh "${LED}" --has cloud; check "--has fails with one missing" 1 "$?"
sh "${LED}" cloud path wired; check "a missing light is not an error" 0 "$?"

fresh hw
sh "${LED}" lora on
check "a plain LED still lights" "1" "$(val green:lora/brightness)"

[ "${failures}" -eq 0 ] || { echo "${failures} failed"; exit 1; }
echo "all passed"
