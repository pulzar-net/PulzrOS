#!/usr/bin/env bash
#
# Drive parkeze-cellular-watchdog through a dead link, a live one and the
# cases that must leave it alone, against stubs.
#
#   scripts/test-cellular-watchdog.sh
#
# Its mistakes are a gateway that never recovers or one that reboots for no
# reason, and neither shows on a bench in less than a day. The stub `sleep`
# is the clock: each call is one minute, it moves the receive counter the way
# the case needs, and it ends the run by killing the watchdog after N.

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

stub sleep 'n=$(( $(cat "$SANDBOX/ticks") + 1 )); echo $n > "$SANDBOX/ticks"
[ "$RX_MODE" = grow ] && echo $(( n * 100 )) > "$RX"
[ $n -ge "$TICKS" ] && kill $PPID; exit 0'
stub uci 'case "$3" in parkeze.cellular.modem_present) echo 1 ;; network.wwan.disabled) echo 0 ;; esac'
stub parkeze-backhaul-check 'case "$1" in
  --tunnel) echo "$TUNNEL" ;;
  --cellular) exit "$CELL_PROBE" ;;
  *) exit 1 ;;
esac'
stub ifstatus 'echo "{\"l3_device\":\"wwan0\"}"'
stub jsonfilter 'sed -n "s/.*\"l3_device\":\"\([^\"]*\)\".*/\1/p"'
stub logger 'exit 0'
stub ifup 'echo "ifup $*" >> "$ACTIONS"'
# A reset recreates the device, so its counter starts over.
stub mmcli 'echo "mmcli $*" >> "$ACTIONS"; echo 10 > "$RX"'
stub reboot 'echo reboot >> "$ACTIONS"'
stub pkill 'exit 1'

fail=0
run() {
  local name="$1" ticks="$2" rx_mode="$3" tunnel="$4" cell_probe="$5" uptime="$6" want="$7"
  echo 0 > "${SANDBOX}/ticks"; echo 5000 > "${RX}"; : > "${ACTIONS}"
  echo "${uptime}.00 0.00" > "${SANDBOX}/uptime"
  # Backgrounded and waited on, so bash does not announce the stub's kill.
  SANDBOX="${SANDBOX}" RX="${RX}" ACTIONS="${ACTIONS}" TICKS="${ticks}" RX_MODE="${rx_mode}" \
    TUNNEL="${tunnel}" CELL_PROBE="${cell_probe}" \
    PARKEZE_SYS_NET="${SANDBOX}/net" PARKEZE_UPTIME_FILE="${SANDBOX}/uptime" \
    PATH="${STUBS}:${PATH}" sh "${WATCHDOG}" 2>/dev/null &
  wait $! 2>/dev/null
  local got; got="$(paste -sd, "${ACTIONS}")"
  if [ "${got}" = "${want}" ]; then
    echo "ok    ${name}"
  else
    echo "FAIL  ${name}: want [${want}] got [${got}]"; fail=1
  fi
}

#   name                               ticks rx    tunnel  probe uptime want
run "dead link climbs to a reboot"     16    flat  waiting 1     25200 "ifup wwan,mmcli -m any --reset,reboot"
run "young gateway restarts the ladder" 21   flat  waiting 1     3600  "ifup wwan,mmcli -m any --reset,ifup wwan"
run "traffic flowing is left alone"    30    grow  waiting 1     25200 ""
run "idle but reachable is left alone" 30    flat  waiting 0     25200 ""
run "wired tunnel up is not judged"    30    flat  up      1     25200 ""

exit "${fail}"
