#!/usr/bin/env bash
#
# Drive pulzr-claim through a revoked claim and back, against a sandbox.
#
#   scripts/test-claim.sh
#
# The part of the claim that decides things — when an answer counts as a
# revocation, when a second claim is minted, which claim is shown, polled and
# promoted — is shell that otherwise only runs on a gateway, against
# Pulzar Cloud. Getting it wrong costs either a gateway nobody can adopt again
# or one that shows a claim code to whoever reports during a bad deploy, and
# neither is found on a bench. So it runs here, with curl, uci, jsonfilter and
# the scripts it calls replaced by stubs that answer what each case needs.
#
# Run under bash, standing in for busybox ash: the script uses the substring
# expansion ash has and dash does not.

set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLAIM="${ROOT_DIR}/feed/pulzr-adopt/files/usr/sbin/pulzr-claim"

command -v python3 >/dev/null 2>&1 || { echo "python3 is required (for the jsonfilter stub)" >&2; exit 2; }

SANDBOX="$(mktemp -d)"
trap 'rm -rf "${SANDBOX}"' EXIT
STUBS="${SANDBOX}/bin"
STATE="${SANDBOX}/claim"
mkdir -p "${STUBS}" "${SANDBOX}/curl"

# ── stubs ───────────────────────────────────────────────────────────────────

cat > "${STUBS}/uci" <<'EOF'
#!/bin/sh
# uci -q get <key>, from a key=value file.
[ "$1" = "-q" ] && shift
[ "$1" = "get" ] || exit 1
grep -m1 "^$2=" "${UCI_DB}" 2>/dev/null | cut -d= -f2- | grep . || exit 1
EOF

cat > "${STUBS}/jsonfilter" <<'EOF'
#!/usr/bin/env python3
import json, sys
args = sys.argv[1:]
expr = args[args.index('-e') + 1]
src = open(args[args.index('-i') + 1]) if '-i' in args else sys.stdin
try:
    value = json.load(src)
    for part in filter(None, expr[2:].split('.')):
        value = value[part]
except Exception:
    sys.exit(1)
if isinstance(value, bool):
    print('true' if value else 'false')
elif isinstance(value, (dict, list)):
    print(json.dumps(value))
else:
    print(value)
EOF

# Answers from ${CURL_DIR}/<last path segment>: the status on the first line,
# the body after it. No file is no answer. Every request is logged.
cat > "${STUBS}/curl" <<'EOF'
#!/bin/sh
url="" body="" write="" fail=""
while [ $# -gt 0 ]; do
    case "$1" in
        -d) body="$2"; shift ;;
        -w) write="$2"; shift ;;
        -X|-H|--max-time) shift ;;
        -f*) fail=1 ;;
        http*) url="$1" ;;
    esac
    shift
done
endpoint="${url##*/}"
printf '%s %s\n' "${endpoint}" "${body}" >> "${CURL_LOG}"
answer="${CURL_DIR}/${endpoint}"
[ -f "${answer}" ] || { echo "curl: (7) Failed to connect" >&2; exit 7; }
status="$(head -n1 "${answer}")"
[ -n "${fail}" ] && [ "${status}" -ge 400 ] && exit 22
tail -n +2 "${answer}"
[ -n "${write}" ] && printf '\n%s' "${status}"
exit 0
EOF

cat > "${STUBS}/logger" <<'EOF'
#!/bin/sh
echo "$*" >> "${SANDBOX}/log"
EOF

cat > "${STUBS}/pulzr-adopt" <<'EOF'
#!/bin/sh
echo "$*" >> "${SANDBOX}/adopt.log"
[ "$1" = "--from-bundle" ] && cp "$2" "${SANDBOX}/installed-bundle.json"
exit 0
EOF

cat > "${STUBS}/pulzr-wireguard-enroll" <<'EOF'
#!/bin/sh
echo "$*" >> "${SANDBOX}/enroll.log"
EOF

printf '#!/bin/sh\necho "{\\"present\\":false}"\n' > "${STUBS}/pulzr-modem-detect"
printf '#!/bin/sh\necho "{\\"wiredUsable\\":true,\\"via\\":\\"wired\\"}"\n' > "${STUBS}/pulzr-wireguard-route"
printf '#!/bin/sh\necho up\n' > "${STUBS}/pulzr-backhaul-check"
cat > "${STUBS}/pulzr-ssh-setup" <<'EOF'
#!/bin/sh
case "$1" in
    --host-key)  echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITEST" ;;
    --trusts-ca) exit 0 ;;
esac
EOF

# A Mac has hexdump and sha256sum; a minimal Linux may lack hexdump.
if ! command -v hexdump >/dev/null 2>&1; then
    cat > "${STUBS}/hexdump" <<'EOF'
#!/bin/sh
od -An -v -tx1 | tr -d ' \n'
EOF
fi

chmod +x "${STUBS}"/*

cat > "${SANDBOX}/board.conf" <<'EOF'
BOARD_ID='rak7289cv2'
PULZR_VERSION='0.4.0'
EOF

export PATH="${STUBS}:${PATH}"
export SANDBOX UCI_DB="${SANDBOX}/uci" CURL_DIR="${SANDBOX}/curl" CURL_LOG="${SANDBOX}/curl.log"
export PULZR_CLAIM_DIR="${STATE}" PULZR_BOARD_CONF="${SANDBOX}/board.conf"
export PULZR_NET_URL="https://net.test"

# ── helpers ─────────────────────────────────────────────────────────────────

fail=0
pass=0
check() {
    local what="$1"; shift
    if "$@"; then pass=$((pass + 1)); else echo "FAIL: ${what}"; fail=1; fi
}

claim() { bash "${CLAIM}" "$@" 2>/dev/null; }
not() { ! "$@"; }
answer() { printf '%s\n%s' "$2" "$3" > "${CURL_DIR}/$1"; }
silent() { rm -f "${CURL_DIR}/$1"; }
requests() { grep -c "^$1 " "${CURL_LOG}" 2>/dev/null || true; }
last_body() { grep "^$1 " "${CURL_LOG}" | tail -n1 | cut -d' ' -f2-; }
field() { printf '%s' "$1" | jsonfilter -e "@.$2"; }

adopted_gateway() {
    rm -rf "${STATE}" "${SANDBOX}"/*.log "${SANDBOX}/installed-bundle.json" "${CURL_DIR}"/*
    : > "${CURL_LOG}"
    cat > "${UCI_DB}" <<'EOF'
pulzr.adoption.state=adopted
pulzr.identity.gateway_eui=ac1f09fffe0a1b2c
pulzr.identity.serial=1234abcd
EOF
    mkdir -p "${STATE}"
    echo "OLD0-CLAI-M000" > "${STATE}/id"
    printf 'oldsecret' > "${STATE}/secret"
    touch "${STATE}/registered"
}

aged_marker() { echo $(( $(date +%s) - 120 )) > "${STATE}/revoked"; }

REVOKED_REPORT='{"error":"No such gateway."}'
CLAIM_ID_FORMAT='^[0-9A-HJKMNP-TV-Z]{4}-[0-9A-HJKMNP-TV-Z]{4}-[0-9A-HJKMNP-TV-Z]{4}$'

# ── an adopted gateway whose reports are accepted ───────────────────────────

adopted_gateway
answer report 200 '{"state":"adopted","backhaul":"ethernet"}'
claim report; rc=$?
check "accepted report exits 0" [ "${rc}" = 0 ]
check "accepted report leaves no revoked marker" [ ! -e "${STATE}/revoked" ]
check "the report is valid JSON" python3 -c 'import json,sys; json.loads(sys.argv[1])' "$(last_body report)"
check "report carries sshCa" [ "$(field "$(last_body report)" facts.sshCa)" = true ]
check "report carries the host key" \
    [ "$(field "$(last_body report)" facts.sshHostKey)" = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITEST" ]
check "a board without a RAK power board reports it as null" \
    python3 -c 'import json,sys; assert json.loads(sys.argv[1])["facts"]["rakPower"] is None' "$(last_body report)"

# The management ports listening beyond loopback, from the socket table: SSH
# and the tunnel console on any address, never telnet on 127.0.0.1, nor a
# connection that is not listening, nor the IPv6 loopback.
mkdir -p "${SANDBOX}/proc"
printf '  sl  local_address rem_address   st\n   0: 00000000:0016 00000000:0000 0A\n   1: 0100007F:0017 00000000:0000 0A\n   2: 00000000:1F90 00000000:0000 0A\n   3: 0A00007A:01BB 0A000001:C000 01\n   4: 00000000:0BB8 00000000:0000 0A\n' > "${SANDBOX}/proc/tcp"
printf '  sl  local_address rem_address   st\n   0: 00000000000000000000000000000000:0016 00000000000000000000000000000000:0000 0A\n   1: 00000000000000000000000001000000:01BB 00000000000000000000000000000000:0000 0A\n' > "${SANDBOX}/proc/tcp6"
PULZR_PROC_NET="${SANDBOX}/proc" claim report
check "the report lists what listens: SSH and 8080, not loopback, not 3000" \
    python3 -c 'import json,sys; assert json.loads(sys.argv[1])["facts"]["listening"] == [22, 8080]' "$(last_body report)"

printf '#!/bin/sh\necho "{\\"running\\":true,\\"watchdog\\":{\\"state\\":\\"failing\\"}}"\n' > "${STUBS}/pulzr-rak-power"
chmod +x "${STUBS}/pulzr-rak-power"
claim report
check "the power board record rides the report" \
    [ "$(field "$(last_body report)" facts.rakPower.watchdog.state)" = failing ]

printf '#!/bin/sh\necho "{\\"running\\":tr"\n' > "${STUBS}/pulzr-rak-power"
claim report
check "an unreadable power board record is null, and the report still parses" \
    python3 -c 'import json,sys; assert json.loads(sys.argv[1])["facts"]["rakPower"] is None' "$(last_body report)"
rm -f "${STUBS}/pulzr-rak-power"

# Radios plugged in (pulzr-radios): the list as it says it, null when it is
# absent or unreadable, and an empty list kept as one, since that is the
# report that says the last radio was pulled out.
check "a gateway without pulzr-radios reports radios as null" \
    python3 -c 'import json,sys; assert json.loads(sys.argv[1])["facts"]["radios"] is None' "$(last_body report)"
printf '#!/bin/sh\nshift; exec "$@"\n' > "${STUBS}/pulzr-timeout"
printf '#!/bin/sh\necho "{\\"detected\\":[{\\"id\\":\\"usb-10c4_ea60-1\\",\\"bus\\":\\"usb\\",\\"state\\":\\"free\\"}]}"\n' > "${STUBS}/pulzr-radios"
chmod +x "${STUBS}/pulzr-timeout" "${STUBS}/pulzr-radios"
claim report
check "the detected radios ride the report" \
    python3 -c 'import json,sys; assert json.loads(sys.argv[1])["facts"]["radios"]["detected"][0]["id"] == "usb-10c4_ea60-1"' "$(last_body report)"
printf '#!/bin/sh\necho "{\\"detected\\":[]}"\n' > "${STUBS}/pulzr-radios"
claim report
check "no radios is an empty list, not null" \
    python3 -c 'import json,sys; assert json.loads(sys.argv[1])["facts"]["radios"] == {"detected": []}' "$(last_body report)"
printf '#!/bin/sh\necho "{\\"detected\\":[{"\n' > "${STUBS}/pulzr-radios"
claim report
check "an unreadable radio list is null, and the report still parses" \
    python3 -c 'import json,sys; assert json.loads(sys.argv[1])["facts"]["radios"] is None' "$(last_body report)"

# The Thread border router (pulzr-thread): its brief status, null without it.
check "a gateway without pulzr-thread reports thread as null" \
    python3 -c 'import json,sys; assert json.loads(sys.argv[1])["facts"]["thread"] is None' "$(last_body report)"
printf '#!/bin/sh\necho "{\\"enabled\\":true,\\"agent\\":\\"running\\",\\"role\\":\\"leader\\"}"\n' > "${STUBS}/pulzr-thread"
chmod +x "${STUBS}/pulzr-thread"
claim report
check "the border router's status rides the report" \
    python3 -c 'import json,sys; assert json.loads(sys.argv[1])["facts"]["thread"]["role"] == "leader"' "$(last_body report)"
rm -f "${STUBS}/pulzr-thread"
rm -f "${STUBS}/pulzr-radios" "${STUBS}/pulzr-timeout"

# The list alone, from hotplug: what pulzr-radios lists (pulzr-probe's radios
# and the modems), under the claim's proof. Its stand-in prints the file.
export PULZR_PROBE_RUN="${SANDBOX}/probe"
mkdir -p "${PULZR_PROBE_RUN}"
printf '#!/bin/sh\n[ "$1" = list ] && cat "%s/radios.json"\n' "${PULZR_PROBE_RUN}" > "${STUBS}/pulzr-radios"
chmod +x "${STUBS}/pulzr-radios"
echo '{"detected":[{"id":"usb-10c4_ea60-1","bus":"usb","state":"free"}]}' > "${PULZR_PROBE_RUN}/radios.json"
answer radios 200 '{"changes":[]}'
claim radios; rc=$?
check "radios alone is accepted" [ "${rc}" = 0 ]
check "and carries the claim's proof and the list" python3 -c '
import json, sys
b = json.loads(sys.argv[1])
assert b["claimId"] == "OLD0-CLAI-M000" and b["secret"] == "oldsecret"
assert b["radios"]["detected"][0]["id"] == "usb-10c4_ea60-1"' "$(last_body radios)"
echo '{"detected":[{' > "${PULZR_PROBE_RUN}/radios.json"
before="$(requests radios)"
claim radios; rc=$?
check "an unreadable list is an error" [ "${rc}" != 0 ]
check "and is not sent" [ "$(requests radios)" = "${before}" ]

check "a gateway without pulzr-apply reports apply as 0" [ "$(field "$(last_body report)" facts.apply)" = 0 ]
printf '#!/bin/sh\nexit 0\n' > "${STUBS}/pulzr-apply"; chmod +x "${STUBS}/pulzr-apply"
claim report
check "a gateway with pulzr-apply reports apply as 1" [ "$(field "$(last_body report)" facts.apply)" = 1 ]
rm -f "${STUBS}/pulzr-apply"

# ── a 404 that is not the revoked answer ────────────────────────────────────

answer report 404 '{"error":"Not found"}'
claim report; rc=$?
check "a generic 404 is not a revocation" [ "${rc}" = 1 ]
check "a generic 404 leaves no marker" [ ! -e "${STATE}/revoked" ]

silent report
claim report; rc=$?
check "no answer is not a revocation" [ "${rc}" = 1 ]
check "no answer leaves no marker" [ ! -e "${STATE}/revoked" ]

# ── the revoked answer, once, then again too soon ───────────────────────────

answer report 404 "${REVOKED_REPORT}"
claim report; rc=$?
check "the revoked answer exits 3" [ "${rc}" = 3 ]
check "the first revoked answer is remembered" [ -s "${STATE}/revoked" ]
check "the first revoked answer mints nothing" [ ! -e "${STATE}/next" ]

claim report
check "a second answer inside a minute mints nothing" [ ! -e "${STATE}/next" ]

# ── confirmed: a second claim beside the first ──────────────────────────────

answer register 200 '{"state":"pending"}'
aged_marker
claim report; rc=$?
next_id="$(cat "${STATE}/next/id" 2>/dev/null)"
check "the confirmed answer still exits 3" [ "${rc}" = 3 ]
check "a new claim is minted" [ -s "${STATE}/next/secret" ]
check "the new claim id is a claim id" grep -qE "${CLAIM_ID_FORMAT}" <<< "${next_id}"
check "the old claim is kept" [ "$(cat "${STATE}/id")" = "OLD0-CLAI-M000" ]
check "the old secret is kept" [ "$(cat "${STATE}/secret")" = "oldsecret" ]
check "the marker is cleared" [ ! -e "${STATE}/revoked" ]
check "the new claim is registered" [ -e "${STATE}/next/registered" ]
check "registration names the new claim" [ "$(field "$(last_body register)" claimId)" = "${next_id}" ]
check "registration commits to the new secret" \
    [ "$(field "$(last_body register)" commitment)" = "$(sha256sum "${STATE}/next/secret" | cut -d' ' -f1)" ]
check "registration names this gateway" [ "$(field "$(last_body register)" eui)" = "ac1f09fffe0a1b2c" ]
check "pulzr-claim reclaiming says so" claim reclaiming

registered_once="$(requests register)"
claim report
check "one waiting claim at a time" [ "$(cat "${STATE}/next/id")" = "${next_id}" ]
check "it is not registered again" [ "$(requests register)" = "${registered_once}" ]
check "no marker while one waits" [ ! -e "${STATE}/revoked" ]

# ── shown where the first claim was ─────────────────────────────────────────

status="$(claim status)"
check "status says reclaiming" [ "$(field "${status}" state)" = reclaiming ]
check "status shows the new claim" [ "$(field "${status}" claimId)" = "${next_id}" ]
check "status says it is registered" [ "$(field "${status}" registered)" = true ]
check "the QR is the new claim's" [ "$(claim qr)" = "https://net.test/adopt#${next_id}" ]

# ── polled while it waits ───────────────────────────────────────────────────

answer poll 200 '{"state":"pending"}'
claim poll; rc=$?
check "a pending poll exits 0" [ "${rc}" = 0 ]
check "the poll asks with the new claim" [ "$(field "$(last_body poll)" claimId)" = "${next_id}" ]
check "the poll proves the new secret" [ "$(field "$(last_body poll)" secret)" = "$(cat "${STATE}/next/secret")" ]

answer poll 404 '{"error":"No such claim."}'
claim poll
check "a forgotten claim is registered again" [ ! -e "${STATE}/next/registered" ]
check "under the same code" [ "$(cat "${STATE}/next/id")" = "${next_id}" ]

answer register 409 '{"error":"That claim was revoked when this gateway changed hands. Generate a new claim on the gateway."}'
claim poll
check "a refused claim is replaced" [ "$(cat "${STATE}/next/id")" != "${next_id}" ]
check "the replacement is not yet registered" [ ! -e "${STATE}/next/registered" ]
check "the old claim is still kept" [ "$(cat "${STATE}/id")" = "OLD0-CLAI-M000" ]

backoff="$(claim backoff)"
check "polled every 30s at first" [ "${backoff}" = 30 ]
echo $(( $(date +%s) - 1000 )) > "${STATE}/next/since"
check "every 5 minutes after fifteen" [ "$(claim backoff)" = 300 ]
echo $(( $(date +%s) - 4000 )) > "${STATE}/next/since"
check "hourly after an hour" [ "$(claim backoff)" = 3600 ]

# ── the old claim accepted again ────────────────────────────────────────────

answer report 200 '{"state":"adopted","backhaul":"ethernet"}'
claim report
check "an accepted report drops the waiting claim" [ ! -e "${STATE}/next" ]
check "and the gateway is not reclaiming" not claim reclaiming

# ── adopted by the new owner ────────────────────────────────────────────────

adopted_gateway
answer report 404 "${REVOKED_REPORT}"
answer register 200 '{"state":"pending"}'
aged_marker
claim report
next_id="$(cat "${STATE}/next/id")"
next_secret="$(cat "${STATE}/next/secret")"
answer poll 200 '{"state":"adopted","eui":"ac1f09fffe0a1b2c","org":"new-owner","recoveryPublicKey":"x","mqtt":{"username":"u","password":"p"}}'
claim poll; rc=$?
check "adoption exits 0" [ "${rc}" = 0 ]
check "the new claim replaces the old" [ "$(cat "${STATE}/id")" = "${next_id}" ]
check "with its secret" [ "$(cat "${STATE}/secret")" = "${next_secret}" ]
check "nothing waits any more" [ ! -e "${STATE}/next" ]
check "the bundle is installed" grep -q -- "--from-bundle" "${SANDBOX}/adopt.log"
check "it is the new owner's" [ "$(jsonfilter -i "${SANDBOX}/installed-bundle.json" -e '@.org')" = "new-owner" ]
check "the bundle is not left on disk" [ ! -e "${STATE}/bundle.json" ]
check "the tunnel enrols again" grep -q -- "--background" "${SANDBOX}/enroll.log"
answer report 200 '{"state":"adopted","backhaul":"ethernet"}'
claim report
check "reports use the new claim" [ "$(field "$(last_body report)" claimId)" = "${next_id}" ]

# Collected by a poll whose answer was lost: still the live claim.
adopted_gateway
answer report 404 "${REVOKED_REPORT}"
answer register 200 '{"state":"pending"}'
aged_marker
claim report
next_id="$(cat "${STATE}/next/id")"
answer poll 409 '{"error":"This gateway collected its bundle already.","state":"collected"}'
claim poll
check "a collected claim still replaces the revoked one" [ "$(cat "${STATE}/id")" = "${next_id}" ]
check "and nothing waits" [ ! -e "${STATE}/next" ]

# ── the tunnel enrolment's revoked answer counts too ────────────────────────

adopted_gateway
claim note-revoked
check "note-revoked remembers the first answer" [ -s "${STATE}/revoked" ]
answer register 200 '{"state":"pending"}'
aged_marker
claim note-revoked
check "note-revoked confirms the second" claim reclaiming

# ── an unadopted gateway with a revoked claim ───────────────────────────────

adopted_gateway
sed -i.bak 's/^pulzr.adoption.state=.*/pulzr.adoption.state=unadopted/' "${UCI_DB}"
answer report 404 "${REVOKED_REPORT}"
aged_marker
claim note-revoked
check "an unadopted gateway mints no second claim" [ ! -e "${STATE}/next" ]

answer poll 404 '{"error":"No such claim."}'
claim poll
check "an unknown claim is registered again" [ ! -e "${STATE}/registered" ]
answer register 409 '{"error":"That claim was revoked when this gateway changed hands. Generate a new claim on the gateway."}'
claim poll
check "a revoked claim is replaced on an unadopted gateway" [ "$(cat "${STATE}/id")" != "OLD0-CLAI-M000" ]
check "with a new secret" [ "$(cat "${STATE}/secret")" != "oldsecret" ]
answer register 200 '{"state":"pending"}'
answer poll 200 '{"state":"pending"}'
claim poll
check "which then registers" [ -e "${STATE}/registered" ]
check "status is still unadopted" [ "$(field "$(claim status)" state)" = unadopted ]

echo "${pass} passed"
exit "${fail}"
