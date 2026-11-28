#!/usr/bin/env bash
#
# Drive pulzr-apply against a scratch /etc/config and stubbed ubus, sleep,
# start-stop-daemon and logger.
#
#   scripts/test-apply.sh
#
# The rollback window is the one thing that has to work when everything else
# has just stopped working: a change that cut the gateway off must come back
# on its own, and a reboot in the middle must not boot into it. None of that
# shows on a bench until it fails. Each case arms, changes a config the way a
# console setter would, and checks what is on "flash" afterwards.

set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APPLY="${ROOT_DIR}/feed/pulzr-base/files/usr/sbin/pulzr-apply"

SANDBOX="$(mktemp -d)"
trap 'rm -rf "${SANDBOX}"' EXIT
BIN="${SANDBOX}/bin"
mkdir -p "${BIN}" "${SANDBOX}/config"
export PULZR_APPLY_STATE="${SANDBOX}/state"
export PULZR_APPLY_CONFIG="${SANDBOX}/config"
export PATH="${BIN}:${PATH}"
CALLS="${SANDBOX}/calls"

pass=0; fail=0
check() {
    if [ "$2" = "$3" ]; then pass=$((pass + 1)); else
        fail=$((fail + 1)); echo "FAIL: $1"; echo "  want: $2"; echo "  got:  $3"
    fi
}

stub() { printf '#!/bin/sh\n%s\n' "$2" > "${BIN}/$1"; chmod +x "${BIN}/$1"; }
# Every one records that it ran; the timer is not started, the test calls
# `expire` itself, and nothing sleeps.
stub ubus 'echo "ubus $*" >> '"${CALLS}"
stub sleep 'exit 0'
stub start-stop-daemon 'echo "timer $*" >> '"${CALLS}"
stub logger 'exit 0'
stub sync 'exit 0'

apply() { sh "${APPLY}" "$@"; }
field() { python3 -c 'import json,sys; v=json.load(sys.stdin)
for k in sys.argv[1].split("."): v = v[k] if v is not None else None
print("null" if v is None else str(v).lower() if isinstance(v, bool) else v)' "$1"; }
age() { sed -i.bak "s/^$1=.*/$1=$2/" "${PULZR_APPLY_STATE}/pending"; rm -f "${PULZR_APPLY_STATE}/pending.bak"; }
reset() {
    rm -rf "${PULZR_APPLY_STATE}" "${SANDBOX}/config" "${CALLS}"
    mkdir -p "${SANDBOX}/config"
    for c in network wireless firewall dhcp pulzr; do echo "${c} before" > "${SANDBOX}/config/${c}"; done
    : > "${CALLS}"
}
cfg() { cat "${SANDBOX}/config/$1"; }

# The clock moves between the call and the check: a figure that counts down is
# within a second of what it started at.
near() { [ "$2" -le "$1" ] && [ "$2" -ge "$(($1 - 1))" ] && echo "$1" || echo "$2"; }

# ── arm ─────────────────────────────────────────────────────────────────────

reset
out="$(apply arm 'tech@example.com')"
check "arm: a change is pending" "tech@example.com" "$(echo "${out}" | field pending.by)"
check "arm: the default window is 90 s" "90" "$(echo "${out}" | field pending.window)"
check "arm: it counts down from the window" "90" "$(near 90 "$(echo "${out}" | field pending.in)")"
check "arm: the first confirm waits out the settle time" "15" "$(near 15 "$(echo "${out}" | field pending.confirmableIn)")"
check "arm: the timer is started" "1" "$(grep -c 'timer .* expire$' "${CALLS}")"
for c in network wireless firewall dhcp pulzr; do
    check "arm: ${c} is kept on flash" "${c} before" "$(cat "${PULZR_APPLY_STATE}/rollback/${c}")"
done
apply arm -w 240 >/dev/null 2>&1
check "a second arm while armed is refused" "4" "$?"
out="$(apply arm -w 240 2>&1)"
check "the refusal says why" "a change is waiting to be confirmed" "${out}"
check "the refusal leaves the window alone" "90" "$(apply status | field pending.window)"

reset
check "a cellular change gets 240 s" "240" "$(apply arm -w 240 | field pending.window)"
apply arm -w 5 >/dev/null 2>&1; check "a window shorter than the settle time is refused" "2" "$?"
apply arm -w 9999 >/dev/null 2>&1; check "a window past ten minutes is refused" "2" "$?"
apply arm -w abc >/dev/null 2>&1; check "a window that is not seconds is refused" "2" "$?"

# ── confirm ─────────────────────────────────────────────────────────────────

reset
apply arm >/dev/null
echo "network after" > "${SANDBOX}/config/network"
apply confirm >/dev/null 2>&1; check "confirm: refused while the change settles" "3" "$?"
check "confirm: the window is still open after a refusal" "true" "$([ -f "${PULZR_APPLY_STATE}/pending" ] && echo true)"
age applied 1
check "confirm: kept once it has settled" "true" "$(apply confirm | field confirmed)"
check "confirm: the new configuration stays" "network after" "$(cfg network)"
check "confirm: nothing is left to restore" "" "$(ls "${PULZR_APPLY_STATE}")"
check "confirm: with nothing pending it says so" "false" "$(apply confirm | field confirmed)"
check "after a confirm the next change can arm" "90" "$(apply arm | field pending.window)"

# ── settle ──────────────────────────────────────────────────────────────────

reset
apply arm >/dev/null
age applied 1; age until 100
out="$(apply settle)"
check "settle: the window counts from now" "90" "$(near 90 "$(echo "${out}" | field pending.in)")"
check "settle: and so does the settle time" "15" "$(near 15 "$(echo "${out}" | field pending.confirmableIn)")"

# ── an extended change keeps the first snapshot ─────────────────────────────

reset
apply arm >/dev/null
echo "network first" > "${SANDBOX}/config/network"
apply arm -e >/dev/null
echo "network second" > "${SANDBOX}/config/network"
age until 1
apply expire 1
check "arm -e: the snapshot is from before the first change" "network before" "$(cfg network)"

# ── expire and restore ──────────────────────────────────────────────────────

reset
apply arm >/dev/null
for c in network wireless firewall dhcp pulzr; do echo "${c} after" > "${SANDBOX}/config/${c}"; done
: > "${CALLS}"
age until 1
apply expire 1
for c in network wireless firewall dhcp pulzr; do
    check "expire: ${c} comes back" "${c} before" "$(cfg "${c}")"
done
check "expire: the network is told to reload" "1" "$(grep -c '^ubus call network reload' "${CALLS}")"
check "expire: nothing is left pending" "" "$(ls "${PULZR_APPLY_STATE}")"

reset
apply arm >/dev/null
echo "network after" > "${SANDBOX}/config/network"
age applied 1
apply confirm >/dev/null
apply expire 1
check "expire: a confirmed change is left alone" "network after" "$(cfg network)"

# ── what it is, and a WiFi uplink that proves itself ───────────────────────

reset
apply arm -d 'Wi-Fi uplink: Silence of the Lan-5G' 'tech@example.com' >/dev/null
check "what: named in the answer" "Wi-Fi uplink: Silence of the Lan-5G" "$(apply status | field pending.what)"
apply arm -e >/dev/null
check "what: kept by a second step of the same change" "Wi-Fi uplink: Silence of the Lan-5G" "$(apply status | field pending.what)"
reset
apply arm -d "Wi-Fi uplink: \"Joe's\"\\" >/dev/null
check "what: nothing JSON would need escaped" "Wi-Fi uplink: Joe's" "$(apply status | field pending.what)"
reset
check "what: none is null" "null" "$(apply arm | field pending.what)"

# pulzr-wifi-uplink's answer, as the stub gives it.
answer() { stub pulzr-wifi-uplink "echo '{ \"state\": \"$1\", \"checkedAt\": $2 }'"; }
proving() {
    reset
    apply arm -d 'Wi-Fi uplink: Silence of the Lan-5G' >/dev/null
    echo "wireless after" > "${SANDBOX}/config/wireless"
    apply settle -p wwifi2 >/dev/null
    age applied "$(( $(date +%s) - 20 ))"
}

proving
answer open "$(date +%s)"
age until "$(( $(date +%s) + 3 ))"
apply expire
check "prove: an uplink that reaches the internet keeps the change" "wireless after" "$(cfg wireless)"
check "prove: nothing is left pending" "" "$(ls "${PULZR_APPLY_STATE}")"

proving
answer portal "$(date +%s)"
age until 1
apply expire
check "prove: one behind a sign-in page is undone at the deadline" "wireless before" "$(cfg wireless)"

proving
answer open "$(( $(date +%s) - 60 ))"
age until 1
apply expire
check "prove: an answer from before the change proves nothing" "wireless before" "$(cfg wireless)"

proving
answer open "$(date +%s)"
age applied "$(date +%s)"
age until 1
apply expire
check "prove: not inside the settle time" "wireless before" "$(cfg wireless)"
rm -f "${BIN}/pulzr-wifi-uplink"

reset
apply arm >/dev/null
age until 1
apply expire
check "prove: a change naming no uplink is undone as before" "network before" "$(cfg network)"

# ── revert ──────────────────────────────────────────────────────────────────

reset
apply revert >/dev/null 2>&1; check "revert: with nothing pending is refused" "2" "$?"
apply arm >/dev/null
echo "dhcp after" > "${SANDBOX}/config/dhcp"
check "revert: answers reverted" "true" "$(apply revert | field reverted)"
check "revert: the configuration is back" "dhcp before" "$(cfg dhcp)"
check "revert: nothing is left pending" "" "$(ls "${PULZR_APPLY_STATE}")"

# ── boot ────────────────────────────────────────────────────────────────────

reset
apply arm >/dev/null
echo "network after" > "${SANDBOX}/config/network"
echo "pulzr after" > "${SANDBOX}/config/pulzr"
: > "${CALLS}"
apply boot
check "boot: a window a reboot interrupted is undone (network)" "network before" "$(cfg network)"
check "boot: (pulzr)" "pulzr before" "$(cfg pulzr)"
check "boot: nothing is left pending" "" "$(ls "${PULZR_APPLY_STATE}")"
check "boot: no reload, nothing is running yet" "0" "$(grep -c ubus "${CALLS}")"
apply boot
check "boot: with nothing pending it changes nothing" "network before" "$(cfg network)"

# ── status ──────────────────────────────────────────────────────────────────

reset
check "status: nothing pending" "null" "$(apply status | field pending)"
apply arm >/dev/null
age until 1
check "status: a window that ran out is no longer pending" "null" "$(apply status | field pending)"

echo "${pass} passed, ${fail} failed"
[ "${fail}" = 0 ]
