#!/usr/bin/env bash
#
# pulzr-radios, the shell around pulzr-probe, against stubs.
#
#   scripts/test-usb-radios.sh
#
# pulzr-probe itself is tested in pulzr-edge against sysfs fixtures. What is
# the gateway's is here: a burst of hotplug events becomes one scan, Pulzar
# Cloud is told only when the list changed and only once adopted, the claim
# report gets the list or null, and a radio id that arrived over the network
# never reaches pulzr-probe unless it is one.

set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RADIOS="${ROOT_DIR}/feed/pulzr-probe/files/usr/sbin/pulzr-radios"

command -v python3 >/dev/null 2>&1 || { echo "python3 is required (for the jsonfilter stub)" >&2; exit 2; }

SANDBOX="$(mktemp -d)"
trap 'rm -rf "${SANDBOX}"' EXIT
STUBS="${SANDBOX}/bin"
mkdir -p "${STUBS}"

# Writes the list in ${FAKE_LIST} to --report, as pulzr-probe would; logs
# every call, and fails for `identify` when ${FAKE_IDENTIFY_FAILS} is set.
cat > "${STUBS}/pulzr-probe" <<'EOF'
#!/bin/sh
echo "$*" >> "${SANDBOX}/probe.log"
report=""
while [ $# -gt 0 ]; do
    case "$1" in
        --report) report="$2"; shift ;;
        --lan) shift ;;
        identify) [ -n "${FAKE_IDENTIFY_FAILS:-}" ] && { echo "pulzr-probe: did not answer" >&2; exit 1; } ;;
    esac
    shift
done
cat "${FAKE_LIST}" > "${report}"
cat "${FAKE_LIST}"
EOF
cat > "${STUBS}/pulzr-claim" <<'EOF'
#!/bin/sh
echo "$*" >> "${SANDBOX}/claim.log"
EOF
cat > "${STUBS}/pulzr-mqtt-agent" <<'EOF'
#!/bin/sh
echo "$*" >> "${SANDBOX}/agent.log"
EOF
cat > "${STUBS}/uci" <<'EOF'
#!/bin/sh
[ "$1" = "-q" ] && shift
[ "$1 $2" = "get pulzr.adoption.state" ] && cat "${SANDBOX}/adoption" 2>/dev/null
EOF
printf '#!/bin/sh\nshift; exec "$@"\n' > "${STUBS}/pulzr-timeout"
printf '#!/bin/sh\nexit 1\n' > "${STUBS}/ubus"
printf '#!/bin/sh\nexit 0\n' > "${STUBS}/logger"
cat > "${STUBS}/jsonfilter" <<'EOF'
#!/usr/bin/env python3
import json, sys
args = sys.argv[1:]
src = open(args[args.index('-i') + 1]) if '-i' in args else sys.stdin
try:
    value = json.load(src)
except Exception:
    sys.exit(1)
expr = args[args.index('-e') + 1]
if expr == '@.detected[*].label':
    for r in value['detected']:
        print(r.get('label', ''))
    sys.exit(0)
# The few paths the scripts use: @, @.<field>, @.detected[@.id='<id>'].<field>.
import re
m = re.fullmatch(r"@\.detected\[@\.id='([^']*)'\]\.(\w+)", expr)
if m:
    found = [r for r in value.get('detected', []) if r.get('id') == m.group(1)]
    value = found[0].get(m.group(2)) if found else None
elif expr != '@':
    for part in expr[2:].split('.'):
        value = value.get(part) if isinstance(value, dict) else None
if value is None:
    sys.exit(1)
print(value if isinstance(value, str) else json.dumps(value))
EOF
# Each module's binary (pulzr-edge-zigbee, ...), as its add-on installs it:
# `radio <id> status` answers ${SANDBOX}/status-<id>.json, or exits 3 as when
# no module runs there.
EDGE_BIN="${SANDBOX}/edge-bin"
mkdir -p "${EDGE_BIN}"
for m in zigbee zwave matter; do
cat > "${EDGE_BIN}/pulzr-edge-${m}" <<'EOF'
#!/bin/sh
echo "$(basename "$0") $*" >> "${SANDBOX}/edge.log"
[ "$1 $3" = "radio status" ] && [ -f "${SANDBOX}/status-$2.json" ] && { cat "${SANDBOX}/status-$2.json"; exit 0; }
echo "No radio module is running on that radio." >&2
exit 3
EOF
chmod +x "${EDGE_BIN}/pulzr-edge-${m}"
done
cat > "${SANDBOX}/init" <<'EOF'
#!/bin/sh
echo "$*" >> "${SANDBOX}/init.log"
EOF
chmod +x "${SANDBOX}/init"
if ! command -v md5sum >/dev/null 2>&1; then
    printf '#!/bin/sh\n[ -f "$1" ] || exit 1\nmd5 -q "$1"\n' > "${STUBS}/md5sum"
fi
chmod +x "${STUBS}"/*

export PATH="${STUBS}:${PATH}" SANDBOX
export PULZR_PROBE_RUN="${SANDBOX}/run" PULZR_PROBE_SETTLE=1 FAKE_LIST="${SANDBOX}/list.json"
export PULZR_EDGE_RADIOS="${SANDBOX}/edge-radios" PULZR_EDGE_RUN="${SANDBOX}/edge-run" PULZR_EDGE_INIT="${SANDBOX}/init"
# Every protocol's module installed, until the test of a gateway locked off one.
export PULZR_EDGE_BIN="${EDGE_BIN}"

fail=0
pass=0
check() {
    local what="$1"; shift
    if "$@"; then pass=$((pass + 1)); else echo "FAIL: ${what}"; fail=1; fi
}
radios() { bash "${RADIOS}" "$@" 2>/dev/null; }
not() { ! "$@"; }
calls() { local n; n="$(grep -c -e "$2" "${SANDBOX}/$1.log" 2>/dev/null)"; echo "${n:-0}"; }
fresh() { rm -f "${SANDBOX}"/*.log; }
# What `tell` starts runs in the background: a check that something was sent
# waits for it (up to 5 s, for a loaded machine), and one that nothing was
# gives it half a second to show up.
settle() { sleep 0.5; }
until_calls() {
    local i=0
    while [ "$(calls "$1" "$2")" != "$3" ] && [ "${i}" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
}

ZBT='{"detected":[{"id":"usb-10c4_ea60-9e2adbd1","bus":"usb","label":"Home Assistant Connect ZBT-1","state":"free","since":1}]}'
BOTH='{"detected":[{"id":"usb-10c4_ea60-9e2adbd1","bus":"usb","label":"Home Assistant Connect ZBT-1","state":"free","since":1},{"id":"usb-1a86_55d4-1-1.3","bus":"usb","label":"USB serial adapter (CH9102)","state":"unidentified","since":2}]}'

# ── not adopted: scans, tells nobody ────────────────────────────────────────
echo "${ZBT}" > "${FAKE_LIST}"
radios scan; settle
check "a scan writes the report" grep -q ZBT-1 "${PULZR_PROBE_RUN}/radios.json"
check "the LAN list falls back to {} without umdns" [ "$(cat "${PULZR_PROBE_RUN}/mdns.json")" = '{}' ]
check "not adopted: nothing sent" [ "$(calls claim radios)" = 0 ]

# ── adopted: told on a change only ──────────────────────────────────────────
echo adopted > "${SANDBOX}/adoption"
fresh
radios scan; settle
check "the same list says nothing" [ "$(calls claim radios)" = 0 ]
echo "${BOTH}" > "${FAKE_LIST}"
radios scan; until_calls claim radios 1; until_calls agent --publish-state 1
check "a new radio sends the list" [ "$(calls claim radios)" = 1 ]
check "and publishes the MQTT state again" [ "$(calls agent --publish-state)" = 1 ]
echo "${ZBT}" > "${FAKE_LIST}"
fresh
radios scan --quiet; settle
check "--quiet never tells" [ "$(calls claim radios)" = 0 ]

# ── a burst of hotplug events is one scan ───────────────────────────────────
echo "${BOTH}" > "${FAKE_LIST}"
fresh
for _ in 1 2 3 4 5 6; do radios hotplug; done
until_calls claim radios 1; settle
check "six events, one scan" [ "$(calls probe --report)" = 1 ]
check "and one list sent" [ "$(calls claim radios)" = 1 ]

# ── facts, for the claim report ─────────────────────────────────────────────
age() { touch -t 202001010000 "${PULZR_PROBE_RUN}/radios.json"; }
fresh
check "facts prints the list, and no networks" [ "$(radios facts)" = "${BOTH%\}},\"networks\":[]}" ]
check "a list scanned this minute is not scanned again" [ "$(calls probe --report)" = 0 ]
age; echo '{"detected":[]}' > "${FAKE_LIST}"
check "an empty list is still a list" [ "$(radios facts)" = '{"detected":[],"networks":[]}' ]
age; echo '{"detected":[{' > "${FAKE_LIST}"
check "an unreadable list is null" [ "$(radios facts)" = null ]

# ── ids from the network ────────────────────────────────────────────────────
echo "${ZBT}" > "${FAKE_LIST}"
fresh
for bad in 'usb-x;reboot' '../../etc/passwd' 'wlan0' 'usb-$(id)' 'USB-10C4' ''; do
    check "identify refuses ${bad:-an empty id}" not radios identify "${bad}"
done
check "assign refuses a use it does not know" not radios assign usb-10c4_ea60-1 zigbee
check "nothing reached pulzr-probe" [ "$(calls probe .)" = 0 ]

check "identify runs pulzr-probe's identify" eval 'radios identify usb-1a86_55d4-1-1.3 >/dev/null'
check "with the id" [ "$(calls probe 'identify usb-1a86_55d4-1-1.3')" = 1 ]
check "assign modbus runs pulzr-probe's assign" eval 'radios assign usb-1a86_55d4-1-1.3 modbus >/dev/null'
check "with the use" [ "$(calls probe 'assign usb-1a86_55d4-1-1.3 modbus')" = 1 ]
FAKE_IDENTIFY_FAILS=1 radios identify usb-1a86_55d4-1-1.3 && rc=0 || rc=$?
check "a radio that did not answer is an error" [ "${rc}" != 0 ]
settle

# ── a radio's module: use, release, backup, and its network in facts ──────────
ZBT_ID=usb-10c4_ea60-9e2adbd1
CH_ID=usb-1a86_55d4-1-1.3
mode() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }
# A listening socket where the module's would be, so `use` need not wait out
# its ten seconds; macOS's long temporary paths can be too long for one, and
# then it does wait.
sock() { python3 -c 'import os,socket,sys; os.makedirs(os.path.dirname(sys.argv[1]),exist_ok=True); socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "$1" 2>/dev/null || true; }
echo "${BOTH}" > "${FAKE_LIST}"; radios scan --quiet
fresh
chmod -x "${EDGE_BIN}/pulzr-edge-zigbee"
check "use without the Zigbee add-on's module is refused" not radios use "${ZBT_ID}" zigbee
chmod +x "${EDGE_BIN}/pulzr-edge-zigbee"
check "use of a radio not plugged in is refused" not radios use usb-10c4_ea60-gone zigbee
check "use takes zigbee or zwave only" not radios use "${ZBT_ID}" thread
echo '{"detected":[{"id":"usb-1a86_55d4-1-1.3","bus":"usb","state":"free","use":"modbus","since":2}]}' > "${PULZR_PROBE_RUN}/radios.json"
check "use of a Modbus adapter is refused" not radios use "${CH_ID}" zwave
echo "${BOTH}" > "${PULZR_PROBE_RUN}/radios.json"
check "nothing written for a refused use" [ ! -e "${PULZR_EDGE_RADIOS}/${ZBT_ID}.json" ]

sock "${PULZR_EDGE_RUN}/radio/${ZBT_ID}.sock"
echo '{"radio":"usb-10c4_ea60-9e2adbd1","protocol":"zigbee","state":"unformed"}' > "${SANDBOX}/status-${ZBT_ID}.json"
check "use starts the module and prints its status" [ "$(radios use "${ZBT_ID}" zigbee | jsonfilter -e @.state)" = unformed ]
check "its file names the protocol" [ "$(jsonfilter -i "${PULZR_EDGE_RADIOS}/${ZBT_ID}.json" -e @.protocol)" = zigbee ]
check "root's alone" [ "$(mode "${PULZR_EDGE_RADIOS}/${ZBT_ID}.json")" = 600 ]
check "and procd is told" [ "$(calls init reload)" = 1 ]
check "use again is the same" eval 'radios use "${ZBT_ID}" zigbee >/dev/null'
check "without telling procd again" [ "$(calls init reload)" = 1 ]
check "another protocol on it is refused" not radios use "${ZBT_ID}" zwave

check "facts carries the module's status" [ "$(radios facts | jsonfilter -e @.networks)" = '[{"radio": "usb-10c4_ea60-9e2adbd1", "protocol": "zigbee", "state": "unformed"}]' ]

echo '{"radio":"usb-10c4_ea60-9e2adbd1","protocol":"zigbee","state":"up"}' > "${SANDBOX}/status-${ZBT_ID}.json"
check "release with a network on it is refused" not radios release "${ZBT_ID}"
check "and the file stays" [ -e "${PULZR_EDGE_RADIOS}/${ZBT_ID}.json" ]
echo '{"radio":"usb-10c4_ea60-9e2adbd1","protocol":"zigbee","state":"unformed"}' > "${SANDBOX}/status-${ZBT_ID}.json"
check "release of an unformed radio" eval 'radios release "${ZBT_ID}" >/dev/null'
check "removes its file" [ ! -e "${PULZR_EDGE_RADIOS}/${ZBT_ID}.json" ]
check "and tells procd" [ "$(calls init reload)" = 2 ]

mkdir -p "${PULZR_EDGE_RUN}/backup"
echo '{"v":1,"protocol":"zigbee"}' > "${PULZR_EDGE_RUN}/backup/${ZBT_ID}.json"
check "backup hands the file to pulzr-claim" eval 'radios backup "${ZBT_ID}"'
check "as a radio backup" [ "$(calls claim "radio-backup ${ZBT_ID} ${PULZR_EDGE_RUN}/backup/${ZBT_ID}.json")" = 1 ]
check "and removes it once sent" [ ! -e "${PULZR_EDGE_RUN}/backup/${ZBT_ID}.json" ]
check "backup refuses a bad id" not radios backup '../x'

# ── Matter's controller: the radio `matter`, on no port of its own ──────────────
echo '{"radio":"matter","protocol":"matter","state":"unformed"}' > "${SANDBOX}/status-matter.json"
check "use matter needs no radio plugged in" eval 'radios use matter matter >/dev/null'
check "its file names Matter" [ "$(jsonfilter -i "${PULZR_EDGE_RADIOS}/matter.json" -e @.protocol)" = matter ]
check "matter is only Matter's" not radios use matter zigbee
check "and a radio is never Matter" not radios use "${ZBT_ID}" matter
check "release matter" eval 'radios release matter >/dev/null'

# ── a gateway locked off Modbus and Zigbee, with pulzr-zwave installed ───────
# Only pulzr-zwave is installed, so only its module's binary is on the
# gateway: its radio runs, Zigbee's does not, and nothing of Modbus is there.
rm -f "${EDGE_BIN}/pulzr-edge-zigbee" "${EDGE_BIN}/pulzr-edge-matter"
mkdir -p "${PULZR_EDGE_RADIOS}"
echo '{"radio":"usb-0658_0200-1-1.3","protocol":"zwave"}' > "${PULZR_EDGE_RADIOS}/usb-0658_0200-1-1.3.json"
echo '{"radio":"usb-10c4_ea60-9e2adbd1","protocol":"zigbee"}' > "${PULZR_EDGE_RADIOS}/usb-10c4_ea60-9e2adbd1.json"
check "the Z-Wave radio runs, with Z-Wave's binary" [ "$(radios runnable)" = "usb-0658_0200-1-1.3 ${EDGE_BIN}/pulzr-edge-zwave" ]
echo '{"radio":"usb-0658_0200-1-1.3","protocol":"zwave","state":"up"}' > "${SANDBOX}/status-usb-0658_0200-1-1.3.json"
check "call reaches it through that binary" [ "$(radios call usb-0658_0200-1-1.3 status < /dev/null | jsonfilter -e @.state)" = up ]
check "and a Zigbee radio's call finds no module" not radios call "${ZBT_ID}" status
check "a Zigbee radio is never started without pulzr-zigbee" not eval '[ -n "$(radios runnable | grep 10c4)" ]'
check "and Zigbee cannot be set up" not radios use usb-10c4_ea60-1 zigbee
check "Modbus's binary and service are pulzr-modbus's alone" eval \
    '[ -e "${ROOT_DIR}/feed/pulzr-modbus/files/etc/init.d/pulzr-edge" ] && grep -q "usr/sbin/pulzr-edge\"" "${ROOT_DIR}/feed/pulzr-modbus/fetch"'
check "each radio add-on ships its own binary" eval \
    '( for m in zigbee zwave matter; do grep -q "usr/sbin/pulzr-edge-${m}" "${ROOT_DIR}/feed/pulzr-${m}/fetch" || exit 1; done )'
check "pulzr-edge-radios starts each radio with the binary runnable names" \
    grep -q 'procd_set_param command "${bin}" radio serve' "${ROOT_DIR}/feed/pulzr-probe/files/etc/init.d/pulzr-edge-radios"

echo "${pass} passed"
exit "${fail}"
