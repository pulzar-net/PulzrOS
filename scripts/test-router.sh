#!/usr/bin/env bash
#
# pulzr-uplinks, pulzr-dns, pulzr-ports and pulzr-lan against a JSON-backed uci, a fake netifd
# and a ping that answers out of the devices it is told to.
#
#   UCODE=/path/to/ucode scripts/test-router.sh
#
# The ucode needs its fs module beside it, as CI's build has. Both tools run
# as shipped except for their absolute paths, which point into a scratch
# directory, and the run loop, which takes a fixed number of rounds instead
# of sleeping forever.
#
# Failover is the thing no bench has exercised: a cable that keeps its link
# while the internet behind it is gone. This walks the tracker through that,
# and back.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UCODE="${UCODE:-ucode}"
command -v "${UCODE}" >/dev/null 2>&1 || { echo "ucode not found; set UCODE=/path/to/ucode" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "jq not found" >&2; exit 2; }
MODULES="$(dirname "$(command -v "${UCODE}")")/*.so"

T="$(mktemp -d)"
trap 'rm -rf "${T}"' EXIT
export T UCI_JSON="${T}/uci.json" NET_JSON="${T}/net.json"
export PATH="${ROOT}/scripts/router-fixture/bin:${PATH}"

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

# system()'s timeout argument hangs ucode on macOS; on the gateway it bounds a
# dnsmasq reload, which the fixture does not have.
sed -e "s#/var/run/pulzr/uplinks.json#${T}/uplinks.json#" \
    -e 's#while (true) sleep(round() \* 1000);#for (let k = 0; k < int(getenv("ROUNDS")); k++) round();#' \
    "${ROOT}/feed/pulzr-uplinks/files/usr/sbin/pulzr-uplinks" > "${T}/uplinks.uc"
sed -e "s#/etc/pulzr/board.conf#${T}/board.conf#" \
    -e "s#/tmp/resolv.conf.d/resolv.conf.auto#${T}/resolv#" \
    -e "s#'/etc/config/ddns'#'${T}/ddns.conf'#" \
    -e "s#'/var/run/ddns/'#'${T}/ddns-run/'#" \
    -e "s#'/var/log/ddns/'#'${T}/ddns-log/'#" \
    -e 's/, [0-9]*000)/)/' \
    "${ROOT}/feed/pulzr-dns/files/usr/sbin/pulzr-dns" > "${T}/dns.uc"
grep -q 'getenv("ROUNDS")' "${T}/uplinks.uc" || { echo "FAIL the run loop moved; update this script" >&2; exit 1; }

up()  { "${UCODE}" -R -L "${ROOT}/scripts/router-fixture/*.uc" -L "${MODULES}" "${T}/uplinks.uc" "$@"; }
dns() { "${UCODE}" -R -L "${ROOT}/scripts/router-fixture/*.uc" -L "${MODULES}" "${T}/dns.uc" "$@"; }
metrics() { jq -c '[.network.wan.metric, .network.wwan.metric, .network.usbwan.metric]' "${UCI_JSON}"; }
state()   { jq -r ".${1}.state // \"none\"" "${T}/uplinks.json"; }

# ── uplinks ─────────────────────────────────────────────────────────────────

cat > "${UCI_JSON}" <<'EOF'
{"network": {"wan": {".type": "interface", ".name": "wan", "metric": "10"},
             "wwan": {".type": "interface", ".name": "wwan", "metric": "20"},
             "usbwan": {".type": "interface", ".name": "usbwan", "metric": "21"},
             "devlan": {".type": "interface", ".name": "devlan"}},
 "pulzr": {"uplinks": {".type": "uplinks", ".name": "uplinks", "track": ["wan"],
             "track_ip": ["1.1.1.1", "8.8.8.8"], "interval": "10", "down": "3", "up": "2"}}}
EOF
echo '{"wan": {"up": true, "l3_device": "eth0"}, "wwan": {"up": true, "l3_device": "wwan0"}, "usbwan": {"up": false}}' > "${NET_JSON}"
echo eth0 > "${T}/ping_ok"
: > "${T}/events"

up apply
check "apply: metrics from the order" '["10","20","30"]' "$(metrics)"
check "apply: one reload" 'reload' "$(cat "${T}/events")"
: > "${T}/events"
check "status: order, Ethernet carrying, cellular untracked" \
    '{"order":["wan","wwan","usbwan"],"active":"wan","states":["unchecked","untracked","down"]}' \
    "$(up status | jq -c '{order, active, states: [.uplinks[].state]}')"

ROUNDS=2 up run
check "answering: online, metrics unchanged" 'online ["10","20","30"]' "$(state wan) $(metrics)"
check "answering: no reload" '' "$(cat "${T}/events")"

: > "${T}/ping_ok"
ROUNDS=2 up run
check "two misses: still online (down is 3)" 'online ["10","20","30"]' "$(state wan) $(metrics)"
up usable wan && u=yes || u=no
check "two misses: still usable" 'yes' "${u}"

ROUNDS=1 up run
check "third miss: offline, Ethernet behind cellular" 'offline ["100","20","30"]' "$(state wan) $(metrics)"
up usable wan && u=yes || u=no
check "third miss: not usable for the tunnel" 'no' "${u}"
check "third miss: cellular carries traffic" 'wwan' "$(up status | jq -r .active)"
check "third miss: logged and reloaded" 'log: wan online -> offline|reload' "$(paste -sd'|' "${T}/events")"
: > "${T}/events"

echo eth0 > "${T}/ping_ok"
ROUNDS=1 up run
check "one answer: still offline (up is 2)" 'offline ["100","20","30"]' "$(state wan) $(metrics)"
ROUNDS=1 up run
check "second answer: back in front" 'online ["10","20","30"]' "$(state wan) $(metrics)"
: > "${T}/events"

up order wwan wan >/dev/null
check "order: cellular first, the rest appended" '["20","10","30"]' "$(metrics)"
check "order: saved as named" '["wwan","wan"]' "$(jq -c .pulzr.uplinks.order "${UCI_JSON}")"
up order wan wifi >/dev/null 2>&1 && r=0 || r=$?
check "order: an uplink the gateway lacks is refused" '2' "${r}"
up order wan wan >/dev/null 2>&1 && r=0 || r=$?
check "order: a repeat is refused" '2' "${r}"
up order wan wwan usbwan >/dev/null

up tracking 9.9.9.9,1.1.1.1 30 2 1 >/dev/null
check "tracking: saved" '{"ips":["9.9.9.9","1.1.1.1"],"interval":30,"down":2,"up":1}' "$(up status | jq -c .tracking)"
for bad in "1.1.1.300 10 3 3" "1.1.1.1 4 3 3" "1.1.1.1 10 0 3" "1.1.1.1,2.2.2.2,3.3.3.3,4.4.4.4,5.5.5.5 10 3 3"; do
    # shellcheck disable=SC2086
    up tracking ${bad} >/dev/null 2>&1 && r=0 || r=$?
    check "tracking: refuses ${bad}" '2' "${r}"
done
up tracking 1.1.1.1,8.8.8.8 10 3 2 >/dev/null

# The Backhaul page's drag and drop, through the console API's own module:
# the body it posts to /api/uplinks/order and /api/uplinks/track, into
# pulzr-uplinks, and on to the metrics and the tracker. The order a person
# drops in is the order failover runs in.
cat > "${T}/pulzr-uplinks" <<EOF
#!/bin/sh
exec "${UCODE}" -R -L "${ROOT}/scripts/router-fixture/*.uc" -L "${MODULES}" "${T}/uplinks.uc" "\$@"
EOF
chmod +x "${T}/pulzr-uplinks"
sed -e "s#/usr/share/pulzr/console/lib/util.uc#${ROOT}/feed/pulzr-console/files/usr/share/pulzr/console/lib/util.uc#" \
    -e "s#'/usr/sbin/pulzr-uplinks'#'${T}/pulzr-uplinks'#" \
    "${ROOT}/feed/pulzr-console/files/usr/share/pulzr/console/lib/uplinks.uc" > "${T}/console-uplinks.uc"
grep -q "${T}/pulzr-uplinks" "${T}/console-uplinks.uc" || { echo "FAIL lib/uplinks.uc's tool path moved; update this script" >&2; exit 1; }
page() {
    BODY="$2" "${UCODE}" -R -L "${MODULES}" -e "
        let m = loadfile('${T}/console-uplinks.uc', { raw_mode: true })();
        printf('%J\n', m['$1'](json(getenv('BODY'))));"
}

check "page: cellular dropped on top is saved" '{"order":["wwan","wan","usbwan"],"active":"wwan"}' \
    "$(page setOrder '{"order": ["wwan", "wan", "usbwan"]}' | jq -c '{order, active}')"
check "page: the order is in UCI" '["wwan","wan","usbwan"]' "$(jq -c .pulzr.uplinks.order "${UCI_JSON}")"
check "page: the metrics follow it" '["20","10","30"]' "$(metrics)"
page setTrack '{"iface": "wwan", "on": true}' >/dev/null
ROUNDS=3 up run
check "page: tracking moves off the top one to the next in the dropped order" 'offline ["20","100","30"] wan' \
    "$(state wwan) $(metrics) $(up status | jq -r .active)"
check "page: a repeat is refused" 'true' "$(page setOrder '{"order": ["wan", "wan"]}' | jq 'has("error")')"
page setTrack '{"iface": "wwan", "on": false}' >/dev/null
page setOrder '{"order": ["wan", "wwan", "usbwan"]}' >/dev/null
check "page: back to the cable first" '["10","20","30"]' "$(metrics)"

: > "${T}/ping_ok"
ROUNDS=3 up run
check "offline again" 'offline' "$(state wan)"
up track wan off >/dev/null
check "tracking off: state dropped, metric back" 'none ["10","20","30"]' "$(state wan) $(metrics)"
check "tracking off: none rather than the default" '"none"' "$(jq -c .pulzr.uplinks.track "${UCI_JSON}")"
check "tracking off: Ethernet untracked" 'untracked' "$(up status | jq -r '.uplinks[0].state')"
up track wwifi on >/dev/null 2>&1 && r=0 || r=$?
check "track: the WiFi has its own check" '2' "${r}"

up track wan on >/dev/null
ROUNDS=3 up run
check "offline before the link drops" 'offline ["100","20","30"]' "$(state wan) $(metrics)"
echo '{"wan": {"up": false}, "wwan": {"up": true, "l3_device": "wwan0"}, "usbwan": {"up": false}}' > "${NET_JSON}"
ROUNDS=1 up run
check "link down: state dropped, so it returns unchecked" 'none ["10","20","30"]' "$(state wan) $(metrics)"
check "link down: shown as down, cellular carrying" 'down wwan' "$(up status | jq -r '"\(.uplinks[0].state) \(.active)"')"

# ── dns ─────────────────────────────────────────────────────────────────────

printf 'PULZR_NET_URL="https://net.parkeze.com"\nPULZR_MQTT_HOST="mqtt.parkeze.com"\n' > "${T}/board.conf"
printf '# Interface wan\nnameserver 192.168.1.1\n# Interface wwan\nnameserver 10.0.0.53\nnameserver 192.168.1.1\n' > "${T}/resolv"
cat > "${UCI_JSON}" <<'EOF'
{"dhcp": {"cfg01411c": {".type": "dnsmasq", ".name": "cfg01411c", "rebind_protection": "1",
                        "server": ["/lan.example/10.1.1.1"]},
          "lan_aabbccddeeff": {".type": "host", ".name": "lan_aabbccddeeff", "mac": "aa:bb:cc:dd:ee:ff",
                               "ip": "192.168.70.10", "name": "plc-1"}}}
EOF
dnsmasq() { jq -c ".dhcp.cfg01411c | {server, noresolv, rebind_protection, rebind_domain}" "${UCI_JSON}"; }

check "status: the uplinks' servers, once each" \
    '{"mode":"auto","servers":["192.168.1.1","10.0.0.53"]}' "$(dns status | jq -c .upstream)"

dns upstream 9.9.9.9 149.112.112.112 >/dev/null
check "upstream: custom, ahead of the per-domain server" \
    '{"server":["9.9.9.9","149.112.112.112","/lan.example/10.1.1.1"],"noresolv":"1","rebind_protection":"1","rebind_domain":null}' \
    "$(dnsmasq)"
out="$(dns upstream 10.9.9.9 2>&1)" && r=0 || r=$?
check "upstream: a server that cannot resolve Pulzar is refused" \
    '3 no answer from 10.9.9.9 for mqtt.parkeze.com' "${r} ${out}"
for bad in "1.2.3" "1.1.1.1 1.1.1.1" "1.1.1.1 2.2.2.2 3.3.3.3 4.4.4.4"; do
    # shellcheck disable=SC2086
    dns upstream ${bad} >/dev/null 2>&1 && r=0 || r=$?
    check "upstream: refuses ${bad}" '2' "${r}"
done
dns upstream auto >/dev/null
check "upstream auto: the per-domain server stays" \
    '{"server":["/lan.example/10.1.1.1"],"noresolv":null,"rebind_protection":"1","rebind_domain":null}' "$(dnsmasq)"

dns host nas 192.168.70.20 >/dev/null
dns host nas-2.site 192.168.70.21 >/dev/null
dns host nas.2.site 192.168.70.22 >/dev/null
check "hosts: a-b and a.b stay two names" \
    '["nas","nas-2.site","nas.2.site"]' "$(dns status | jq -c '[.hosts[].name]')"
for bad in net.parkeze.com x.mqtt.PARKEZE.com parkeze.com; do
    out="$(dns host "${bad}" 1.2.3.4 2>&1)" && r=0 || r=$?
    check "hosts: ${bad} is Pulzar's" "2 names under parkeze.com are Pulzar's" "${r} ${out}"
done
out="$(dns host plc-1 1.2.3.4 2>&1)" && r=0 || r=$?
check "hosts: a reservation's name is refused" "3 plc-1 is a reservation's name" "${r} ${out}"
dns host -bad 1.2.3.4 >/dev/null 2>&1 && r=0 || r=$?
check "hosts: a label may not start with a hyphen" '2' "${r}"
dns host evilparkeze.com 1.2.3.4 >/dev/null && r=0 || r=$?
check "hosts: a lookalike is not Pulzar's" '0' "${r}"
dns unhost nas >/dev/null
dns unhost nas >/dev/null 2>&1 && r=0 || r=$?
check "unhost: gone, and a second time refused" '3 ["evilparkeze.com","nas-2.site","nas.2.site"]' \
    "${r} $(dns status | jq -c '[.hosts[].name]')"

dns rebind on corp.local site.internal >/dev/null
check "rebind: on, with allowed domains" '{"protection":true,"allowed":["corp.local","site.internal"]}' \
    "$(dns status | jq -c .rebind)"
dns rebind off >/dev/null
check "rebind: off, allowed cleared" '{"protection":false,"allowed":[]}' "$(dns status | jq -c .rebind)"

# Dynamic DNS: what ddns-scripts is told, and that the token goes in on stdin
# and never comes back out.
touch "${T}/ddns.conf"; mkdir -p "${T}/ddns-run" "${T}/ddns-log"
jq '.network = {"wan": {".type": "interface", ".name": "wan"}, "wan_lan1": {".type": "interface", ".name": "wan_lan1"},
                "wwifi": {".type": "interface", ".name": "wwifi"}, "wwan": {".type": "interface", ".name": "wwan"},
                "usbwan": {".type": "interface", ".name": "usbwan"}}
    | .ddns = {"global": {".type": "ddns", ".name": "global"}}' "${UCI_JSON}" > "${T}/u" && mv "${T}/u" "${UCI_JSON}"
TOKEN=abcdefghijklmnopqrstuvwxyz0123456789ABCD
check "ddns: the uplinks it may follow, never cellular" '["wan","wan_lan1","wwifi"]' "$(dns status | jq -c .ddns.uplinks)"
out="$(dns ddns cam.example.com example.com wwifi 2>&1)" && r=0 || r=$?
check "ddns: refused before a token" '3 set the API token first' "${r} ${out}"
out="$(echo 'not a token' | dns ddns-token 2>&1)" && r=0 || r=$?
check "ddns-token: refuses what is not one" '2' "${r}"
echo "${TOKEN}" | dns ddns-token >/dev/null
dns ddns cam.example.com example.com wwifi >/dev/null
check "ddns: what ddns-scripts is told" \
    '["1","cloudflare.com-v4","cam@example.com","Bearer","wwifi","wwifi","web","1"]' \
    "$(jq -c '.ddns.pulzr | [.enabled, .service_name, .domain, .username, .interface, .bind_network, .ip_source, .force_ipversion]' "${UCI_JSON}")"
check "ddns: curl, for binding to the uplink" '"1"' "$(jq -c .ddns.global.use_curl "${UCI_JSON}")"
check "ddns: status says a token is set and not what it is" 'true 0' \
    "$(dns status | jq -c .ddns.tokenSet) $(dns status | grep -c "${TOKEN}")"
dns ddns example.com example.com wan >/dev/null
check "ddns: the zone's own name" '"@example.com"' "$(jq -c .ddns.pulzr.domain "${UCI_JSON}")"
for bad in "cam.example.com example.com wwan" "cam.example.com example.com usbwan" \
           "cam.other.com example.com wan" "cam.parkeze.com parkeze.com wan" "cam.example.com com wan"; do
    # shellcheck disable=SC2086
    dns ddns ${bad} >/dev/null 2>&1 && r=0 || r=$?
    check "ddns: refuses ${bad}" 'nonzero' "$([ "${r}" -ne 0 ] && echo nonzero || echo 0)"
done
echo "198.51.100.7" > "${T}/ddns-run/pulzr.ip"
check "ddns: the registered address" '"198.51.100.7"' "$(dns status | jq -c .ddns.address)"
dns ddns off >/dev/null
check "ddns off: disabled, the token kept" '"0" true' \
    "$(jq -c .ddns.pulzr.enabled "${UCI_JSON}") $(dns status | jq -c .ddns.tokenSet)"

# ── ports ───────────────────────────────────────────────────────────────────
#
# The layout written into network, firewall, dhcp and the uplink order. The
# undo window's timer and snapshot are the gateway's (start-stop-daemon,
# /etc/config); here only what a layout renders to, what is refused, and that
# a confirm too soon is refused.

sed -e "s#/etc/pulzr/board.conf#${T}/board.conf#" \
    -e "s#'/usr/sbin/pulzr-apply'#'${T}/apply'#" \
    -e "s#'/etc/config/'#'${T}/config/'#" \
    "${ROOT}/feed/pulzr-base/files/usr/sbin/pulzr-ports" > "${T}/ports.uc"
grep -q "${T}/apply'" "${T}/ports.uc" || { echo "FAIL pulzr-ports' apply path moved; update this script" >&2; exit 1; }
mkdir -p "${T}/ports" "${T}/config" "${T}/applybin"
printf '#!/bin/sh\nexit 0\n' > "${T}/applybin/start-stop-daemon"; chmod +x "${T}/applybin/start-stop-daemon"
printf '#!/bin/sh\nPATH="%s:${PATH}" PULZR_APPLY_STATE="%s" PULZR_APPLY_CONFIG="%s" exec sh "%s" "$@"\n' \
    "${T}/applybin" "${T}/ports" "${T}/config" "${ROOT}/feed/pulzr-base/files/usr/sbin/pulzr-apply" > "${T}/apply"
chmod +x "${T}/apply"
ports() { "${UCODE}" -R -L "${ROOT}/scripts/router-fixture/*.uc" -L "${MODULES}" "${T}/ports.uc" "$@"; }

printf 'PULZR_PORT_IFACE="wan"\nPULZR_LAN_PORTS="lan1 lan2"\nPULZR_DEVLAN_IPADDR="192.168.64.1"\n' > "${T}/board.conf"
cat > "${UCI_JSON}" <<'EOF'
{"network": {"wan": {".type": "interface", ".name": "wan", "device": "wan", "proto": "static",
                     "ipaddr": "10.0.0.50", "netmask": "255.255.255.0", "gateway": "10.0.0.1", "metric": "10"},
             "console": {".type": "interface", ".name": "console", "device": "wan", "ipaddr": "192.168.61.1"},
             "linklocal": {".type": "interface", ".name": "linklocal", "device": "wan"},
             "wwan": {".type": "interface", ".name": "wwan", "metric": "20"},
             "devlan_dev": {".type": "device", ".name": "devlan_dev", "name": "br-devlan", "type": "bridge",
                            "ports": ["lan1", "lan2"]},
             "devlan": {".type": "interface", ".name": "devlan", "device": "br-devlan"}},
 "firewall": {"wan": {".type": "zone", ".name": "wan", "network": "wan console linklocal wwifi"}},
 "dhcp": {"cfg01": {".type": "dnsmasq", ".name": "cfg01", "notinterface": "wan"}},
 "pulzr": {"uplinks": {".type": "uplinks", ".name": "uplinks", "track": ["wan"], "order": ["wan", "wwan"]}}}
EOF

ports seed
check "seed: the board's shape, keeping wan's static address" \
    '[["wan","uplink","static"],["lan1","devices","dhcp"],["lan2","devices","dhcp"]]' \
    "$(ports status | jq -c '[.ports[] | [.name, .role, .addressing.mode]]')"
ports seed
check "seed: a kept layout is left alone" '3' "$(jq '[.pulzr[] | select(.[".type"] == "port")] | length' "${UCI_JSON}")"

cat > "${T}/layout.json" <<'EOF'
{"ports": [{"name": "wan", "role": "devices"},
           {"name": "lan1", "role": "uplink"},
           {"name": "lan2", "role": "uplink", "vlans": [
               {"vid": 20, "role": "uplink", "addressing": {"mode": "static", "address": "10.9.0.2",
                                                            "netmask": "255.255.255.0", "gateway": "10.9.0.1"}},
               {"vid": 30, "role": "devices"}]}]}
EOF
: > "${T}/events"
ports set "${T}/layout.json" tester >/dev/null
check "set: an uplink per link, named by device" '["wan_lan1","wan_lan2","wan_lan2_20"]' \
    "$(jq -c '[.network | to_entries[] | select(.value[".type"] == "interface" and (.key | test("^wan"))) | .key] | sort' "${UCI_JSON}")"
check "set: VLAN 20 static on lan2.20" '["lan2.20","static","10.9.0.2"]' \
    "$(jq -c '.network.wan_lan2_20 | [.device, .proto, .ipaddr]' "${UCI_JSON}")"
check "set: VLAN devices" '["lan2.20","lan2.30"]' \
    "$(jq -c '[.network | to_entries[] | select(.value.type == "8021q") | .value.name] | sort' "${UCI_JSON}")"
check "set: the bridge holds the LAN links" '["wan","lan2.30"]' "$(jq -c .network.devlan_dev.ports "${UCI_JSON}")"
check "set: the console moves to the first uplink port" '"lan1"' "$(jq -c .network.console.device "${UCI_JSON}")"
check "set: the wan zone, WiFi kept" '"wan_lan1 wan_lan2 wan_lan2_20 console linklocal wwifi"' \
    "$(jq -c .firewall.wan.network "${UCI_JSON}")"
check "set: dnsmasq stays off every uplink" '["lan1","lan2","lan2.20"]' "$(jq -c .dhcp.cfg01.notinterface "${UCI_JSON}")"
check "set: new uplinks tracked, wan gone" '["wan_lan1","wan_lan2","wan_lan2_20"]' "$(jq -c .pulzr.uplinks.track "${UCI_JSON}")"
check "set: new uplinks ordered ahead of cellular" '["wan_lan1","wan_lan2","wan_lan2_20","wwan"]' \
    "$(jq -c .pulzr.uplinks.order "${UCI_JSON}")"
check "set: pending, by whom" 'tester' "$(ports status | jq -r .pending.by)"
check "set: logged, then reloaded" 'reload' "$(grep -x reload "${T}/events" | head -n1)"
ports confirm >/dev/null 2>&1 && r=0 || r=$?
check "confirm: refused while the change settles" '3' "${r}"
echo '{"wan_lan1": {"up": true, "l3_device": "lan1"}, "wwan": {"up": true, "l3_device": "wwan0"}}' > "${NET_JSON}"
check "uplinks: the wired ones by kind, in order" \
    '[["wan_lan1","ethernet"],["wan_lan2","ethernet"],["wan_lan2_20","ethernet"],["wwan","cellular"]]' \
    "$(up status | jq -c '[.uplinks[] | [.iface, .kind]]')"

refuse() {
    local what="$1" body="$2" out r
    echo "${body}" > "${T}/bad.json"
    out="$(ports set "${T}/bad.json" 2>&1)" && r=0 || r=$?
    check "refuses: ${what}" "2" "${r}"
}
refuse "every port unused" '{"ports": [{"name": "wan", "role": "none"}, {"name": "lan1", "role": "none"}, {"name": "lan2", "role": "none"}]}'
refuse "a port the board lacks" '{"ports": [{"name": "lan9", "role": "uplink"}]}'
refuse "a VLAN ID of 5000" '{"ports": [{"name": "wan", "role": "uplink", "vlans": [{"vid": 5000, "role": "uplink"}]}]}'
refuse "a VLAN twice" '{"ports": [{"name": "wan", "role": "uplink", "vlans": [{"vid": 7, "role": "uplink"}, {"vid": 7, "role": "devices"}]}]}'
refuse "a static address in the console network" '{"ports": [{"name": "wan", "role": "uplink", "addressing": {"mode": "static", "address": "192.168.61.9", "netmask": "255.255.255.0", "gateway": "192.168.61.1"}}]}'
refuse "a static address in the LAN" '{"ports": [{"name": "wan", "role": "uplink", "addressing": {"mode": "static", "address": "192.168.64.9", "netmask": "255.255.0.0", "gateway": "192.168.1.1"}}]}'
refuse "a gateway off the subnet" '{"ports": [{"name": "wan", "role": "uplink", "addressing": {"mode": "static", "address": "10.0.0.9", "netmask": "255.255.255.0", "gateway": "10.0.1.1"}}]}'
refuse "two uplinks on one subnet" '{"ports": [{"name": "wan", "role": "uplink", "addressing": {"mode": "static", "address": "10.0.0.9", "netmask": "255.255.255.0", "gateway": "10.0.0.1"}}, {"name": "lan1", "role": "uplink", "addressing": {"mode": "static", "address": "10.0.0.10", "netmask": "255.255.255.0", "gateway": "10.0.0.1"}}]}'
refuse "not JSON" 'ports'

echo '{"ports": [{"name": "wan", "role": "uplink"}, {"name": "lan1", "role": "devices"}, {"name": "lan2", "role": "devices"}]}' > "${T}/layout.json"
ports set "${T}/layout.json" >/dev/null
check "back: wan is wan again, the board's port" '["wan","dhcp"]' "$(jq -c '.network.wan | [.device, .proto]' "${UCI_JSON}")"
check "back: VLAN devices gone" '0' "$(jq '[.network[] | select(.type == "8021q")] | length' "${UCI_JSON}")"
check "back: the console on wan" '"wan"' "$(jq -c .network.console.device "${UCI_JSON}")"
check "back: uplinks that went are out of the order" '["wan","wwan"]' "$(jq -c .pulzr.uplinks.order "${UCI_JSON}")"

# ── lan: exposed ports and cellular rules ───────────────────────────────────
#
# What pulzr-lan loads into its table (the nft fixture logs each script),
# and what it refuses. That the kernel takes the rules is the bench's to show.

sed -e "s#'/etc/pulzr/lan'#'${T}/lan'#" \
    -e "s#'/tmp/dhcp.leases'#'${T}/leases'#" \
    -e "s#/sys/class/net/#${T}/sys/#g" \
    -e "s#'/proc/net/arp'#'${T}/arp'#" \
    -e "s#'/var/run/pulzr'#'${T}/run'#" \
    -e "s#'/usr/sbin/pulzr-mqtt-agent'#'${T}/agent'#" \
    -e "s#'/proc/sys/kernel/random/boot_id'#'${T}/boot_id'#" \
    -e 's/, [0-9]*000)/)/' \
    "${ROOT}/feed/pulzr-lan/files/usr/sbin/pulzr-lan" > "${T}/lan.uc"
grep -q "${T}/lan'" "${T}/lan.uc" || { echo "FAIL pulzr-lan's state path moved; update this script" >&2; exit 1; }
lan() { "${UCODE}" -R -L "${ROOT}/scripts/router-fixture/*.uc" -L "${MODULES}" "${T}/lan.uc" "$@"; }
lastload() { awk '/^# load/ { buf = ""; next } { buf = buf $0 "\n" } END { printf "%s", buf }' "${T}/nft.log"; }
: > "${T}/nft.log"

cat > "${UCI_JSON}" <<'EOF'
{"network": {"devlan": {".type": "interface", ".name": "devlan", "ipaddr": "192.168.64.1", "netmask": "255.255.255.0"},
             "devlan_dev": {".type": "device", ".name": "devlan_dev", "name": "br-devlan", "ports": ["lan1", "lan2"]}},
 "dhcp": {"lan_c26c1dd1f7b3": {".type": "host", ".name": "lan_c26c1dd1f7b3", "mac": "c2:6c:1d:d1:f7:b3", "ip": "192.168.64.50"}},
 "firewall": {}, "pulzr": {}}
EOF
cat > "${NET_JSON}" <<'EOF'
{"wan": {"up": true, "l3_device": "wan", "ipv4-address": [{"address": "10.0.0.50", "mask": 24}]},
 "console": {"up": true, "l3_device": "wan", "ipv4-address": [{"address": "192.168.61.1", "mask": 24}]},
 "wan_lan1": {"up": true, "l3_device": "lan1", "ipv4-address": [{"address": "10.9.0.2", "mask": 24}]},
 "wwifi": {"up": true, "l3_device": "phy0-sta0", "ipv4-address": [{"address": "192.168.1.40", "mask": 24}]},
 "usbwan": {"up": true, "l3_device": "usb0", "ipv4-address": [{"address": "192.168.8.100", "mask": 24}]},
 "wwan": {"up": true, "l3_device": "wwan0", "ipv4-address": [{"address": "10.129.0.5", "mask": 30}]},
 "devlan": {"up": true, "l3_device": "br-devlan"}}
EOF

lan apply
check "links: wired and WiFi uplinks by device and address, never the console or cellular" \
    '"lan1" . 10.9.0.2, "phy0-sta0" . 192.168.1.40, "wan" . 10.0.0.50' \
    "$(lastload | sed -n 's/^add element inet pulzr_lan uplink_in { \(.*\) }$/\1/p' | tr ',' '\n' | sed 's/^ //' | sort | paste -sd, - | sed 's/,/, /g')"
check "links: the cellular devices" '"usb0", "wwan0"' \
    "$(lastload | sed -n 's/^add element inet pulzr_lan cellular_if { \(.*\) }$/\1/p' | tr ',' '\n' | sed 's/^ //' | sort | paste -sd, - | sed 's/,/, /g')"

refuse_lan() {
    local what="$1"; shift
    out="$(lan "$@" 2>&1)" && r=0 || r=$?
    check "refused: ${what}" "nonzero" "$([ "${r}" -ne 0 ] && echo nonzero || echo "0: ${out}")"
}
refuse_lan "an unreserved client" expose tcp 8080 192.168.64.51
refuse_lan "the console's port" expose tcp 443 192.168.64.50
refuse_lan "DHCP's port" expose udp 68 192.168.64.50
refuse_lan "the gateway itself" expose tcp 8080 192.168.64.1
refuse_lan "an address off the LAN" expose tcp 8080 10.0.0.9
refuse_lan "sctp" expose sctp 8080 192.168.64.50

lan expose tcp 8080 192.168.64.50 80 >/dev/null
lan expose udp 8554 192.168.64.50 >/dev/null
check "expose: kept in UCI" '[["tcp","8080","192.168.64.50","80"],["udp","8554","192.168.64.50","8554"]]' \
    "$(jq -c '[.pulzr | to_entries[] | select(.value[".type"] == "lan_expose") | .value | [.proto, .port, .ip, .dport]] | sort' "${UCI_JSON}")"
check "expose: loaded into the map" 'add element inet pulzr_lan expose_to { tcp . 8080 : 192.168.64.50 . 80, udp . 8554 : 192.168.64.50 . 8554 }' \
    "$(lastload | grep '^add element inet pulzr_lan expose_to')"
check "expose: journalled" 'expose' "$(tail -n1 "${T}/lan/forwards.log" | jq -r .op)"
refuse_lan "moving a reservation an exposed port points at" reserve c2:6c:1d:d1:f7:b3 192.168.64.60
refuse_lan "releasing it" unreserve c2:6c:1d:d1:f7:b3
lan unexpose udp 8554 >/dev/null
check "unexpose: gone from UCI and the map" 'add element inet pulzr_lan expose_to { tcp . 8080 : 192.168.64.50 . 80 }' \
    "$(lastload | grep '^add element inet pulzr_lan expose_to')"
check "status: exposed and where" '[{"proto":"tcp","port":8080,"ip":"192.168.64.50","dport":80}] 3' \
    "$(lan status | jq -c '.exposed' | tr -d '\n') $(lan status | jq '.exposedOn | length')"

lan policy c2:6c:1d:d1:f7:b3 internet >/dev/null
lan cellular c2:6c:1d:d1:f7:b3 allow tcp:554 udp:5000-5010 >/dev/null
check "cellular: blocked ports loaded" 'add element inet pulzr_lan cell_block { c2:6c:1d:d1:f7:b3 . tcp . 554, c2:6c:1d:d1:f7:b3 . udp . 5000-5010 }' \
    "$(lastload | grep '^add element inet pulzr_lan cell_block')"
lan cellular c2:6c:1d:d1:f7:b3 block >/dev/null
check "cellular: blocked outright" 'add element inet pulzr_lan cell_deny { c2:6c:1d:d1:f7:b3 }' \
    "$(lastload | grep '^add element inet pulzr_lan cell_deny')"
check "cellular: no per-port blocks under an outright one" '' "$(lastload | grep '^add element inet pulzr_lan cell_block' || true)"
lan policy c2:6c:1d:d1:f7:b3 parkeze >/dev/null
check "policy back to parkeze keeps the cellular rule" '"block"' \
    "$(jq -c '.pulzr.lan_c26c1dd1f7b3.cellular' "${UCI_JSON}")"
check "status: the client's cellular rule" '"block" "parkeze"' \
    "$(lan status | jq -c '.clients[0].cellular' | tr -d '\n') $(lan status | jq -c '.clients[0].policy')"
lan cellular c2:6c:1d:d1:f7:b3 allow >/dev/null
lan policy c2:6c:1d:d1:f7:b3 internet >/dev/null
check "cellular: back to the default drops the section" 'null' "$(jq -c '.pulzr.lan_c26c1dd1f7b3' "${UCI_JSON}")"
refuse_lan "a block that is not tcp or udp" cellular c2:6c:1d:d1:f7:b3 allow icmp:1
refuse_lan "a backwards range" cellular c2:6c:1d:d1:f7:b3 allow udp:10-5

# ── lan: links and clients on the wire with no lease ────────────────────────
#
# The Campo camera: a static address on another subnet, so no lease and no
# ARP entry, only the bridge's own table on lan1. lan2 has no cable.
mkdir -p "${T}/sys/br-devlan/brif/lan1" "${T}/sys/br-devlan/brif/lan2" "${T}/sys/lan1" "${T}/sys/lan2"
echo 0x1 > "${T}/sys/br-devlan/brif/lan1/port_no"
echo 0x2 > "${T}/sys/br-devlan/brif/lan2/port_no"
printf '1\n' > "${T}/sys/lan1/carrier"; printf '100\n' > "${T}/sys/lan1/speed"
printf 'full\n' > "${T}/sys/lan1/duplex"; printf '5\n' > "${T}/sys/lan1/carrier_changes"
printf '0\n' > "${T}/sys/lan2/carrier"; printf '1\n' > "${T}/sys/lan2/carrier_changes"
# __fdb_entry: MAC, port_no, is_local, ageing timer, port_hi, padding. The
# camera on lan1, the reserved client on lan2, and the bridge's own address,
# which is local and is not a client.
{ printf '\360\000\006\020\221\153\001\000\000\000\000\000\000\000\000\000'
  printf '\302\154\035\321\367\263\002\000\000\000\000\000\000\000\000\000'
  printf '\224\203\304\352\256\321\001\001\000\000\000\000\000\000\000\000'
} > "${T}/sys/br-devlan/brforward"
check "status: each port's link" \
    '[{"name":"lan1","up":true,"speed":100,"duplex":"full","carrierChanges":5},{"name":"lan2","up":false,"speed":null,"duplex":null,"carrierChanges":1}]' \
    "$(lan status | jq -c .links)"
check "status: on the wire with no lease, by its port" '[{"mac":"c2:6c:1d:d1:f7:b3","port":"lan2"},{"mac":"f0:00:06:10:91:6b","port":"lan1"}]' \
    "$(lan status | jq -c '[.clients[] | {mac, port}] | sort_by(.mac)')"
check "status: a wire-only client has no address and no DHCP contact" 'null null false' \
    "$(lan status | jq -r '.clients[] | select(.mac == "f0:00:06:10:91:6b") | "\(.ip) \(.firstSeen) \(.online)"')"

# ── lan: the port scan ──────────────────────────────────────────────────────
#
# Only the clients the bridge sees now, only the console's ports, polite and
# bound to the bridge; not at all without a default route or on cellular; and
# a push only when what answers changed.

printf '#!/bin/sh\necho "$*" >> "%s/pushes"\n' "${T}" > "${T}/agent"
chmod +x "${T}/agent"
jq '.pulzr.adoption = {".type": "adoption", ".name": "adoption", "state": "adopted"}' "${UCI_JSON}" > "${T}/u" && mv "${T}/u" "${UCI_JSON}"
cat > "${T}/arp" <<'ARP'
IP address       HW type     Flags       HW address            Mask     Device
192.168.64.50    0x1         0x2         c2:6c:1d:d1:f7:b3     *        br-devlan
192.168.64.77    0x1         0x2         02:80:e1:9c:0f:3f     *        br-devlan
192.168.64.78    0x1         0x0         02:80:e1:9c:0f:40     *        br-devlan
10.0.0.1         0x1         0x2         d4:6a:91:5f:cf:00     *        wan
ARP
printf '22\n80\n' > "${T}/nmap.192.168.64.50"
: > "${T}/nmap.log"

check "scan: nothing without a default route" '{"skipped":true} 0' "$(lan scan | jq -c .) $(wc -l < "${T}/nmap.log" | tr -d ' ')"
jq '.wwan.route = [{"target": "0.0.0.0", "mask": 0, "metric": 10}]' "${NET_JSON}" > "${T}/n" && mv "${T}/n" "${NET_JSON}"
check "scan: nothing while cellular routes" '{"skipped":true} 0' "$(lan scan | jq -c .) $(wc -l < "${T}/nmap.log" | tr -d ' ')"
jq '.wan.route = [{"target": "0.0.0.0", "mask": 0, "metric": 1}]' "${NET_JSON}" > "${T}/n" && mv "${T}/n" "${NET_JSON}"
lan scan >/dev/null
check "scan: the console's ports, polite, bound to the bridge" \
    '-n -Pn -sT -T2 --max-retries 1 --host-timeout 60s -e br-devlan -p 22,23,80,443,8080,8443 -oG -' \
    "$(tail -n1 "${T}/nmap.log" | sed 's/ 192\..*//')"
check "scan: only the clients the bridge sees now" '192.168.64.50 192.168.64.77' \
    "$(tail -n1 "${T}/nmap.log" | tr ' ' '\n' | grep '^192' | sort | paste -sd' ' -)"
check "scan: each client's open ports in the status, [] for one with none" '[22,80] []' \
    "$(lan status | jq -c '[.clients[] | select(.mac == "c2:6c:1d:d1:f7:b3")][0].services') $(lan status | jq -c '[.clients[] | select(.mac == "02:80:e1:9c:0f:3f")][0].services')"
check "scan: an incomplete ARP entry is not scanned, and has no ports" 'null' \
    "$(lan status | jq -c '[.clients[] | select(.mac == "02:80:e1:9c:0f:40")][0].services')"
check "scan: when, in the status" 'number' "$(lan status | jq -r '.scannedAt | type')"
check "scan: the change is pushed" '--push lan' "$(cat "${T}/pushes")"
lan scan >/dev/null
check "scan: the same answer is not pushed again" '1' "$(wc -l < "${T}/pushes" | tr -d ' ')"
printf '22\n23\n' > "${T}/nmap.192.168.64.77"
lan scan >/dev/null
check "scan: telnet appearing is pushed" '2 [22,23]' \
    "$(wc -l < "${T}/pushes" | tr -d ' ') $(lan status | jq -c '[.clients[] | select(.mac == "02:80:e1:9c:0f:3f")][0].services')"

# ── lan: another subnet on the bridge ───────────────────────────────────────
#
# A camera with a static 10.20.0.112: the gateway takes 10.20.0.2/24 on
# br-devlan, and the camera can then be reserved, forwarded to and exposed.
refuse_lan "a subnet overlapping the LAN" address add 192.168.64.200/24
refuse_lan "a subnet overlapping an uplink" address add 10.0.0.2/24
refuse_lan "a subnet overlapping the console's" address add 192.168.61.5/24
refuse_lan "a /32" address add 10.20.0.2/32
refuse_lan "a network address" address add 10.20.0.0/24
refuse_lan "a forward off every subnet" forward 10.20.0.112 80 600
: > "${T}/events"
lan address add 10.20.0.2/24 >/dev/null
check "address: devlan_extra on the bridge" '["br-devlan","static",["10.20.0.2/24"]]' \
    "$(jq -c '.network.devlan_extra | [.device, .proto, .ipaddr]' "${UCI_JSON}")"
check "address: netifd reloaded" '1' "$(grep -cx reload "${T}/events")"
check "address: adding it again changes nothing" '{"addresses":["10.20.0.2/24"]}' "$(lan address add 10.20.0.2/24 | jq -c .)"
refuse_lan "a second subnet overlapping the first" address add 10.20.0.9/16
check "status: the other subnets" '["10.20.0.2/24"]' "$(lan status | jq -c .addresses)"
refuse_lan "the gateway's own address there" reserve 02:00:00:00:00:01 10.20.0.2
check "a forward to a client there" '10.20.0.112' "$(lan forward 10.20.0.112 80 600 | jq -r .ip)"
lan reserve f0:00:06:10:91:6b 10.20.0.112 cam >/dev/null
lan expose tcp 8554 10.20.0.112 554 >/dev/null
check "expose: a client there" '10.20.0.112' "$(jq -r '.pulzr.expose_tcp_8554.ip' "${UCI_JSON}")"
refuse_lan "removing a subnet an exposed port points into" address remove 10.20.0.2/24
lan unexpose tcp 8554 >/dev/null
lan address remove 10.20.0.2/24 >/dev/null
check "address: the last one removed takes the interface" 'null' "$(jq -c '.network.devlan_extra' "${UCI_JSON}")"
refuse_lan "removing one that is not there" address remove 10.20.0.2/24

# ── lan: the internet by default, and each client's metered totals ─────────
#
# docs/src/content/docs/lan.md, Metering. The kernel's counters come from
# $T/nft.set.*; a boot is $T/nft.absent and a new $T/boot_id.

A=02:00:00:00:00:0a B=02:00:00:00:00:0b
jq '.firewall = {
  "devlan_pulzr_wan": {".type": "rule", ".name": "devlan_pulzr_wan", "dest": "wan", "target": "ACCEPT"},
  "devlan_ntp_wan": {".type": "rule", ".name": "devlan_ntp_wan", "dest": "wan", "target": "ACCEPT"},
  "devlan_pulzr_cellular": {".type": "rule", ".name": "devlan_pulzr_cellular", "dest": "cellular", "target": "ACCEPT"},
  "devlan_ntp_cellular": {".type": "rule", ".name": "devlan_ntp_cellular", "dest": "cellular", "target": "ACCEPT"},
  "lan_inet_02000000000b_wan": {".type": "rule", ".name": "lan_inet_02000000000b_wan", "dest": "wan", "src_mac": "02:00:00:00:00:0b", "target": "ACCEPT"},
  "devlan_inet_wan": {".type": "rule", ".name": "devlan_inet_wan", "dest": "wan", "target": "ACCEPT"},
  "devlan_inet_cellular": {".type": "rule", ".name": "devlan_inet_cellular", "dest": "cellular", "target": "ACCEPT"}}
  | .pulzr = {}' "${UCI_JSON}" > "${UCI_JSON}.new" && mv "${UCI_JSON}.new" "${UCI_JSON}"
printf '%s %s 192.168.64.70 cam-a *\n%s %s 192.168.64.71 plc-b *\n' \
    "$(( $(date +%s) + 3600 ))" "${A}" "$(( $(date +%s) + 3600 ))" "${B}" > "${T}/leases"
: > "${T}/arp"
rm -f "${T}"/nft.set.*
traffic() { lan status | jq -c --arg m "$1" '[.clients[] | select(.mac == $m)][0].traffic'; }
counted() {
    local set="$1"; shift
    jq -nc --args '{nftables: [{set: {name: $ARGS.positional[0], elem: [$ARGS.positional[1:] | _nwise(3) |
        {elem: {val: {concat: [.[0], .[1]]}, counter: {packets: 1, bytes: (.[2] | tonumber)}}}]}}]}' \
        "${set}" "$@" > "${T}/nft.set.${set}"
}

echo boot-one > "${T}/boot_id"; touch "${T}/nft.absent"
lan apply
lan seen "${A}" 192.168.64.70; lan seen "${B}" 192.168.64.71
epoch="$(lan status | jq -r .usageEpoch)"
check "usage: a new table starts an epoch" 'true' "$([ -n "${epoch}" ] && [ "${epoch}" != null ] && echo true)"
check "policy: the internet by default" '"internet"' "$(lan status | jq -c --arg m "${B}" '[.clients[] | select(.mac == $m)][0].policy')"
check "policy: the per-client internet accepts from before go" 'null' "$(jq -c '.firewall.lan_inet_02000000000b_wan' "${UCI_JSON}")"

counted usage_up 192.168.64.70 wwan0 100 192.168.64.70 phy0-sta0 50
counted usage_down 192.168.64.70 wwan0 1000
check "usage: per uplink, by its netifd name" '{"wwan":{"txBytes":100,"rxBytes":1000},"wwifi":{"txBytes":50,"rxBytes":0}}' "$(traffic "${A}")"

lan save-usage
check "usage: saved for the next boot" "\"${epoch}\" \"boot-one\" 1100" \
    "$(jq -c '.epoch, .boot, (.clients["'"${A}"'"].wwan | .txBytes + .rxBytes)' "${T}/lan/usage.json" | paste -sd' ' -)"

echo boot-two > "${T}/boot_id"; touch "${T}/nft.absent"; rm -f "${T}"/nft.set.*
lan apply
check "usage: a clean reboot keeps the epoch" "${epoch}" "$(lan status | jq -r .usageEpoch)"
check "usage: and starts from the saved totals" '{"wwan":{"txBytes":100,"rxBytes":1000},"wwifi":{"txBytes":50,"rxBytes":0}}' "$(traffic "${A}")"
check "usage: the saved copy is used once" 'gone' "$([ -e "${T}/lan/usage.json" ] || echo gone)"
counted usage_up 192.168.64.70 wwan0 10
check "usage: the kernel's counts add to them" '110' "$(traffic "${A}" | jq .wwan.txBytes)"

: > "${T}/nft.log"
printf '%s %s 192.168.64.72 cam-a *\n%s %s 192.168.64.71 plc-b *\n' \
    "$(( $(date +%s) + 3600 ))" "${A}" "$(( $(date +%s) + 3600 ))" "${B}" > "${T}/leases"
lan seen "${A}" 192.168.64.72
check "usage: a new address keeps what the old one counted" '110' "$(traffic "${A}" | jq .wwan.txBytes)"
check "usage: and the old address's counters are deleted" 'delete element inet pulzr_lan usage_up { 192.168.64.70 . "wwan0" }' \
    "$(grep '^delete element' "${T}/nft.log")"
lan seen "${B}" 192.168.64.70
check "usage: whoever takes the address starts from nothing" '{}' "$(traffic "${B}")"

echo boot-three > "${T}/boot_id"; touch "${T}/nft.absent"; rm -f "${T}"/nft.set.*
lan apply
check "usage: a power cut is a new epoch, from nothing" 'true {}' \
    "$([ "$(lan status | jq -r .usageEpoch)" != "${epoch}" ] && echo true) $(traffic "${A}")"

lan save-usage
lan apply
check "usage: a start without a reboot drops what the stop saved" 'gone' "$([ -e "${T}/lan/usage.json" ] || echo gone)"

lan policy "${B}" parkeze >/dev/null
check "policy: parkeze is a REJECT between Pulzar's accepts and the internet's" \
    'devlan_pulzr_wan devlan_ntp_wan devlan_pulzr_cellular devlan_ntp_cellular lan_pulzr_02000000000b_wan devlan_inet_wan lan_pulzr_02000000000b_cellular devlan_inet_cellular' \
    "$(jq -r '.firewall | keys_unsorted | join(" ")' "${UCI_JSON}")"
check "policy: parkeze, rejected" 'REJECT 02:00:00:00:00:0b' \
    "$(jq -r '.firewall.lan_pulzr_02000000000b_wan | "\(.target) \(.src_mac)"' "${UCI_JSON}")"
check "status: parkeze" '"parkeze"' "$(lan status | jq -c --arg m "${B}" '[.clients[] | select(.mac == $m)][0].policy')"
jq '.firewall = ({"lan_pulzr_02000000000b_wan": .firewall.lan_pulzr_02000000000b_wan} + .firewall)' "${UCI_JSON}" > "${UCI_JSON}.new" && mv "${UCI_JSON}.new" "${UCI_JSON}"
lan apply
check "policy: put back after an upgrade moved Pulzar's accepts below it" 'devlan_inet_wan' \
    "$(jq -r '.firewall | keys_unsorted | . as $k | $k[($k | index("lan_pulzr_02000000000b_wan")) + 1]' "${UCI_JSON}")"
lan policy "${B}" internet >/dev/null
check "policy: back to the internet drops the rules and the section" 'null null' \
    "$(jq -c '.firewall.lan_pulzr_02000000000b_wan, .pulzr.lan_02000000000b' "${UCI_JSON}" | paste -sd' ' -)"

exit "${fail}"
