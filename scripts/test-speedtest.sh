#!/usr/bin/env bash
#
# pulzr-speedtest's test of one uplink, against stub librespeed-cli, curl and
# pulzr-uplinks and the router fixture's netifd and uci.
#
#   UCODE=/path/to/ucode scripts/test-speedtest.sh
#
# The Backhaul page tests any one connection, standby ones and cellular
# included. What has to hold: the test leaves through that uplink's own
# device and touches no route, the tunnel test is left out, a metered uplink
# runs only once somebody has confirmed its cost and for the short length the
# estimate was for, and the nightly run still never touches cellular.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UCODE="${UCODE:-ucode}"
command -v "${UCODE}" >/dev/null 2>&1 || { echo "ucode not found; set UCODE=/path/to/ucode" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "jq not found" >&2; exit 2; }
MODULES="$(dirname "$(command -v "${UCODE}")")/*.so"

T="$(mktemp -d)"
trap 'rm -rf "${T}"' EXIT
export T UCI_JSON="${T}/uci.json" NET_JSON="${T}/net.json"
mkdir -p "${T}/bin"
export PATH="${T}/bin:${ROOT}/scripts/router-fixture/bin:${PATH}"

fail=0
check() {
    local what="$1" expected="$2" actual="$3"
    if [ "${actual}" = "${expected}" ]; then
        echo "ok   ${what}"
    else
        echo "FAIL ${what}"
        echo "     expected: ${expected}"
        echo "     actual:   ${actual}"
        fail=1
    fi
}

# Each tool as shipped but for its absolute paths, which point into the
# scratch directory.
sed -e "s#'/etc/pulzr/speedtest'#'${T}/state'#" \
    -e "s#/var/run/pulzr/speedtest.json#${T}/running.json#" \
    -e "s#'/var/run/pulzr'#'${T}'#" \
    -e "s#/usr/sbin/pulzr-uplinks#${T}/bin/pulzr-uplinks#g" \
    -e "s#/usr/sbin/pulzr-wireguard-route#${T}/bin/pulzr-wireguard-route#" \
    -e "s#/usr/sbin/pulzr-claim#${T}/bin/pulzr-claim#" \
    -e "s#/tmp/pulzr-speedtest#${T}/st#g" \
    "${ROOT}/feed/pulzr-speedtest/files/usr/sbin/pulzr-speedtest" > "${T}/speedtest.uc"
grep -q "${T}/bin/pulzr-uplinks" "${T}/speedtest.uc" || { echo "FAIL pulzr-speedtest's paths moved; update this script" >&2; exit 1; }

st() { "${UCODE}" -R -L "${ROOT}/scripts/router-fixture/*.uc" -L "${MODULES}" "${T}/speedtest.uc" "$@"; }

# librespeed-cli: records the device it was bound to and the duration, and
# answers 80 down, 20 up.
cat > "${T}/bin/librespeed-cli" <<'EOF'
#!/bin/sh
while [ $# -gt 0 ]; do
    case "$1" in --interface) dev="$2" ;; --duration) dur="$2" ;; esac
    shift
done
echo "librespeed ${dev} ${dur}" >> "${T}/calls"
echo '[{"server":{"name":"Test"},"download":80,"upload":20,"ping":12,"jitter":1,"bytes_received":50000000,"bytes_sent":12500000}]'
EOF
cat > "${T}/bin/curl" <<'EOF'
#!/bin/sh
while [ $# -gt 0 ]; do [ "$1" = --interface ] && dev="$2"; shift; done
echo "curl ${dev}" >> "${T}/calls"
echo '[{"name":"Test","server":"https://speed.example/"}]'
EOF
cat > "${T}/bin/pulzr-claim" <<'EOF'
#!/bin/sh
echo "claim $*" >> "${T}/calls"
[ "$1" = tunnel-test ] && echo '{"downloadMbps":30,"uploadMbps":10,"pingMs":40}'
exit 0
EOF
cat > "${T}/bin/pulzr-wireguard-route" <<'EOF'
#!/bin/sh
echo '{"via":"wired","iface":"wan","device":"eth0"}'
EOF
# WAN carries traffic; LAN 2 VLAN 20 is a standby cable; the SIM is up behind
# both.
cat > "${T}/bin/pulzr-uplinks" <<'EOF'
#!/bin/sh
cat <<'JSON'
{"order":["wan","wan_lan2_20","wwan"],"active":"wan","uplinks":[
 {"iface":"wan","kind":"ethernet","up":true,"device":"eth0","state":"online"},
 {"iface":"wan_lan2_20","kind":"ethernet","up":true,"device":"lan2.20","state":"online"},
 {"iface":"wwan","kind":"cellular","up":true,"device":"wwan0","state":"untracked"}]}
JSON
EOF
chmod +x "${T}/bin/"*
echo '{"pulzr": {"speedtest": {".type": "speedtest", ".name": "speedtest", "every": "daily", "duration": "10"}}}' > "${UCI_JSON}"
echo '{}' > "${NET_JSON}"
: > "${T}/events"

: > "${T}/calls"
st run wan_lan2_20 >/dev/null
check "one uplink: bound to its own device, the full length" \
    $'curl lan2.20\nlibrespeed lan2.20 10' "$(grep -v '^claim report' "${T}/calls")"
check "one uplink: no route touched" '0' "$(grep -c reload "${T}/events" || true)"
check "one uplink: recorded against it" '{"iface":"wan_lan2_20","metered":false,"downloadMbps":80}' \
    "$(jq -c '.[-1] | {iface, metered, downloadMbps}' "${T}/state/history.json")"

: > "${T}/calls"
st run wwan >/dev/null 2>&1 && r=0 || r=$?
check "cellular: refused without the confirm" '2' "${r}"
check "cellular: nothing sent" '' "$(cat "${T}/calls")"
check "cellular: the estimate with no earlier test" '[{"iface":"wwan","seconds":5,"estimateMB":44,"from":"assumed"}]' \
    "$(st status | jq -c .metered)"

st run wwan metered >/dev/null
check "cellular, confirmed: bound to the modem, five seconds" \
    $'curl wwan0\nlibrespeed wwan0 5' "$(grep -v '^claim report' "${T}/calls")"
check "cellular: recorded as metered" '{"iface":"wwan","kind":"cellular","metered":true,"duration":5}' \
    "$(jq -c '.[-1] | {iface, kind, metered, duration}' "${T}/state/history.json")"
check "cellular: the estimate from its last test" '63' "$(st status | jq '.metered[0].estimateMB')"

st run wifi0 >/dev/null 2>&1 && r=0 || r=$?
check "not an uplink: refused" '2' "${r}"

: > "${T}/calls"
st run >/dev/null
check "every uplink: wired only, never cellular, then the tunnel" \
    $'curl eth0\nlibrespeed eth0 10\ncurl lan2.20\nlibrespeed lan2.20 10\nclaim tunnel-test 10' \
    "$(grep -v '^claim report' "${T}/calls")"

exit "${fail}"
