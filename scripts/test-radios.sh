#!/usr/bin/env bash
#
# The radios page's backend (lib/radios.uc) against a JSON-backed uci, a fake
# netifd and iwinfo, and `iw phy info` from three real kinds of radio: a
# dual-band MediaTek that takes a station and many APs, a Raspberry Pi 3's
# brcmfmac that takes one of each on one channel, and a radio that is a
# station or an AP and never both.
#
#   UCODE=/path/to/ucode scripts/test-radios.sh
#
# The ucode needs its fs module beside it, as CI's build has. The console's
# lib/*.uc run as shipped except for their absolute paths, which point into a
# scratch directory.
#
# What this guards: a repeater the hardware cannot run written anyway and left
# for hostapd to fail on, a channel and width the regulatory domain does not
# allow, an open AP onto the LAN by accident, an AP made on the radios page
# deleted by the next WiFi join, and a rejoin putting the uplink back on the
# radio the AP is on. And the uplink moved to another radio by letting go of
# the network on the old one first: a second station joins beside it, is
# proven, and only then takes the traffic (handover), or is removed again.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UCODE="${UCODE:-ucode}"
command -v "${UCODE}" >/dev/null 2>&1 || { echo "ucode not found; set UCODE=/path/to/ucode" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "jq not found" >&2; exit 2; }
MODULES="$(dirname "$(command -v "${UCODE}")")/*.so"
FIX="${ROOT}/scripts/radios-fixture"

T="$(mktemp -d)"
trap 'rm -rf "${T}"' EXIT
export T UCI_JSON="${T}/uci.json"
# The radios fixture first; the WiFi one has the uci and logger access.uc
# calls from a shell.
export PATH="${FIX}/bin:${ROOT}/scripts/wifi-fixture/bin:${PATH}"
mkdir -p "${T}/run" "${T}/iwinfo" "${T}/assoc" "${T}/phy" "${T}/sys/class/ieee80211" "${T}/sys/devices" "${T}/bin"
# pulzr-wifi-uplink's answers and pulzr-uplinks' order, from files; what they
# were told to do, into the events.
cat > "${T}/bin/pulzr-wifi-uplink" <<'STUB'
#!/bin/sh
case "$1" in
    status) cat "${T}/verdict-$2.json" 2>/dev/null || echo '{"state":"unchecked"}' ;;
    *) echo "pulzr-wifi-uplink $*" >> "${T}/events" ;;
esac
STUB
cat > "${T}/bin/pulzr-uplinks" <<'STUB'
#!/bin/sh
case "$1" in
    status) cat "${T}/uplinks.json" 2>/dev/null || echo '{"order":[]}' ;;
    *) echo "pulzr-uplinks $*" >> "${T}/events" ;;
esac
STUB
chmod +x "${T}/bin/pulzr-wifi-uplink" "${T}/bin/pulzr-uplinks"
echo pulzr-1234ab > "${T}/hostname"

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

LIB="${T}/lib"
mkdir -p "${LIB}"
for f in "${ROOT}"/feed/pulzr-console/files/usr/share/pulzr/console/lib/*.uc; do
    sed -e "s#/usr/share/pulzr/console/lib/#${LIB}/#g" \
        -e "s#/var/run/pulzr/#${T}/run/#g" \
        -e "s#/var/run/#${T}/run/#g" \
        -e "s#/tmp/pulzr-signin#${T}/signin#g" \
        -e "s#/tmp/pulzr-wifi-probe#${T}/probe#g" \
        -e "s#'/sys/class/#'${T}/sys/class/#g" \
        -e "s#/proc/sys/kernel/hostname#${T}/hostname#g" \
        -e "s#/usr/sbin/pulzr-wifi-uplink#${T}/bin/pulzr-wifi-uplink#g" \
        -e "s#/usr/sbin/pulzr-uplinks#${T}/bin/pulzr-uplinks#g" \
        -e "s#/usr/share/pulzr/console/wifi-handover.uc#${T}/no-handover.uc#g" \
        "${f}" > "${LIB}/$(basename "${f}")"
done
# One call per run: `fn` with `req`, the answer as JSON.
cat > "${T}/drive.uc" <<EOF
let radios = loadfile('${LIB}/radios.uc', { raw_mode: true })();
let access = loadfile('${LIB}/access.uc', { raw_mode: true })();
let call = json(ARGV[0]);
let fns = { status: radios.status, setRadio: radios.setRadio, setAp: radios.setAp,
            removeAp: radios.removeAp, joinUplink: radios.joinUplink, joinWifi: access.joinWifi,
            handover: radios.handover, removeUplink: radios.removeUplink,
            parsePhy: radios.parsePhy, fits: radios.fits, channelOk: radios.channelOk,
            widthsOf: radios.widthsOf };
let out;
if (call.fn == 'parsePhy') out = radios.parsePhy(call.req);
else if (call.fn == 'fits') out = radios.fits(radios.parsePhy(call.phy), call.req);
else if (call.fn == 'channelOk') {
    let caps = radios.parsePhy(call.phy);
    out = map(call.req, (r) => radios.channelOk(r[0], caps.bands[r[0]], r[1], r[2]));
}
else out = fns[call.fn](call.req);
print(sprintf('%J\n', out));
EOF
run() { "${UCODE}" -R -L "${ROOT}/scripts/router-fixture/*.uc" -L "${MODULES}" "${T}/drive.uc" "$1"; }
phytext() { jq -Rs . < "${FIX}/phy/$1.txt"; }
call() { run "{\"fn\":\"$1\",\"req\":$2}"; }
err() { call "$1" "$2" | jq -r '.error // "none"'; }
uci() { jq -c "$1" "${UCI_JSON}"; }

# A phy as sysfs has it: /sys/class/ieee80211/<phy>/device is the device the
# UCI wifi-device's `path` names.
phy() {
    local name="$1" path="$2" text="$3"
    mkdir -p "${T}/sys/devices/${path}" "${T}/sys/class/ieee80211/${name}"
    ln -sfn "${T}/sys/devices/${path}" "${T}/sys/class/ieee80211/${name}/device"
    cp "${FIX}/phy/${text}.txt" "${T}/phy/${name}.txt"
}
reset_phys() { rm -rf "${T}/sys/class/ieee80211"/* "${T}/phy"/* "${T}/iwinfo"/* "${T}/assoc"/*; : > "${T}/events"; }

# ── iw phy info ─────────────────────────────────────────────────────────────

out="$(run "{\"fn\":\"parsePhy\",\"req\":$(phytext mt7981-5g)}")"
check "parse: the interface modes" '["IBSS","managed","AP","AP/VLAN","monitor","mesh point"]' "$(jq -c .modes <<< "${out}")"
check "parse: 5 GHz, open channels and the closed ones" "27 2" \
    "$(jq -r '[(.bands["5g"].channels | length), ([.bands["5g"].channels[] | select(.disabled)] | length)] | join(" ")' <<< "${out}")"
check "parse: radar, no IR and the power cap of channel 52" '{"channel":52,"mhz":5260,"maxDbm":24,"disabled":false,"noIr":true,"dfs":true}' \
    "$(jq -c '.bands["5g"].channels[] | select(.channel == 52)' <<< "${out}")"
check "parse: VHT 160 and HE 160" "true true true" "$(jq -r '.bands["5g"] | [.vht, .vht160, .he160] | join(" ")' <<< "${out}")"
check "parse: a combination continued onto a second line" \
    '[{"limits":[{"types":["IBSS"],"max":1},{"types":["managed","AP","mesh point"],"max":16}],"total":16,"channels":1}]' \
    "$(jq -c .combinations <<< "${out}")"
out="$(run "{\"fn\":\"parsePhy\",\"req\":$(phytext brcmfmac)}")"
check "parse: an older iw's whole-MHz frequencies" "2412 2467 true" \
    "$(jq -r '.bands["2g"].channels | [.[0].mhz, .[3].mhz, .[3].noIr] | join(" ")' <<< "${out}")"
check "parse: two combinations" "2 2" "$(jq -r '[(.combinations | length), .combinations[1].total] | join(" ")' <<< "${out}")"
check "parse: HT20 only is no HT40" "false" "$(jq -r '.bands["2g"].ht40' <<< "${out}")"

# ── what fits ───────────────────────────────────────────────────────────────

fits() { run "{\"fn\":\"fits\",\"phy\":$(phytext "$1"),\"req\":$2}" | jq -c '[.ok, .channels]'; }
check "fits: Pi 3, a station and an AP, one channel" '[true,1]' "$(fits brcmfmac '{"managed":1,"AP":1}')"
check "fits: Pi 3, two APs" '[false,null]' "$(fits brcmfmac '{"AP":2}')"
check "fits: Pi 3, a station and two APs" '[false,null]' "$(fits brcmfmac '{"managed":1,"AP":2}')"
check "fits: MediaTek, a station and four APs" '[true,1]' "$(fits mt7981-2g '{"managed":1,"AP":4}')"
check "fits: no combinations, one interface" '[true,1]' "$(fits single '{"AP":1}')"
check "fits: no combinations, a station and an AP" '[false,null]' "$(fits single '{"managed":1,"AP":1}')"
check "fits: a mode the radio lacks" '[false,null]' "$(fits single '{"mesh point":1}')"

ok="$(run "{\"fn\":\"channelOk\",\"phy\":$(phytext mt7981-5g),\"req\":[[\"5g\",36,80],[\"5g\",48,80],[\"5g\",149,80],[\"5g\",165,40],[\"5g\",100,160],[\"5g\",132,160],[\"5g\",169,20]]}")"
check "channels: 80 at 36 and 48, 80 at 149, no 40 at 165, 160 at 100 not 132, 169 closed" \
    '[true,true,true,false,true,false,false]' "$(jq -c . <<< "${ok}")"
ok="$(run "{\"fn\":\"channelOk\",\"phy\":$(phytext mt7981-2g),\"req\":[[\"2g\",1,40],[\"2g\",11,40],[\"2g\",13,20]]}")"
check "channels: 2.4 GHz at 40 takes four above or below; 13 is closed in the US" '[true,true,false]' "$(jq -c . <<< "${ok}")"

# ── a two-radio repeater ────────────────────────────────────────────────────
#
# The router's case: radio0 (2.4 GHz) the uplink, a client of the site's
# WiFi; radio1 (5 GHz) an access point onto the LAN with two clients.

reset_phys
phy phy0 platform/soc/18000000.wifi mt7981-2g
phy phy1 platform/soc/18000000.wifi+1 mt7981-5g
repeater_uci() {
    cat > "${UCI_JSON}" <<'EOF'
{"wireless": {
   "radio0": {".type": "wifi-device", ".name": "radio0", "type": "mac80211", "path": "platform/soc/18000000.wifi", "band": "2g", "channel": "1", "htmode": "HE20", "country": "US"},
   "radio1": {".type": "wifi-device", ".name": "radio1", "type": "mac80211", "path": "platform/soc/18000000.wifi+1", "band": "5g", "channel": "36", "htmode": "HE80", "country": "US"},
   "parkeze_sta": {".type": "wifi-iface", ".name": "parkeze_sta", "device": "radio0", "mode": "sta", "network": "wwifi", "ssid": "Site-Ops", "encryption": "psk2", "key": "upstream-pass"},
   "pulzr_ap_0": {".type": "wifi-iface", ".name": "pulzr_ap_0", "device": "radio1", "mode": "ap", "network": "devlan", "ssid": "Shop", "encryption": "sae-mixed", "key": "shop-secret"}},
 "network": {"devlan": {".type": "interface", ".name": "devlan", "proto": "static", "ipaddr": "192.168.64.1"},
             "wwifi": {".type": "interface", ".name": "wwifi", "proto": "dhcp"},
             "wan": {".type": "interface", ".name": "wan", "proto": "dhcp"}},
 "firewall": {"wan": {".type": "zone", ".name": "wan", "network": "wan wwifi"}},
 "pulzr": {"s": {".type": "wifi_network", ".name": "s", "ssid": "Site-Ops", "security": "psk", "key": "upstream-pass"}}}
EOF
}
repeater_uci
cat > "${T}/wireless.json" <<'EOF'
{"radio0": {"up": true, "interfaces": [{"section": "parkeze_sta", "ifname": "phy0-sta0"}]},
 "radio1": {"up": true, "interfaces": [{"section": "pulzr_ap_0", "ifname": "phy1-ap0"}]}}
EOF
echo '{"phy":"phy0","ssid":"Site-Ops","bssid":"aa:bb:cc:00:00:01","country":"US","mode":"Client","channel":6,"frequency":2437,"txpower":20,"signal":-61,"htmodes":["HT20","HT40","HE20","HE40"],"hwmodes":["b","g","n","ax"],"hardware":{"name":"MediaTek MT7981"}}' > "${T}/iwinfo/phy0-sta0.json"
echo '{"phy":"phy1","ssid":"Shop","country":"US","mode":"Master","channel":36,"frequency":5180,"txpower":23,"htmodes":["VHT80","HE80","HE160"],"hwmodes":["a","n","ac","ax"],"hardware":{"name":"MediaTek MT7981"}}' > "${T}/iwinfo/phy1-ap0.json"
echo '{"results":[{"mac":"00:11:22:33:44:55","signal":-48,"inactive":120,"rx":{"rate":866700},"tx":{"rate":780000}},{"mac":"00:11:22:33:44:66","signal":-70,"inactive":3000}]}' > "${T}/assoc/phy1-ap0.json"
echo '{"interface":[{"interface":"wan","up":false},{"interface":"wwifi","up":true,"route":[{"target":"0.0.0.0","mask":0,"metric":15}]},{"interface":"wwan","up":true,"route":[{"target":"0.0.0.0","mask":0,"metric":20}]}]}' > "${T}/dump.json"

st="$(call status '{}')"
check "status: both radios, on the phys their paths name" '[["radio0","phy0","2g",true],["radio1","phy1","5g",true]]' \
    "$(jq -c '[.radios[] | [.id, .phy, .band, .present]]' <<< "${st}")"
check "status: the uplink, its network and signal" '{"role":"uplink","owner":"uplink","ssid":"Site-Ops","signal":-61,"channel":6}' \
    "$(jq -c '.radios[0].interfaces[0] | {role, owner, ssid, signal, channel}' <<< "${st}")"
check "status: the AP, its network and its two clients" '{"role":"ap","owner":"console","ssid":"Shop","security":"sae-mixed","net":"LAN","clients":2}' \
    "$(jq -c '.radios[1].interfaces[0] | {role, owner, ssid, security, net: .networks[0].label, clients: (.clients | length)}' <<< "${st}")"
check "status: the key is never in it" "no" "$(grep -q 'shop-secret\|upstream-pass' <<< "${st}" && echo yes || echo no)"
check "status: the route is the WiFi" '{"via":"wifi","iface":"wwifi"}' "$(jq -c .route <<< "${st}")"
check "status: widths each radio does" '[[20,40],[20,40,80,160]]' "$(jq -c '[.radios[].capabilities.widths]' <<< "${st}")"
check "status: 2.4 GHz channels open here, power cap" "11 23" "$(jq -r '.radios[0] | [(.capabilities.channels | length), .txpower.max] | join(" ")' <<< "${st}")"
check "status: two radios, no shared channel; room for more on both" '[false,true,true]' \
    "$(jq -c '[.radios[0].sharedChannel, .radios[0].capabilities.room.ap, .radios[1].capabilities.room.uplink]' <<< "${st}")"
check "status: the LAN is where an AP can go" '[{"id":"devlan","label":"LAN","address":"192.168.64.1"}]' "$(jq -c .networks <<< "${st}")"
check "status: hardware, country, the uplink's radio, the hostname" "MediaTek MT7981 US radio0 pulzr-1234ab" \
    "$(jq -r '[.radios[0].hardware, .country, .uplink, .hostname] | join(" ")' <<< "${st}")"

# ── changing a radio ────────────────────────────────────────────────────────

check "radio: 80 MHz at 165 refused" "Channel 165 cannot carry 80 MHz here." \
    "$(err setRadio '{"radio":"radio1","channel":165,"width":80}')"
check "radio: a closed channel refused" "Channel 169 is not open on this radio here." \
    "$(err setRadio '{"radio":"radio1","channel":169}')"
check "radio: 160 MHz on 2.4 GHz refused" "This radio does not do 160 MHz on this band." \
    "$(err setRadio '{"radio":"radio0","width":160}')"
check "radio: more power than the channel allows refused" "Power is 1 to 23 dBm on this radio." \
    "$(err setRadio '{"radio":"radio0","txpower":30}')"
check "radio: an unknown radio refused" "No such radio." "$(err setRadio '{"radio":"radio9"}')"
check "radio: a country that is not a code refused" "A country is its two-letter code." \
    "$(err setRadio '{"radio":"radio0","country":"Germany"}')"
check "radio: nothing written by a refusal" '"36"' "$(uci .wireless.radio1.channel)"
call setRadio '{"radio":"radio1","channel":52,"width":160,"txpower":20,"country":"DE"}' >/dev/null
check "radio: channel, the radio's own width family, power" '["52","HE160","20"]' \
    "$(uci '.wireless.radio1 | [.channel, .htmode, .txpower]')"
check "radio: the country on every radio" '["DE","DE"]' "$(uci '[.wireless.radio0.country, .wireless.radio1.country]')"
call setRadio '{"radio":"radio1","channel":"auto","txpower":"max","enabled":false}' >/dev/null
check "radio: auto, full power, off" '["auto",null,"1"]' "$(uci '.wireless.radio1 | [.channel, .txpower, .disabled]')"
sleep 3
check "radio: the radios reload after the answer" "wifi reload" "$(sort -u "${T}/events")"

# ── access points ───────────────────────────────────────────────────────────

repeater_uci
check "ap: a short passphrase refused" "A passphrase is 8 to 63 characters." \
    "$(err setAp '{"radio":"radio0","ssid":"Yard","security":"psk2","key":"short","network":"devlan"}')"
check "ap: open onto the LAN refused unless confirmed" \
    "An open access point puts the LAN in reach of anybody nearby. Confirm it explicitly." \
    "$(err setAp '{"radio":"radio0","ssid":"Yard","security":"none","network":"devlan"}')"
check "ap: onto an uplink refused" "Choose a network for the access point." \
    "$(err setAp '{"radio":"radio0","ssid":"Yard","security":"psk2","key":"yard-secret","network":"wan"}')"
check "ap: the setup AP is not this page's" "That access point is not one made here." \
    "$(err setAp '{"id":"parkeze_ap","ssid":"x"}')"
check "ap: WPA3 refused without SAE" "This gateway has no WPA3 support." \
    "$(HOSTAPD_SAE=1 err setAp '{"radio":"radio0","ssid":"Yard","security":"sae","key":"yard-secret","network":"devlan"}')"
out="$(call setAp '{"radio":"radio0","ssid":"Yard","security":"sae","key":"yard-secret","network":"devlan","hidden":true}')"
check "ap: added beside the uplink, as the next pulzr_ap" "pulzr_ap_1" "$(jq -r .id <<< "${out}")"
check "ap: its section" '{"device":"radio0","mode":"ap","network":"devlan","ssid":"Yard","encryption":"sae","key":"yard-secret","hidden":"1","disabled":"0"}' \
    "$(uci '.wireless.pulzr_ap_1 | {device, mode, network, ssid, encryption, key, hidden, disabled}')"
call setAp '{"id":"pulzr_ap_1","ssid":"Yard 2","security":"psk2","key":""}' >/dev/null
check "ap: an edit with the passphrase blank keeps it" '["Yard 2","psk2","yard-secret","1"]' \
    "$(uci '.wireless.pulzr_ap_1 | [.ssid, .encryption, .key, .hidden]')"
check "ap: removing the uplink's station is not this" "That access point is not one made here." \
    "$(err removeAp '{"id":"parkeze_sta"}')"
call removeAp '{"id":"pulzr_ap_1"}' >/dev/null
check "ap: removed" "null" "$(uci .wireless.pulzr_ap_1)"

# ── joins keep the access points ────────────────────────────────────────────

repeater_uci
jq '.wireless.default_radio0 = {".type": "wifi-iface", ".name": "default_radio0", "device": "radio0", "mode": "ap", "ssid": "OpenWrt", "encryption": "none", "network": "lan"}' \
    "${UCI_JSON}" > "${T}/u" && mv "${T}/u" "${UCI_JSON}"
call joinWifi '{"ssid":"Site-Ops","saved":true}' >/dev/null
check "join: OpenWrt's stock AP goes, this page's stays" '[null,"Shop"]' \
    "$(uci '[.wireless.default_radio0, .wireless.pulzr_ap_0.ssid]')"

# ── the uplink onto the other radio, without a gap ──────────────────────────

wwifi_before="$(uci .network.wwifi)"
call joinUplink '{"radio":"radio1","ssid":"Site-Ops","saved":true}' >/dev/null
check "move: a second station on the other radio, the first left as it is" \
    '["radio0","Site-Ops","radio1","Site-Ops","wwifi2","Shop"]' \
    "$(uci '.wireless | [.parkeze_sta.device, .parkeze_sta.ssid, .pulzr_sta2.device, .pulzr_sta2.ssid, .pulzr_sta2.network, .pulzr_ap_0.ssid]')"
check "move: its own interface, behind every uplink, in the wan zone" '["dhcp","200","wan wwifi wwifi2"]' \
    "$(uci '[.network.wwifi2.proto, .network.wwifi2.metric, .firewall.wan.network]')"
check "move: the first one's interface untouched" "${wwifi_before}" "$(uci .network.wwifi)"
check "move: a handover from the WiFi carrying now" '["wwifi2","radio1","Site-Ops","wwifi","radio0","joining"]' \
    "$(jq -c '[.iface, .radio, .ssid, .from, .fromRadio, .state]' "${T}/run/wifi-handover.json")"
call joinWifi '{"ssid":"Site-Ops","saved":true}' >/dev/null
check "join: a rejoin from the WiFi page leaves both stations where they are" '["radio0","radio1"]' \
    "$(uci '[.wireless.parkeze_sta.device, .wireless.pulzr_sta2.device]')"
st="$(call status '{}')"
check "status: both WiFi uplinks, the WiFi page's first" '[["parkeze_sta","wwifi","radio0"],["pulzr_sta2","wwifi2","radio1"]]' \
    "$(jq -c '[.uplinks[] | [.id, .iface, .radio]]' <<< "${st}")"
check "status: the second station is this page's, an uplink" '["uplink","radios"]' \
    "$(jq -c '[.radios[1].interfaces[] | select(.id == "pulzr_sta2") | .role, .owner]' <<< "${st}")"
check "status: the handover" "joining" "$(jq -r .handover.state <<< "${st}")"

# Proven: up, and open on this network. It goes where the old one was in the
# order, the old one right behind it, a cable ahead of both left ahead.
now="$(date +%s)"
echo '{"up":true}' > "${T}/wwifi2.json"
echo "{\"state\":\"open\",\"ssid\":\"Site-Ops\",\"checkedAt\":${now}}" > "${T}/verdict-wwifi2.json"
echo '{"order":["wan","wwifi","wwan"]}' > "${T}/uplinks.json"
: > "${T}/events"
out="$(call handover '"wwifi2"')"
check "handover: done once it is open" "done" "$(jq -r .state <<< "${out}")"
check "handover: first among the WiFi uplinks, behind the cable" "pulzr-uplinks order wan wwifi2 wwifi wwan" "$(cat "${T}/events")"
check "handover: both stations stay" '["radio0","radio1"]' "$(uci '[.wireless.parkeze_sta.device, .wireless.pulzr_sta2.device]')"

# Not proven in time: the new station goes, the old one was never touched.
handover_again() {
    jq -c ".state = \"joining\" | .startedAt = $(( now - 300 ))" "${T}/run/wifi-handover.json" > "${T}/h" \
        && mv "${T}/h" "${T}/run/wifi-handover.json"
    : > "${T}/events"
}
handover_again
echo "{\"state\":\"offline\",\"step\":\"dns\",\"detail\":\"10.0.0.1\",\"ssid\":\"Site-Ops\",\"checkedAt\":${now}}" > "${T}/verdict-wwifi2.json"
out="$(call handover '"wwifi2"')"
check "handover: given up, with why" '["failed","DNS 10.0.0.1 did not answer."]' "$(jq -c '[.state, .reason]' <<< "${out}")"
check "handover: the new station removed, the old one as it was" '[null,null,"wan wwifi","radio0","Site-Ops"]' \
    "$(uci '[.wireless.pulzr_sta2, .network.wwifi2, .firewall.wan.network, .wireless.parkeze_sta.device, .wireless.parkeze_sta.ssid]')"
check "handover: the order not touched" "" "$(grep 'pulzr-uplinks order' "${T}/events" || true)"

call joinUplink '{"radio":"radio1","ssid":"Site-Ops","saved":true}' >/dev/null
handover_again
echo '{"up":false}' > "${T}/wwifi2.json"
cp "${T}/wireless.json" "${T}/wireless.bak"
jq '.radio1.interfaces += [{"section": "pulzr_sta2", "ifname": "phy1-sta0"}]' "${T}/wireless.bak" > "${T}/wireless.json"
printf '%s\n' \
    'Mon Nov 23 10:00:01 2026 daemon.notice wpa_supplicant[900]: phy1-sta0: CTRL-EVENT-SSID-TEMP-DISABLED id=0 ssid="Site-Ops" auth_failures=1 duration=10 reason=WRONG_KEY' \
    'Mon Nov 23 10:00:02 2026 daemon.notice wpa_supplicant[901]: phy0-sta0: CTRL-EVENT-CONNECTED' > "${T}/logread"
out="$(call handover '"wwifi2"')"
check "handover: never associated, wpa_supplicant's reason for that station" '["failed","wrong_passphrase"]' \
    "$(jq -c '[.state, .failure.code]' <<< "${out}")"
rm -f "${T}/logread"
mv "${T}/wireless.bak" "${T}/wireless.json"

call joinUplink '{"radio":"radio1","ssid":"Site-Ops","saved":true}' >/dev/null
jq 'del(.wireless.pulzr_sta2)' "${UCI_JSON}" > "${T}/u" && mv "${T}/u" "${UCI_JSON}"
check "handover: the station undone under it, nothing to do" "null" "$(call handover '"wwifi2"')"
check "handover: and no record left" "no" "$([ -f "${T}/run/wifi-handover.json" ] && echo yes || echo no)"

# ── removing the second uplink ──────────────────────────────────────────────

call joinUplink '{"radio":"radio1","ssid":"Site-Ops","saved":true}' >/dev/null
echo '{"order":["wwifi2","wwifi","wwan"]}' > "${T}/uplinks.json"
: > "${T}/events"
check "remove: the WiFi page's station is forgotten there" "Forget this network on the WiFi page." \
    "$(err removeUplink '{"radio":"radio0"}')"
call removeUplink '{"radio":"radio1"}' >/dev/null
check "remove: last in the order before it goes" "pulzr-uplinks order wwifi wwan wwifi2" "$(head -n1 "${T}/events")"
check "remove: the station, its interface and its zone membership" '[null,null,"wan wwifi","radio0"]' \
    "$(uci '[.wireless.pulzr_sta2, .network.wwifi2, .firewall.wan.network, .wireless.parkeze_sta.device]')"
check "remove: nothing on a radio with no uplink" "No uplink on this radio." "$(err removeUplink '{"radio":"radio1"}')"

# ── the one-step repeater ───────────────────────────────────────────────────

cat > "${UCI_JSON}" <<'EOF'
{"wireless": {
   "radio0": {".type": "wifi-device", ".name": "radio0", "path": "platform/soc/18000000.wifi", "band": "2g", "disabled": "1"},
   "radio1": {".type": "wifi-device", ".name": "radio1", "path": "platform/soc/18000000.wifi+1", "band": "5g", "disabled": "1"}},
 "network": {"devlan": {".type": "interface", ".name": "devlan", "proto": "static", "ipaddr": "192.168.64.1"}},
 "firewall": {"wan": {".type": "zone", ".name": "wan", "network": "wan"}},
 "pulzr": {}}
EOF
echo '{}' > "${T}/wireless.json"
before="$(cat "${UCI_JSON}")"
check "repeater: the AP checked before anything is written" "A passphrase is 8 to 63 characters." \
    "$(err joinUplink '{"radio":"radio0","ssid":"Cafe","key":"cafe-pass","ap":{"radio":"radio1","ssid":"Cafe Ext","security":"psk2","key":"x","network":"devlan"}}')"
check "repeater: the join checked before anything is written" "A WPA passphrase is 8 to 63 characters." \
    "$(err joinUplink '{"radio":"radio0","ssid":"Cafe","key":"short","ap":{"radio":"radio1","ssid":"Cafe Ext","security":"psk2","key":"ext-secret","network":"devlan"}}')"
check "repeater: a refusal changed nothing" "same" "$([ "$(cat "${UCI_JSON}")" = "${before}" ] && echo same || echo changed)"
out="$(call joinUplink '{"radio":"radio0","ssid":"Cafe","key":"cafe-pass","ap":{"radio":"radio1","ssid":"Cafe Ext","security":"psk2","key":"ext-secret","network":"devlan"}}')"
check "repeater: joined, with its AP" "pulzr_ap_0" "$(jq -r .ap <<< "${out}")"
check "repeater: uplink on radio0, AP on radio1, both radios on" '["radio0","Cafe","radio1","Cafe Ext","0","0"]' \
    "$(uci '.wireless | [.parkeze_sta.device, .parkeze_sta.ssid, .pulzr_ap_0.device, .pulzr_ap_0.ssid, .radio0.disabled, .radio1.disabled]')"
check "repeater: the upstream network saved, as any join" '"Cafe"' "$(uci '[.pulzr[] | select(.[".type"] == "wifi_network")][0].ssid')"

# ── one radio ───────────────────────────────────────────────────────────────
#
# A Pi 3 takes a station and one AP on one channel: a repeater on one radio,
# with the AP on the upstream network's channel. A radio that does one
# interface at a time takes neither.

reset_phys
phy phy0 platform/soc/3f300000.mmcnr/mmc_host/mmc1/mmc1:0001/mmc1:0001:1 brcmfmac
cat > "${UCI_JSON}" <<'EOF'
{"wireless": {
   "radio0": {".type": "wifi-device", ".name": "radio0", "path": "platform/soc/3f300000.mmcnr/mmc_host/mmc1/mmc1:0001/mmc1:0001:1", "band": "2g", "channel": "6", "htmode": "HT20"}},
 "network": {"devlan": {".type": "interface", ".name": "devlan", "proto": "static", "ipaddr": "192.168.64.1"}},
 "firewall": {"wan": {".type": "zone", ".name": "wan", "network": "wan"}},
 "pulzr": {}}
EOF
echo '{"radio0": {"up": false, "interfaces": []}}' > "${T}/wireless.json"
out="$(call joinUplink '{"radio":"radio0","ssid":"Cafe","key":"cafe-pass","ap":{"radio":"radio0","ssid":"Cafe Ext","security":"psk2","key":"ext-secret","network":"devlan"}}')"
check "one radio: a station and an AP on a Pi 3" "pulzr_ap_0" "$(jq -r '.ap // .error' <<< "${out}")"
st="$(call status '{}')"
check "one radio: the AP follows the uplink's channel" "true" "$(jq -r '.radios[0].sharedChannel' <<< "${st}")"
check "one radio: no room for a second AP" "false" "$(jq -r '.radios[0].capabilities.room.ap' <<< "${st}")"
check "one radio: a second AP refused" "This radio cannot run that many interfaces at once." \
    "$(err setAp '{"radio":"radio0","ssid":"Two","security":"psk2","key":"two-secret","network":"devlan"}')"
check "one radio: 40 MHz is not on offer" "[20]" "$(jq -c '.radios[0].capabilities.widths' <<< "${st}")"

reset_phys
phy phy0 platform/ahb/18100000.wmac single
jq '.wireless.radio0.path = "platform/ahb/18100000.wmac" | del(.wireless.parkeze_sta) | del(.wireless.pulzr_ap_0)' \
    "${UCI_JSON}" > "${T}/u" && mv "${T}/u" "${UCI_JSON}"
before="$(cat "${UCI_JSON}")"
check "station or AP: both on one radio refused, with what to do" \
    "This radio cannot be the uplink and an access point at once. Use two radios." \
    "$(err joinUplink '{"radio":"radio0","ssid":"Cafe","key":"cafe-pass","ap":{"radio":"radio0","ssid":"Cafe Ext","security":"psk2","key":"ext-secret","network":"devlan"}}')"
check "station or AP: nothing written" "same" "$([ "$(cat "${UCI_JSON}")" = "${before}" ] && echo same || echo changed)"

# ── no WiFi ─────────────────────────────────────────────────────────────────

reset_phys
echo '{"network": {}, "wireless": {}}' > "${UCI_JSON}"
echo '{}' > "${T}/wireless.json"
check "no radios: an empty list" "[]" "$(call status '{}' | jq -c .radios)"
check "no LAN: nowhere to put an AP" "[]" "$(call status '{}' | jq -c .networks)"

# ── what the routes and the other writers do ────────────────────────────────

API="${ROOT}/feed/pulzr-console/files/usr/share/pulzr/console/api/index.uc"
unguarded="$(grep -A1 "'POST /api/radios" "${API}" | grep -c 'apply.guard' || true)"
check "routes: every radios setter is inside the rollback window" \
    "$(grep -c "'POST /api/radios" "${API}")" "${unguarded}"
check "routes: the radios belong to the wifi feature" "1" "$(grep -c "\['/api/radios', *'wifi'\]" "${API}")"
for f in feed/pulzr-ap/files/etc/uci-defaults/60-pulzr-ap feed/pulzr-ap/files/usr/sbin/pulzr-ap; do
    check "$(basename "${f}"): keeps this page's access points" "1" \
        "$(grep -c 'parkeze_\*|pulzr_\*) ;;' "${ROOT}/${f}")"
done

exit "${fail}"
