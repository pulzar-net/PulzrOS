#!/usr/bin/env bash
#
# parkeze-uplinks, parkeze-dns and parkeze-ports against a JSON-backed uci, a fake netifd
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
sed -e "s#/var/run/parkeze/uplinks.json#${T}/uplinks.json#" \
    -e 's#while (true) sleep(round() \* 1000);#for (let k = 0; k < int(getenv("ROUNDS")); k++) round();#' \
    "${ROOT}/feed/parkeze-uplinks/files/usr/sbin/parkeze-uplinks" > "${T}/uplinks.uc"
sed -e "s#/etc/parkeze/board.conf#${T}/board.conf#" \
    -e "s#/tmp/resolv.conf.d/resolv.conf.auto#${T}/resolv#" \
    -e 's/, [0-9]*000)/)/' \
    "${ROOT}/feed/parkeze-dns/files/usr/sbin/parkeze-dns" > "${T}/dns.uc"
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
 "parkeze": {"uplinks": {".type": "uplinks", ".name": "uplinks", "track": ["wan"],
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
check "order: saved as named" '["wwan","wan"]' "$(jq -c .parkeze.uplinks.order "${UCI_JSON}")"
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

: > "${T}/ping_ok"
ROUNDS=3 up run
check "offline again" 'offline' "$(state wan)"
up track wan off >/dev/null
check "tracking off: state dropped, metric back" 'none ["10","20","30"]' "$(state wan) $(metrics)"
check "tracking off: none rather than the default" '"none"' "$(jq -c .parkeze.uplinks.track "${UCI_JSON}")"
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

printf 'PARKEZE_NET_URL="https://net.parkeze.com"\nPARKEZE_MQTT_HOST="mqtt.parkeze.com"\n' > "${T}/board.conf"
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
check "upstream: a server that cannot resolve Parkeze is refused" \
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
    check "hosts: ${bad} is Parkeze's" "2 names under parkeze.com are Parkeze's" "${r} ${out}"
done
out="$(dns host plc-1 1.2.3.4 2>&1)" && r=0 || r=$?
check "hosts: a reservation's name is refused" "3 plc-1 is a reservation's name" "${r} ${out}"
dns host -bad 1.2.3.4 >/dev/null 2>&1 && r=0 || r=$?
check "hosts: a label may not start with a hyphen" '2' "${r}"
dns host evilparkeze.com 1.2.3.4 >/dev/null && r=0 || r=$?
check "hosts: a lookalike is not Parkeze's" '0' "${r}"
dns unhost nas >/dev/null
dns unhost nas >/dev/null 2>&1 && r=0 || r=$?
check "unhost: gone, and a second time refused" '3 ["evilparkeze.com","nas-2.site","nas.2.site"]' \
    "${r} $(dns status | jq -c '[.hosts[].name]')"

dns rebind on corp.local site.internal >/dev/null
check "rebind: on, with allowed domains" '{"protection":true,"allowed":["corp.local","site.internal"]}' \
    "$(dns status | jq -c .rebind)"
dns rebind off >/dev/null
check "rebind: off, allowed cleared" '{"protection":false,"allowed":[]}' "$(dns status | jq -c .rebind)"

# ── ports ───────────────────────────────────────────────────────────────────
#
# The layout written into network, firewall, dhcp and the uplink order. The
# undo window's timer and snapshot are the gateway's (start-stop-daemon,
# /etc/config); here only what a layout renders to, what is refused, and that
# a confirm too soon is refused.

sed -e "s#/etc/parkeze/board.conf#${T}/board.conf#" \
    -e "s#'/etc/parkeze/ports'#'${T}/ports'#" \
    -e "s#'/etc/config/'#'${T}/config/'#" \
    "${ROOT}/feed/parkeze-base/files/usr/sbin/parkeze-ports" > "${T}/ports.uc"
grep -q "${T}/ports'" "${T}/ports.uc" || { echo "FAIL parkeze-ports' state path moved; update this script" >&2; exit 1; }
mkdir -p "${T}/ports" "${T}/config"
ports() { "${UCODE}" -R -L "${ROOT}/scripts/router-fixture/*.uc" -L "${MODULES}" "${T}/ports.uc" "$@"; }

printf 'PARKEZE_PORT_IFACE="wan"\nPARKEZE_LAN_PORTS="lan1 lan2"\nPARKEZE_DEVLAN_IPADDR="192.168.64.1"\n' > "${T}/board.conf"
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
 "parkeze": {"uplinks": {".type": "uplinks", ".name": "uplinks", "track": ["wan"], "order": ["wan", "wwan"]}}}
EOF

ports seed
check "seed: the board's shape, keeping wan's static address" \
    '[["wan","uplink","static"],["lan1","devices","dhcp"],["lan2","devices","dhcp"]]' \
    "$(ports status | jq -c '[.ports[] | [.name, .role, .addressing.mode]]')"
ports seed
check "seed: a kept layout is left alone" '3' "$(jq '[.parkeze[] | select(.[".type"] == "port")] | length' "${UCI_JSON}")"

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
check "set: new uplinks tracked, wan gone" '["wan_lan1","wan_lan2","wan_lan2_20"]' "$(jq -c .parkeze.uplinks.track "${UCI_JSON}")"
check "set: new uplinks ordered ahead of cellular" '["wan_lan1","wan_lan2","wan_lan2_20","wwan"]' \
    "$(jq -c .parkeze.uplinks.order "${UCI_JSON}")"
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
check "back: uplinks that went are out of the order" '["wan","wwan"]' "$(jq -c .parkeze.uplinks.order "${UCI_JSON}")"

exit "${fail}"
