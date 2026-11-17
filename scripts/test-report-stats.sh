#!/usr/bin/env bash
#
# Drive pulzr-report-stats against a stubbed /proc and /sys.
#
#   scripts/test-report-stats.sh
#
# The stats section rides the report, so its mistakes are a report Pulzar Cloud
# rejects whole (bad JSON), a report held up by a hung modem, or a CPU figure
# that is a lie after a reboot. None shows on a bench. Each case builds the
# files and command answers one board family would have and checks the object
# that comes out, including that a field the board cannot read is absent.

set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATS="${ROOT_DIR}/feed/pulzr-adopt/files/usr/sbin/pulzr-report-stats"

command -v python3 >/dev/null 2>&1 || { echo "python3 is required (for the jsonfilter stub)" >&2; exit 2; }

SANDBOX="$(mktemp -d)"
trap 'rm -rf "${SANDBOX}"' EXIT
BIN="${SANDBOX}/bin"
mkdir -p "${BIN}"
export PULZR_STATS_PROC="${SANDBOX}/proc"
export PULZR_STATS_SYS="${SANDBOX}/sys"
export PULZR_STATS_STATE="${SANDBOX}/cpu.state"
export PATH="${BIN}:${PATH}"

pass=0; fail=0
check() {
    if [ "$2" = "$3" ]; then pass=$((pass + 1)); else
        fail=$((fail + 1)); echo "FAIL: $1"; echo "  want: $2"; echo "  got:  $3"
    fi
}

stub() { printf '#!/bin/sh\n%s\n' "$2" > "${BIN}/$1"; chmod +x "${BIN}/$1"; }
unstub() { rm -f "${BIN}/$1"; }

# The image has no `timeout`, so neither does this test: the stub fails the
# way a gateway does. The stub that used to stand in for it passed every case
# here while every real report sent `{}`.
stub timeout 'echo "timeout: not found" >&2; exit 127'
cp "${ROOT_DIR}/feed/pulzr-base/files/usr/sbin/pulzr-timeout" "${BIN}/pulzr-timeout"

cat > "${BIN}/jsonfilter" <<'EOF'
#!/usr/bin/env python3
import json, sys
expr = sys.argv[sys.argv.index('-e') + 1]
try:
    value = json.load(sys.stdin)
    if expr.startswith('@[*].interfaces['):
        value = [i['ifname'] for r in value.values() for i in r['interfaces'] if i['section'] == 'parkeze_sta'][0]
    else:
        import re
        for name, idx in re.findall(r'\.(\w+)|\[(\d+)\]', expr[1:]):
            value = value[name] if name else value[int(idx)]
except Exception:
    sys.exit(1)
if value is None:
    sys.exit(1)
if isinstance(value, bool):
    print('true' if value else 'false')
elif isinstance(value, (dict, list)):
    print(json.dumps(value))
else:
    print(value)
EOF
chmod +x "${BIN}/jsonfilter"

# A board with everything: a stock RAK-class gateway on a cable, a SIM and a
# saved WiFi, with the LoRa buffer running.
full_board() {
    rm -rf "${PULZR_STATS_PROC}" "${PULZR_STATS_SYS}" "${PULZR_STATS_STATE}"
    mkdir -p "${PULZR_STATS_PROC}" "${PULZR_STATS_SYS}/class/thermal/thermal_zone0"
    for d in eth0 wlan0-sta wwan0; do mkdir -p "${PULZR_STATS_SYS}/class/net/${d}/statistics"; done
    echo "1000.00 900.00" > "${PULZR_STATS_PROC}/uptime"
    echo "cpu  100 0 100 700 100 0 0 0 0 0" > "${PULZR_STATS_PROC}/stat"
    printf 'MemTotal:  1000 kB\nMemFree: 100 kB\nMemAvailable: 250 kB\n' > "${PULZR_STATS_PROC}/meminfo"
    echo 48500 > "${PULZR_STATS_SYS}/class/thermal/thermal_zone0/temp"
    echo 1000 > "${PULZR_STATS_SYS}/class/net/eth0/statistics/rx_bytes"
    echo 2000 > "${PULZR_STATS_SYS}/class/net/eth0/statistics/tx_bytes"
    echo 30 > "${PULZR_STATS_SYS}/class/net/wlan0-sta/statistics/rx_bytes"
    echo 40 > "${PULZR_STATS_SYS}/class/net/wlan0-sta/statistics/tx_bytes"
    echo 5 > "${PULZR_STATS_SYS}/class/net/wwan0/statistics/rx_bytes"
    echo 6 > "${PULZR_STATS_SYS}/class/net/wwan0/statistics/tx_bytes"
    stub df 'printf "Filesystem 1K-blocks Used Available Use%% Mounted on\n/dev/x 1000 420 580 42%% /overlay\n"'
    stub uci 'echo Home'
    stub ubus 'echo "{\"radio0\":{\"interfaces\":[{\"section\":\"parkeze_sta\",\"ifname\":\"wlan0-sta\"}]}}"'
    stub iwinfo 'echo "          Signal: -61 dBm  Noise: -95 dBm"'
    stub pulzr-uplinks 'echo "{\"uplinks\":[{\"iface\":\"wan\",\"kind\":\"ethernet\",\"device\":\"eth0\"},{\"iface\":\"wwifi\",\"kind\":\"wifi\",\"device\":\"wlan0-sta\"},{\"iface\":\"wwan\",\"kind\":\"cellular\",\"device\":\"wwan0\"}]}"'
    stub pulzr-lora-buffer 'echo "{\"enabled\":true,\"running\":true}"'
    stub mosquitto_sub 'echo 17'
    stub pulzr-modem-detect 'echo "{\"present\":true,\"kind\":\"qmi\",\"index\":0}"'
    # As mmcli answers: dBm only from --signal-get, and only once netifd has
    # set a refresh rate (wwan's signalrate); plain -m has a percentage.
    stub mmcli 'case "$*" in
        *--signal-get*) printf "modem.signal.refresh.rate : 60\nmodem.signal.lte.rssi : -73.00\nmodem.signal.lte.rsrp : -101.00\n" ;;
        *) printf "modem.generic.state : connected\nmodem.generic.signal-quality.value : 54\n" ;;
    esac'
}

run() { sh "${STATS}" 2>/dev/null; }
valid() { printf '%s' "$1" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null && echo valid || echo invalid; }

# ── the first report: everything but CPU ────────────────────────────────────
full_board
got="$(run)"
check "first report is JSON" valid "$(valid "${got}")"
check "first report has no CPU" "" "$(echo "${got}" | grep -o 'cpuPercent' || true)"
check "first report" \
  '{"memoryUsedPercent":75.0,"temperatureC":48.5,"storageUsedPercent":42,"bufferDepth":17,"signalDbm":{"wifi":-61,"cellular":-73},"traffic":{"wired":{"rxBytes":1000,"txBytes":2000},"wifi":{"rxBytes":30,"txBytes":40},"cellular":{"rxBytes":5,"txBytes":6}}}' \
  "${got}"

# ── the second: CPU is the delta since the first ────────────────────────────
echo "21600.00 20000.00" > "${PULZR_STATS_PROC}/uptime"
echo "cpu  400 0 300 1500 200 0 0 0 0 0" > "${PULZR_STATS_PROC}/stat"
# busy 500 of 1400 jiffies since the first sample
got="$(run)"
check "second report CPU" "1" "$(echo "${got}" | grep -c '"cpuPercent":35.7')"

# A report a few seconds later is not a sample, and does not move the earlier one.
echo "21630.00 20000.00" > "${PULZR_STATS_PROC}/uptime"
echo "cpu  900 0 300 1500 200 0 0 0 0 0" > "${PULZR_STATS_PROC}/stat"
check "report inside a minute has no CPU" "" "$(run | grep -o 'cpuPercent' || true)"

# A reboot: the counters start over and the sample is not taken from them.
echo "30.00 20.00" > "${PULZR_STATS_PROC}/uptime"
echo "cpu  5 0 5 90 0 0 0 0 0 0" > "${PULZR_STATS_PROC}/stat"
check "report after a reboot has no CPU" "" "$(run | grep -o 'cpuPercent' || true)"

# ── a board that can read little: no thermal zone, no radios, no buffer ─────
full_board
rm -rf "${PULZR_STATS_SYS}/class/thermal" "${PULZR_STATS_SYS}/class/net/wlan0-sta" "${PULZR_STATS_SYS}/class/net/wwan0"
for c in iwinfo mmcli mosquitto_sub pulzr-lora-buffer pulzr-modem-detect; do unstub "${c}"; done
stub pulzr-uplinks 'echo "{\"uplinks\":[{\"iface\":\"wan\",\"kind\":\"ethernet\",\"device\":\"eth0\"}]}"'
got="$(run)"
check "minimal board is JSON" valid "$(valid "${got}")"
check "minimal board" \
  '{"memoryUsedPercent":75.0,"storageUsedPercent":42,"traffic":{"wired":{"rxBytes":1000,"txBytes":2000}}}' \
  "${got}"

# ── no pulzr-uplinks: no traffic; no df answer falls through to / ───────────
unstub pulzr-uplinks
stub df 'case "$3" in /overlay) exit 1 ;; esac; printf "Filesystem 1K-blocks Used Available Use%% Mounted on\n/dev/x 1000 700 300 70%% /\n"'
check "no uplinks, root storage" '{"memoryUsedPercent":75.0,"storageUsedPercent":70}' "$(run)"

# ── no refresh rate set: mmcli has no dBm, and a percentage is not one ──────
# What a bench Pi answered on 0.4.0-rc3 before wwan had a signalrate.
full_board
stub mmcli 'case "$*" in
    *--signal-get*) printf "modem.signal.refresh.rate : 0\nmodem.signal.lte.rssi : --\nmodem.signal.lte.rsrp : --\n" ;;
    *) printf "modem.generic.state : connected\nmodem.generic.signal-quality.value : 80\n" ;;
esac'
check "no dBm from a percentage" "" "$(run | grep -o '"cellular":-' || true)"
# A HiLink dongle has no index to ask.
stub pulzr-modem-detect 'echo "{\"present\":true,\"kind\":\"hilink\"}"'
stub mmcli 'exit 99'
check "hilink has no cellular signal" '"signalDbm":{"wifi":-61}' "$(run | grep -o '"signalDbm":{[^}]*}')"

# ── a buffer that is not running is not asked ───────────────────────────────
stub pulzr-lora-buffer 'echo "{\"enabled\":true,\"running\":false}"'
stub mosquitto_sub 'echo 99'
check "stopped buffer has no depth" "" "$(run | grep -o 'bufferDepth' || true)"

# ── garbage from the commands never reaches the JSON ────────────────────────
full_board
stub mosquitto_sub 'echo "x\"y"'
stub iwinfo 'echo "Signal: unknown"'
echo "not a number" > "${PULZR_STATS_SYS}/class/thermal/thermal_zone0/temp"
got="$(run)"
check "garbage is JSON" valid "$(valid "${got}")"
check "garbage is left out" "" "$(echo "${got}" | grep -o 'bufferDepth\|temperatureC\|"wifi":-' || true)"

echo "${pass} passed, ${fail} failed"
[ "${fail}" -eq 0 ]
