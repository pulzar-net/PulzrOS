#!/usr/bin/env bash
#
# The WiFi uplink's verdict, its resolver, roam() and the TUI's WiFi page,
# against a fake netifd, curl, DNS and iwinfo.
#
#   UCODE=/path/to/ucode scripts/test-wifi-uplink.sh
#
# The ucode needs its fs module beside it, as CI's build has. Each program
# runs as shipped except for its absolute paths, which point into a scratch
# directory.
#
# What this guards: a gateway joined to eduroam and put back on a guest
# network within the minute, a network called offline because one host was
# blocked or one DNS datagram lost, and a portal that drops the probe left
# with no way to sign in.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UCODE="${UCODE:-ucode}"
command -v "${UCODE}" >/dev/null 2>&1 || { echo "ucode not found; set UCODE=/path/to/ucode" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "jq not found" >&2; exit 2; }
MODULES="$(dirname "$(command -v "${UCODE}")")/*.so"
FIX="${ROOT}/scripts/wifi-fixture"

T="$(mktemp -d)"
trap 'rm -rf "${T}"' EXIT
export T UCI_JSON="${T}/uci.json"
export PATH="${FIX}/bin:${PATH}"
mkdir -p "${T}/run"

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

# ── pulzr-wifi-uplink check ─────────────────────────────────────────────────

sed -e "s#/lib/functions/network.sh#${FIX}/network.sh#" \
    -e "s#/usr/share/libubox/jshn.sh#${FIX}/jshn.sh#" \
    -e "s#/var/run/pulzr/#${T}/run/#g" \
    -e "s#/usr/sbin/pulzr-wifi-resolve#pulzr-wifi-resolve#" \
    "${ROOT}/feed/pulzr-base/files/usr/sbin/pulzr-wifi-uplink" > "${T}/uplink.sh"

G=connectivitycheck_gstatic_com C=cp_cloudflare_com
# Every case starts from a working network; each unsets what it breaks.
reset() {
    unset "RESOLVE_${G}" "RESOLVE_${C}" "CURL_http_${G}" "CURL_http_${C}" "CURL_https_${C}" 2>/dev/null || true
    export WIFI_DEV=phy0-sta0 WIFI_GW=10.30.0.1 WIFI_DNS="10.30.0.53 10.30.0.54" WIFI_SSID=eduroam
    export "RESOLVE_${G}=142.250.80.3" "RESOLVE_${C}=104.16.132.229"
    export "CURL_http_${G}=0 204 0.01 0" "CURL_http_${C}=0 204 0.01 0" "CURL_https_${C}=0 204 0.02 0"
    : > "${T}/curls"
}
up()     { sh "${T}/uplink.sh" "$@"; }
field()  { jq -r ".$1 // \"-\"" "${T}/run/wifi-uplink.json"; }
answer() { jq -c '{state, step, host, detail}' "${T}/run/wifi-uplink.json"; }

rm -f "${T}/run/wifi-uplink.json" "${T}/log"
reset; up check
check "open: 204 from the first host" '{"state":"open","step":null,"host":null,"detail":null}' "$(answer)"
check "open: only the first host asked" "1" "$(wc -l < "${T}/curls" | tr -d ' ')"
check "open: about this network" "eduroam" "$(field ssid)"
up usable && u=yes || u=no
check "open: usable" yes "${u}"
WIFI_SSID=Guest up usable && u=yes || u=no
check "an answer about another network is not usable" no "${u}"

# A second radio's station: its own answer, about its own network, so it is
# proven on its own and never inherits the first one's "open".
WIFI_SSID2=Charter up check wwifi2
check "a second station: its own answer, about its network" "open Charter" \
    "$(jq -r '"\(.state) \(.ssid)"' "${T}/run/wifi-uplink-wwifi2.json")"
check "a second station: the first one's answer untouched" "eduroam" "$(field ssid)"
WIFI_SSID2=Charter up usable wwifi2 && u=yes || u=no
check "a second station: usable on its own answer" yes "${u}"
rm -f "${T}/run/wifi-uplink-wwifi2.json"
WIFI_SSID2=Charter up usable wwifi2 && u=yes || u=no
check "a second station unchecked is not usable, whatever the first says" no "${u}"
up usable wwifi3 2>/dev/null && u=yes || u=no
check "not a WiFi uplink: refused" no "${u}"

reset; WIFI_GW='' up check
check "no gateway in the lease" '{"state":"offline","step":"no_gateway","host":null,"detail":null}' "$(answer)"

reset; WIFI_DNS='fe80::1' up check
check "no IPv4 DNS server in the lease" '{"state":"offline","step":"no_dns","host":null,"detail":null}' "$(answer)"

rm -f "${T}/log"
reset
export "RESOLVE_${G}=4:noanswer 10.30.0.53 10.30.0.54" "RESOLVE_${C}=4:noanswer 10.30.0.53 10.30.0.54"
up check
check "DNS silent: offline, which servers" \
    '{"state":"offline","step":"dns","host":"connectivitycheck.gstatic.com","detail":"10.30.0.53 10.30.0.54"}' "$(answer)"
up check
check "DNS silent: logged once, with why" \
    "WiFi uplink eduroam: offline (dns connectivitycheck.gstatic.com: 10.30.0.53 10.30.0.54) http://connectivitycheck.gstatic.com/generate_204" \
    "$(cat "${T}/log")"

reset; export "RESOLVE_${G}=5:noaddress 10.30.0.53"
up check
check "a DNS filter refusing one host does not cost the uplink" "open" "$(field state)"

reset; export "CURL_http_${G}=28 000 0.000000 0"
up check
check "one host timing out does not cost the uplink" "open" "$(field state)"

reset; export "CURL_http_${G}=28 000 0.000000 0" "CURL_http_${C}=28 000 0.000000 0"
up check
check "port 80 shut, HTTPS verifies: open" "open" "$(field state)"

reset; export "CURL_http_${G}=28 000 0.000000 0" "CURL_http_${C}=28 000 0.000000 0" "CURL_https_${C}=28 000 0.000000 0"
up check
check "nothing answers: offline, the connection timed out" \
    '{"state":"offline","step":"connect_timeout","host":"connectivitycheck.gstatic.com","detail":"142.250.80.3"}' "$(answer)"

reset; export "CURL_http_${G}=28 000 0.020 0" "CURL_http_${C}=28 000 0.020 0" "CURL_https_${C}=28 000 0.020 0"
up check
check "connected, no HTTP answer: http_timeout" "offline http_timeout" "$(field state) $(field step)"

reset; export "CURL_http_${G}=7 000 0 0" "CURL_http_${C}=7 000 0 0" "CURL_https_${C}=7 000 0 0"
up check
check "refused everywhere: connect" "offline connect 142.250.80.3" "$(field state) $(field step) $(field detail)"

reset; export "CURL_http_${G}=28 000 0 0" "CURL_http_${C}=28 000 0 0" "CURL_https_${C}=60 000 0.02 0"
up check
check "probe dropped, TLS intercepted: portal" "portal tls cp.cloudflare.com" "$(field state) $(field step) $(field host)"

reset; export "RESOLVE_${G}=10.30.0.1" "RESOLVE_${C}=10.30.0.1" \
    "CURL_http_${G}=7 000 0 0" "CURL_http_${C}=7 000 0 0"
up check
check "probe dropped, DNS answers the portal's own address: portal" \
    "portal dns_hijack 10.30.0.1 10.30.0.1" "$(field state) $(field step) $(field detail) $(field hijack)"
check "dns_hijack: the probe URL to start from" "http://connectivitycheck.gstatic.com/generate_204" "$(field url)"

reset; export "CURL_http_${G}=0 302 0.01 0 https://portal.example/login?mac=1" \
    "CURL_http_${C}=0 302 0.01 0 https://portal.example/login?mac=1"
up check
check "redirect: portal, where it pointed" "portal portal https://portal.example/login?mac=1" \
    "$(field state) $(field step) $(field url)"

reset; export "CURL_http_${G}=0 200 0.01 812" "CURL_http_${C}=0 200 0.01 812"
up check
check "a page: portal, its refresh target" "portal http://portal.example/login" "$(field state) $(field url)"

reset; export "CURL_http_${G}=0 200 0.01 0"
up check
check "an empty 200 is a transparent proxy, not a portal" "open" "$(field state)"

reset; export "CURL_http_${G}=0 403 0.01 120" "CURL_http_${C}=0 403 0.01 120"
up check
check "403 everywhere: code" "portal code 403" "$(field state) $(field step) $(field detail)"

reset; export "CURL_http_${G}=7 000 0 0" "CURL_http_${C}=7 000 0 0" "CURL_https_${C}=7 000 0 0"
up check
since="$(field since)"
echo '{"state":"offline","ssid":"Guest","since":1,"checkedAt":1}' > "${T}/run/wifi-uplink.json"
up check
check "another network's verdict is not carried over" "yes" "$([ "$(field since)" -gt 1 ] && echo yes || echo no)"

reset; WIFI_DEV='' up check
check "not associated: no answer kept" "gone" "$([ -f "${T}/run/wifi-uplink.json" ] && echo kept || echo gone)"

# ── pulzr-wifi-resolve ──────────────────────────────────────────────────────

echo '{"up": true, "l3_device": "phy0-sta0", "dns-server": ["10.30.0.53", "fe80::1", "10.30.0.54"]}' > "${T}/wwifi.json"
resolve() {
    : > "${T}/dns"
    FAKE_DNS="$1" "${UCODE}" -R -L "${FIX}/*.uc" -L "${MODULES}" \
        "${ROOT}/feed/pulzr-base/files/usr/sbin/pulzr-wifi-resolve" connectivitycheck.gstatic.com 2>"${T}/err"
}
got="$(resolve '10.30.0.53=a:142.250.80.3')"; rc=$?
check "resolve: the first server's address" "0 142.250.80.3" "${rc} ${got}"
got="$(resolve '10.30.0.53=drop,10.30.0.54=a:142.250.80.4')"; rc=$?
check "resolve: the second server when the first is silent" "0 142.250.80.4" "${rc} ${got}"
got="$(resolve '10.30.0.53=tc:142.250.80.5')"; rc=$?
check "resolve: a truncated answer is asked again over TCP" "0 142.250.80.5 udp 10.30.0.53|tcp 10.30.0.53" \
    "${rc} ${got} $(paste -sd'|' "${T}/dns")"
set +e
resolve '' >/dev/null; rc=$?
check "resolve: nobody answers, both asked twice" "4 noanswer 10.30.0.53 10.30.0.54 4" \
    "${rc} $(cat "${T}/err") $(wc -l < "${T}/dns" | tr -d ' ')"
resolve '10.30.0.53=nx,10.30.0.54=nx' >/dev/null; rc=$?
check "resolve: NXDOMAIN is an answer, not asked again" "5 noaddress 10.30.0.53 10.30.0.54 2" \
    "${rc} $(cat "${T}/err") $(wc -l < "${T}/dns" | tr -d ' ')"
echo '{"up": true, "l3_device": "phy0-sta0", "dns-server": ["fe80::1"]}' > "${T}/wwifi.json"
resolve '' >/dev/null; rc=$?
check "resolve: no IPv4 server in the lease" "3 nodns" "${rc} $(cat "${T}/err")"
set -e

# ── roam() and the console's view of it ─────────────────────────────────────

LIB="${T}/lib"
mkdir -p "${LIB}" "${T}/sys/class/ieee80211/phy0" "${T}/sys/class/net"
for f in "${ROOT}"/feed/pulzr-console/files/usr/share/pulzr/console/lib/*.uc; do
    sed -e "s#/usr/share/pulzr/console/lib/#${LIB}/#g" \
        -e "s#/var/run/pulzr/#${T}/run/#g" \
        -e "s#/var/run/#${T}/run/#g" \
        -e "s#/tmp/pulzr-signin#${T}/signin#g" \
        -e "s#/tmp/pulzr-wifi-probe#${T}/probe#g" \
        -e "s#'/sys/class/#'${T}/sys/class/#g" \
        "${f}" > "${LIB}/$(basename "${f}")"
done
cat > "${T}/drive.uc" <<EOF
let access = loadfile('${LIB}/access.uc', { raw_mode: true })();
let out = {};
for (let step in split(ARGV[0], ',')) {
    if (step == 'roam') out.roam = access.roam();
    else if (step == 'join') out.join = access.joinWifi({ ssid: ARGV[1], saved: true });
    else if (step == 'detail') out.detail = access.wifiDetail();
}
print(sprintf('%J\n', out));
EOF
console() { "${UCODE}" -R -L "${ROOT}/scripts/router-fixture/*.uc" -L "${MODULES}" "${T}/drive.uc" "$@"; }

now="$(date +%s)"
uci_on() {
    cat > "${UCI_JSON}" <<EOF
{"wireless": {"radio0": {".type": "wifi-device", ".name": "radio0"},
              "parkeze_sta": {".type": "wifi-iface", ".name": "parkeze_sta", "ssid": "$1"}},
 "network": {"wwifi": {".type": "interface", ".name": "wwifi"}},
 "firewall": {"wan": {".type": "zone", ".name": "wan", "network": "wan wwifi"}},
 "pulzr": {"a": {".type": "wifi_network", ".name": "a", "ssid": "eduroam", "security": "psk", "key": "abcdefgh"},
           "b": {".type": "wifi_network", ".name": "b", "ssid": "Campus Guest", "security": "open"}}}
EOF
}
echo '{"results": [{"ssid": "Campus Guest", "signal": -60, "quality": 50, "encryption": "none"}]}' > "${T}/scan.json"
echo '{"up": true, "l3_device": "phy0-sta0"}' > "${T}/wwifi.json"

uci_on eduroam
echo "{\"state\":\"offline\",\"ssid\":\"eduroam\",\"step\":\"dns\",\"host\":\"connectivitycheck.gstatic.com\",\"detail\":\"10.30.0.53 10.30.0.54\",\"since\":$((now - 200))}" \
    > "${T}/run/wifi-uplink.json"
echo "{\"downSince\": $((now - 200))}" > "${T}/run/pulzr-wifi-roam.json"
rm -f "${T}/run/wifi-roams.json"
out="$(console detail,roam)"
check "detail: the failing step as a sentence" "DNS 10.30.0.53, 10.30.0.54 did not answer." \
    "$(jq -r .detail.uplink.reason <<< "${out}")"
check "roam: three minutes offline, switched" "switched eduroam Campus Guest dns" \
    "$(jq -r '[.roam.action, .roam.from, .roam.to, .roam.why.step] | join(" ")' <<< "${out}")"
check "roam: recorded" '[{"from":"eduroam","to":"Campus Guest","step":"dns"}]' \
    "$(jq -c '[.[] | {from, to, step: .why.step}]' "${T}/run/wifi-roams.json")"
check "roam: the old network's answer is dropped" "gone" \
    "$([ -f "${T}/run/wifi-uplink.json" ] && echo kept || echo gone)"
out="$(console detail)"
check "detail: the last roam, why" "Campus Guest DNS did not answer for 3 min" \
    "$(jq -r '[.detail.roam.to, .detail.roam.reason] | join(" ")' <<< "${out}")"

# The owner's report: a gateway behind a guest portal for an hour is joined
# to eduroam, which is not up yet at the next minute.
uci_on "Campus Guest"
echo "{\"state\":\"portal\",\"ssid\":\"Campus Guest\",\"step\":\"portal\",\"since\":$((now - 3600))}" > "${T}/run/wifi-uplink.json"
echo "{\"downSince\": $((now - 3600))}" > "${T}/run/pulzr-wifi-roam.json"
echo '{"up": false}' > "${T}/wwifi.json"
echo '{"results": [{"ssid": "Campus Guest", "signal": -50, "quality": 60, "encryption": "none"}]}' > "${T}/scan.json"
out="$(console join,roam,roam eduroam)"
check "join: the guest network's verdict goes with it" "gone" \
    "$([ -f "${T}/run/wifi-uplink.json" ] && echo kept || echo gone)"
check "join: roam() does not undo it the next minute" "none" "$(jq -r .roam.action <<< "${out}")"
check "join: still on eduroam" "eduroam" "$(jq -r .wireless.parkeze_sta.ssid "${UCI_JSON}")"

uci_on eduroam
echo '{"up": true, "l3_device": "phy0-sta0"}' > "${T}/wwifi.json"
echo "{\"state\":\"portal\",\"ssid\":\"Campus Guest\",\"since\":1}" > "${T}/run/wifi-uplink.json"
echo "{\"downSince\": $((now - 3600))}" > "${T}/run/pulzr-wifi-roam.json"
check "roam: another network's portal is not this one's" "none up" \
    "$(console roam | jq -r '[.roam.action, .roam.reason] | join(" ")')"

echo "{\"state\":\"portal\",\"ssid\":\"eduroam\",\"since\":1}" > "${T}/run/wifi-uplink.json"
echo "{\"downSince\": $((now - 3600))}" > "${T}/run/pulzr-wifi-roam.json"
mkdir -p "${T}/signin/sessions"
echo "{\"subject\":\"t\",\"expires\":$((now + 600)),\"trust\":[]}" > "${T}/signin/sessions/$(printf 'a%.0s' $(seq 64))"
check "roam: held while somebody signs in" "none signing in" \
    "$(console roam | jq -r '[.roam.action, .roam.reason] | join(" ")')"
rm -rf "${T}/signin"

for i in $(seq 12); do
    echo "{\"state\":\"offline\",\"ssid\":\"eduroam\",\"since\":1}" > "${T}/run/wifi-uplink.json"
    echo "{\"downSince\": $((now - 3600))}" > "${T}/run/pulzr-wifi-roam.json"
    uci_on eduroam
    console roam > /dev/null
done
check "roam history: the last ten" "10" "$(jq length "${T}/run/wifi-roams.json")"

# ── the terminal UI's WiFi page ─────────────────────────────────────────────

TUI="${ROOT}/feed/pulzr-tui/files/usr/share/pulzr/tui"
cat > "${T}/tui.uc" <<EOF
let api = loadfile('${ROOT}/scripts/tui-fixture/api.uc', { raw_mode: true })();
let fmt = loadfile('${TUI}/fmt.uc', { raw_mode: true })();
let ctx = {
    api, fmt,
    ui: { status: (ok, a, b, w) => w ?? (ok ? a : b), glyph: () => '-' },
    act: (name, req) => api.act(name, req),
    qr: (text) => [ 'QR' ],
    term: { cols: (s) => length(s), pad: (s, n) => s, clip: (s, n) => s, state: { rows: 40 } },
    later: () => null, refresh: () => null, flash: () => null,
};
let page = loadfile('${TUI}/pages/wifi.uc', { raw_mode: true })()(ctx);
page.load();
let lines = (rows) => map(filter(rows, (r) => r.t == 'notice' || r.t == 'buttons' || (r.t == 'fact' && r.label == 'Open')),
    (r) => r.t == 'notice' ? r.text : (r.t == 'fact' ? 'Open ' + r.value.text
                                                     : join('/', map(r.items, (i) => i.label))));
let first = page.view(80);
print(join('\n', slice(lines(first), 0, 4)), '\n');
for (let r in first) if (r.t == 'buttons') for (let i in r.items) if (i.key == 'wifi-signin') i.run();
print(join('\n', lines(page.view(80))), '\n');
EOF
out="$(TZ=UTC "${UCODE}" -R -L "${MODULES}" "${T}/tui.uc")"
check "tui: sign in, check again, the reason and the last roam" \
    "Sign in/Check again/Forget network|Site-Ops: DNS sends connectivitycheck.gstatic.com to 10.30.0.1.|Left eduroam at 06:13: DNS did not answer for 3 min. Joined Site-Ops." \
    "$(sed -n 1,3p <<< "${out}" | paste -sd'|' -)"
check "tui: then a URL to open, on the gateway's local name" \
    "Open https://pulzr-1234ab.local:8443/signin/session?t=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef" \
    "$(grep '^Open ' <<< "${out}" | sed 's/  [0-9]*m [0-9]*s$//')"

exit "${fail}"
