#!/usr/bin/env bash
#
# Drive parkeze-cellular-watchdog through a dead link, a stranded one, a live
# one and the cases that must leave it alone, against stubs.
#
#   scripts/test-cellular-watchdog.sh
#
# Its mistakes are a gateway that never recovers or one that reboots for no
# reason, and neither shows on a bench in less than a day. The stub `sleep`
# is the clock: each `sleep 60` is one look, it moves the receive counter the
# way the case needs, and it ends the run by killing the watchdog after N.
# netifd's and ModemManager's state live in files, so ifup and a modem reset
# can change them the way the real ones would.

set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WATCHDOG="${ROOT_DIR}/feed/parkeze-cellular/files/usr/sbin/parkeze-cellular-watchdog"

SANDBOX="$(mktemp -d)"
trap 'rm -rf "${SANDBOX}"' EXIT
STUBS="${SANDBOX}/bin"
mkdir -p "${STUBS}" "${SANDBOX}/net/wwan0/statistics"
RX="${SANDBOX}/net/wwan0/statistics/rx_bytes"
ACTIONS="${SANDBOX}/actions"

stub() { printf '#!/bin/sh\n%s\n' "$2" > "${STUBS}/$1"; chmod +x "${STUBS}/$1"; }

# Only the loop's own sleep is a look; the modem-detect follow-up and the
# buffer flush sleep for nothing.
stub sleep '[ "$1" = 60 ] || exit 0
n=$(( $(cat "$SANDBOX/ticks") + 1 )); echo $n > "$SANDBOX/ticks"
[ "$RX_MODE" = grow ] && echo $(( n * 100 )) > "$RX"
[ $n -ge "$TICKS" ] && kill $PPID; exit 0'
stub uci 'case "$3" in parkeze.cellular.modem_present) echo 1 ;; network.wwan.disabled) echo "$DISABLED" ;; esac'
stub parkeze-backhaul-check 'case "$1" in
  --tunnel) echo "$TUNNEL" ;;
  --cellular) exit "$CELL_PROBE" ;;
  *) exit 1 ;;
esac'
stub ifstatus 'printf "{\"up\":%s,\"pending\":%s,\"l3_device\":\"wwan0\",\"errors\":[{\"code\":\"X\"}]}" \
  "$(cat "$SANDBOX/up")" "$(cat "$SANDBOX/pending")"'
stub jsonfilter 'key="${2#@.}"; case "$key" in errors*) key=code ;; esac
sed -n "s/.*\"$key\":\"\{0,1\}\([^\",}]*\).*/\1/p"'
stub logger 'exit 0'
# With IFUP_FIXES the bearer comes up; without it netifd fails again.
stub ifup 'echo "ifup $*" >> "$ACTIONS"
[ -n "$IFUP_FIXES" ] && { echo connected > "$SANDBOX/mm"; echo true > "$SANDBOX/up"; }; exit 0'
# A reset recreates the device, so its counter starts over, and the modem
# comes back as RESET_TO when the case says how it does.
stub mmcli 'case "$*" in
  *--output-keyvalue*) echo "modem.generic.state : $(cat "$SANDBOX/mm")" ;;
  *--reset*) echo "mmcli $*" >> "$ACTIONS"; echo 10 > "$RX"
             [ -n "$RESET_TO" ] && { echo "$RESET_TO" > "$SANDBOX/mm"; echo false > "$SANDBOX/up"; } ;;
esac; exit 0'
stub reboot 'echo reboot >> "$ACTIONS"'
stub pkill 'exit 1'

fail=0
# run NAME TICKS RX TUNNEL PROBE UPTIME UP MODEM RESET_TO IFUP_FIXES DISABLED WANT
run() {
  local name="$1" ticks="$2" rx_mode="$3" tunnel="$4" cell_probe="$5" uptime="$6"
  echo 0 > "${SANDBOX}/ticks"; echo 5000 > "${RX}"; : > "${ACTIONS}"
  echo "${uptime}.00 0.00" > "${SANDBOX}/uptime"
  echo "$7" > "${SANDBOX}/up"; echo false > "${SANDBOX}/pending"; echo "$8" > "${SANDBOX}/mm"
  # Backgrounded and waited on, so bash does not announce the stub's kill.
  SANDBOX="${SANDBOX}" RX="${RX}" ACTIONS="${ACTIONS}" TICKS="${ticks}" RX_MODE="${rx_mode}" \
    TUNNEL="${tunnel}" CELL_PROBE="${cell_probe}" RESET_TO="$9" IFUP_FIXES="${10}" \
    DISABLED="${11}" \
    PARKEZE_SYS_NET="${SANDBOX}/net" PARKEZE_UPTIME_FILE="${SANDBOX}/uptime" \
    PATH="${STUBS}:${PATH}" sh "${WATCHDOG}" 2>/dev/null &
  wait $! 2>/dev/null
  local got; got="$(paste -sd, "${ACTIONS}")"
  if [ "${got}" = "${12}" ]; then
    echo "ok    ${name}"
  else
    echo "FAIL  ${name}: want [${12}] got [${got}]"; fail=1
  fi
}

R="mmcli -m any --reset"
I="ifup wwan"

# A link netifd and the modem call fine, judged by its traffic.
#   name                                 ticks rx   tunnel  probe uptime up    modem      reset_to fixes off want
run "dead link climbs to a reboot"       16    flat waiting 1     25200  true  connected  ""       ""    0   "$I,$R,reboot"
run "young gateway restarts the ladder"  21    flat waiting 1     3600   true  connected  ""       ""    0   "$I,$R,$I"
run "traffic flowing is left alone"      30    grow waiting 1     25200  true  connected  ""       ""    0   ""
run "idle but reachable is left alone"   30    flat waiting 0     25200  true  connected  ""       ""    0   ""
run "wired tunnel up is not judged"      30    flat up      1     25200  true  connected  ""       ""    0   ""

# A link netifd or the modem has given up on.
run "blocked wwan, modem registered"     10    grow waiting 1     25200  false registered ""       1     0   "$I"
run "up with no bearer"                  10    grow waiting 1     25200  true  registered ""       1     0   "$I"
run "SIM written off: reset, then up"    12    grow waiting 1     25200  false searching  disabled 1     0   "$R,$I"
run "refused for good backs off, reboots" 32   flat waiting 1     25200  false searching  disabled ""    0   "$R,$I,$I,$I,$I,$I,reboot"
run "refused, young: no reboot"          32    flat waiting 1     3600   false searching  disabled ""    0   "$R,$I,$I,$I,$I,$I"
run "refused behind a wired tunnel"      32    flat up      1     25200  false searching  disabled ""    0   "$R,$I,$I,$I,$I,$I"
run "cellular off in the console"        30    flat waiting 1     25200  false searching  disabled ""    1   ""

exit "${fail}"
