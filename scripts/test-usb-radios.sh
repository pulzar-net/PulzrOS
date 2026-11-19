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
EOF
if ! command -v md5sum >/dev/null 2>&1; then
    printf '#!/bin/sh\n[ -f "$1" ] || exit 1\nmd5 -q "$1"\n' > "${STUBS}/md5sum"
fi
chmod +x "${STUBS}"/*

export PATH="${STUBS}:${PATH}" SANDBOX
export PULZR_PROBE_RUN="${SANDBOX}/run" PULZR_PROBE_SETTLE=1 FAKE_LIST="${SANDBOX}/list.json"

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
# What `tell` starts runs in the background.
settle() { sleep 0.5; }

ZBT='{"detected":[{"id":"usb-10c4_ea60-9e2adbd1","bus":"usb","label":"Home Assistant Connect ZBT-1","state":"free","since":1}]}'
BOTH='{"detected":[{"id":"usb-10c4_ea60-9e2adbd1","bus":"usb","label":"Home Assistant Connect ZBT-1","state":"free","since":1},{"id":"usb-1a86_55d4-1-1.3","bus":"usb","label":"USB serial adapter (CH9102)","state":"unidentified","since":2}]}'

# ── not adopted: scans, tells nobody ────────────────────────────────────────
echo "${ZBT}" > "${FAKE_LIST}"
radios scan; settle
check "a scan writes the report" grep -q ZBT-1 "${PULZR_PROBE_RUN}/radios.json"
check "the LAN list falls back to {} without umdns" [ "$(cat "${PULZR_PROBE_RUN}/mdns.json")" = '{}' ]
check "not adopted: no report sent" [ "$(calls claim report)" = 0 ]

# ── adopted: told on a change only ──────────────────────────────────────────
echo adopted > "${SANDBOX}/adoption"
fresh
radios scan; settle
check "the same list says nothing" [ "$(calls claim report)" = 0 ]
echo "${BOTH}" > "${FAKE_LIST}"
radios scan; settle
check "a new radio sends the report" [ "$(calls claim report)" = 1 ]
check "and publishes the MQTT state again" [ "$(calls agent --publish-state)" = 1 ]
echo "${ZBT}" > "${FAKE_LIST}"
fresh
radios scan --quiet; settle
check "--quiet never tells" [ "$(calls claim report)" = 0 ]

# ── a burst of hotplug events is one scan ───────────────────────────────────
echo "${BOTH}" > "${FAKE_LIST}"
fresh
for _ in 1 2 3 4 5 6; do radios hotplug; done
sleep 2.5
check "six events, one scan" [ "$(calls probe --report)" = 1 ]
check "and one report" [ "$(calls claim report)" = 1 ]

# ── facts, for the claim report ─────────────────────────────────────────────
check "facts prints the list" [ "$(radios facts)" = "${BOTH}" ]
echo '{"detected":[]}' > "${FAKE_LIST}"
check "an empty list is still a list" [ "$(radios facts)" = '{"detected":[]}' ]
echo '{"detected":[{' > "${FAKE_LIST}"
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

echo "${pass} passed"
exit "${fail}"
