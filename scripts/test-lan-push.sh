#!/usr/bin/env bash
#
# pulzr-lan's DHCP hook (hotplug.d/dhcp/60-pulzr-lan-push), against stubs.
#
#   scripts/test-lan-push.sh
#
# What it must do: a burst of lease events is one push; a renewal that changes
# no lease (MAC, address, name) is none; a new, changed or expired lease is
# one; nothing before adoption.
set -uo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="${ROOT_DIR}/feed/pulzr-lan/files/etc/hotplug.d/dhcp/60-pulzr-lan-push"
SANDBOX="$(mktemp -d)"
trap 'rm -rf "${SANDBOX}"' EXIT
STUBS="${SANDBOX}/bin"
mkdir -p "${STUBS}"
export SANDBOX

cat > "${STUBS}/uci" <<'STUB'
#!/bin/sh
[ "$*" = "-q get pulzr.adoption.state" ] && cat "${SANDBOX}/adopted" 2>/dev/null
STUB
cat > "${STUBS}/agent" <<'STUB'
#!/bin/sh
echo "$*" >> "${SANDBOX}/pushes"
STUB
command -v md5sum >/dev/null 2>&1 || printf '#!/bin/sh\nmd5 -q | sed "s/$/  -/"\n' > "${STUBS}/md5sum"
chmod +x "${STUBS}"/*

export PATH="${STUBS}:${PATH}" PULZR_LAN_PUSH_DIR="${SANDBOX}/run" PULZR_LEASES="${SANDBOX}/leases" \
       PULZR_MQTT_AGENT="${STUBS}/agent" PULZR_LAN_PUSH_WAIT=1

pass=0 fail=0
check() {
    local name="$1" want="$2" got
    got="$(cat "${SANDBOX}/pushes" 2>/dev/null | wc -l | tr -d ' ')"
    if [ "${got:-0}" = "${want}" ]; then pass=$((pass + 1)); echo "ok   ${name}"
    else fail=$((fail + 1)); echo "FAIL ${name}: ${got:-0} pushes, wanted ${want}"; fi
}
event() { ACTION="$1" sh "${HOOK}"; }
settle() { sleep 2; }

echo "1795619000 aa:bb:cc:dd:ee:01 192.168.61.10 meter-1 *" > "${SANDBOX}/leases"
event add; settle
check "not adopted: nothing" 0

echo adopted > "${SANDBOX}/adopted"
event add; settle
check "a new lease is pushed" 1

for i in 1 2 3 4 5 6; do event update; done; settle
check "renewals that change nothing are not" 1

echo "1795622600 aa:bb:cc:dd:ee:01 192.168.61.10 meter-1 *" > "${SANDBOX}/leases"
event update; settle
check "only the expiry moved: not news" 1

echo "1795622600 aa:bb:cc:dd:ee:01 192.168.61.11 meter-1 *" > "${SANDBOX}/leases"
echo "1795622600 aa:bb:cc:dd:ee:02 192.168.61.12 cam-2 *" >> "${SANDBOX}/leases"
for i in 1 2 3; do event add; event update; done; settle
check "a burst with a moved and a new lease is one push" 2

: > "${SANDBOX}/leases"
event remove; settle
check "expiry is pushed" 3

ACTION=bogus sh "${HOOK}"; settle
check "other actions are ignored" 3

echo; echo "${pass} passed, ${fail} failed"
[ "${fail}" -eq 0 ]
