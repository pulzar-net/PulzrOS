#!/usr/bin/env bash
#
# The cellular profile, against stubs: what decides a gateway is on its SIM,
# and what each part does about it.
#
#   scripts/test-lora-profile.sh
#
# What it must do:
#   - on_cellular: a SIM with the route and no free uplink is cellular; a cable
#     or a WiFi that reaches the internet is not; a WiFi behind a portal is.
#   - pulzr-lora-config: 30s in concentratord's file whatever the profile
#     (the LNS sets the interval); the direct forwarder's keepalive 30s, 60s
#     on cellular, 30s behind the buffer; CRC filters written out, and no
#     lorawan_only (it drops rejoin requests).
#   - pulzr-lora-profile: the setting overrides auto; the first settle after a
#     boot is at once, a later one only once the change has held, never two at
#     once; the facts ask for 300s on cellular; apply restarts only the
#     process whose file changed, and nothing when nothing did.
#   - pulzr-logship sends every 30 min on a SIM, every minute otherwise.
#   - pulzr-mqtt-agent pings every 240s on a SIM, every 60s otherwise.
#   - the buffer's bridge keepalive is 120s.
set -uo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LORA="${ROOT_DIR}/feed/pulzr-lorawan/files"
BASE="${ROOT_DIR}/feed/pulzr-base/files"
SANDBOX="$(mktemp -d)"
trap 'rm -rf "${SANDBOX}"' EXIT
STUBS="${SANDBOX}/bin"
mkdir -p "${STUBS}"
export SANDBOX

pass=0 fail=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1"; }
expect() {
    local name="$1" want="$2" got="$3"
    if [ "${got}" = "${want}" ]; then ok "${name}"; else bad "${name}: got [${got}], wanted [${want}]"; fi
}

# ── stubs ───────────────────────────────────────────────────────────────────

# uci: `get` from $SANDBOX/uci (key=value lines), `show network` from
# $SANDBOX/network.
cat > "${STUBS}/uci" <<'STUB'
#!/bin/sh
[ "$1" = "-q" ] && shift
case "$1" in
    get) v="$(sed -n "s|^$2=||p" "${SANDBOX}/uci" 2>/dev/null | head -n1)"
         [ -n "${v}" ] || exit 1; echo "${v}" ;;
    show) cat "${SANDBOX}/network" 2>/dev/null ;;
esac
STUB
cat > "${STUBS}/logger" <<'STUB'
#!/bin/sh
echo "$*" >> "${SANDBOX}/log"
STUB
# Each slot's processes, by the config they run: $SANDBOX/procs, "pid cmdline".
cat > "${STUBS}/pgrep" <<'STUB'
#!/bin/sh
[ "$1" = "-f" ] && shift
grep -E "$1" "${SANDBOX}/procs" 2>/dev/null | cut -d' ' -f1
STUB
cat > "${STUBS}/kill" <<'STUB'
#!/bin/sh
case "$1" in -0) exit 1 ;; esac
echo "$*" >> "${SANDBOX}/killed"
STUB
cat > "${STUBS}/sleep" <<'STUB'
#!/bin/sh
STUB
cat > "${STUBS}/jsonfilter" <<'STUB'
#!/usr/bin/env python3
import json, sys
args = sys.argv[1:]
expr = args[args.index('-e') + 1]
value = json.load(open(args[args.index('-i') + 1]))
try:
    for part in filter(None, expr[2:].split('.')):
        value = value[part]
except Exception:
    sys.exit(1)
print(('true' if value else 'false') if isinstance(value, bool) else value)
STUB
command -v md5sum >/dev/null 2>&1 || printf '#!/bin/sh\nmd5 -q | sed "s/$/  -/"\n' > "${STUBS}/md5sum"
chmod +x "${STUBS}"/*
export PATH="${STUBS}:${PATH}"

# ── on_cellular, with the real helpers and a fake netifd ───────────────────
#
# network.sh answers from $SANDBOX/routes: "<iface> <gateway> <device>" for
# each interface with a default route.
SHARE="${SANDBOX}/share"
mkdir -p "${SHARE}"
cat > "${SANDBOX}/network.sh" <<'STUB'
network_flush_cache() { :; }
network_get_gateway() { eval "$1=\"\$(awk -v i=\"$2\" '\$1 == i { print \$2 }' \"${SANDBOX}/routes\")\""; [ -n "$(eval echo \"\$$1\")" ]; }
network_get_device()  { eval "$1=\"\$(awk -v i=\"$2\" '\$1 == i { print \$3 }' \"${SANDBOX}/routes\")\""; [ -n "$(eval echo \"\$$1\")" ]; }
network_is_up()       { awk -v i="$1" '$1 == i { f = 1 } END { exit !f }' "${SANDBOX}/routes"; }
STUB
# The WiFi check: "open" for the interfaces in $SANDBOX/wifi-open.
cat > "${SANDBOX}/pulzr-wifi-uplink" <<'STUB'
#!/bin/sh
[ "$1" = usable ] && grep -qx "$2" "${SANDBOX}/wifi-open" 2>/dev/null
STUB
chmod +x "${SANDBOX}/pulzr-wifi-uplink"
for f in cellular.sh wired.sh wifi.sh; do
    sed -e "s#/lib/functions/network.sh#${SANDBOX}/network.sh#" \
        -e "s#/usr/sbin/pulzr-wifi-uplink#${SANDBOX}/pulzr-wifi-uplink#" \
        -e "s#/usr/sbin/pulzr-uplinks#${SANDBOX}/no-such-uplinks#" \
        "${BASE}/usr/share/pulzr/${f}" > "${SHARE}/${f}"
done
printf 'network.wan=interface\nnetwork.wwifi=interface\n' > "${SANDBOX}/network"
echo "network.wwifi=interface" > "${SANDBOX}/uci"

cellular() {
    PULZR_SHARE="${SHARE}" sh -c '. "${PULZR_SHARE}/cellular.sh"; on_cellular' && echo yes || echo no
}
routes() { printf '%s\n' "$@" > "${SANDBOX}/routes"; }

routes "wan 192.0.2.1 eth0" "wwan 10.0.0.1 wwan0"
expect "a cable beside the SIM is not cellular" no "$(cellular)"
routes "wwan 10.0.0.1 wwan0"
expect "the SIM alone is cellular" yes "$(cellular)"
routes "usbwan 192.168.8.1 usb0"
expect "a tethered phone alone is cellular" yes "$(cellular)"
routes
expect "no route at all is not cellular" no "$(cellular)"
routes "wwifi 10.36.0.1 phy0-sta0" "wwan 10.0.0.1 wwan0"
echo wwifi > "${SANDBOX}/wifi-open"
expect "a WiFi that reaches the internet is not cellular" no "$(cellular)"
: > "${SANDBOX}/wifi-open"
expect "a WiFi behind a portal leaves the SIM carrying it" yes "$(cellular)"

# ── pulzr-lora-config ───────────────────────────────────────────────────────

RUN="${SANDBOX}/run"
mkdir -p "${RUN}/lora" "${SHARE}/concentrator" "${SHARE}/region"
cp "${LORA}/usr/share/pulzr/concentrator/"*.json "${SHARE}/concentrator/"
cp -R "${LORA}/usr/share/pulzr/region/US915" "${SHARE}/region/"
cat > "${SANDBOX}/board.conf" <<'EOF'
BOARD_ID='test'
PULZR_MQTT_HOST='mqtt.example.net'
EOF
cat > "${SANDBOX}/uci" <<'EOF'
pulzr.slot0.active=sx1302_spi
pulzr.slot0.bus=spi
pulzr.slot0.device=/dev/spidev0.0
pulzr.identity.gateway_eui=0102030405060708
pulzr.mqtt.username=u
pulzr.mqtt.password=p
pulzr.concentrator.slots=1
EOF
# The profile the config asks for: whatever $SANDBOX/want says.
cat > "${STUBS}/want" <<'STUB'
#!/bin/sh
cat "${SANDBOX}/want"
STUB
chmod +x "${STUBS}/want"
export PULZR_BOARD_CONF="${SANDBOX}/board.conf" PULZR_SHARE="${SHARE}" PULZR_RUN="${RUN}" \
       PULZR_KILL="${STUBS}/kill" PULZR_LORA_PROFILE_CMD="${STUBS}/want" PULZR_LORA_CONFIG="${LORA}/usr/sbin/pulzr-lora-config"

render() { # profile -> renders slot 0 into $SANDBOX/out
    echo "$1" > "${SANDBOX}/want"
    rm -rf "${SANDBOX}/out"
    sh "${LORA}/usr/sbin/pulzr-lora-config" 0 "${SANDBOX}/out" || bad "render $1 failed"
}
setting() { sed -n "s/^$1=\"*\([^\"]*\)\"*$/\1/p" "${SANDBOX}/out/$2" | head -n1; }

render standard
expect "the file's stats interval is 30s: the LNS sets the real one" 30s "$(setting stats_interval concentratord.toml)"
expect "standard: the direct keepalive stays 30s" 30s "$(setting keep_alive_interval mqtt-forwarder.toml)"
render cellular
expect "cellular: the file still says 30s" 30s "$(setting stats_interval concentratord.toml)"
expect "cellular: the direct keepalive is 60s" 60s "$(setting keep_alive_interval mqtt-forwarder.toml)"
render nonsense
expect "an unknown answer is the standard keepalive" 30s "$(setting keep_alive_interval mqtt-forwarder.toml)"
expect "CRC-failed frames are not forwarded" false "$(setting forward_crc_invalid mqtt-forwarder.toml)"
expect "frames with no CRC are not forwarded" false "$(setting forward_crc_missing mqtt-forwarder.toml)"
expect "no lorawan_only: it drops rejoin requests" "" "$(grep '^lorawan_only' "${SANDBOX}/out/mqtt-forwarder.toml")"

# Behind the buffer the forwarder talks to loopback.
echo "pulzr.lorawan.buffer=1" >> "${SANDBOX}/uci"
echo "listener 18831 127.0.0.1" > "${RUN}/lora/mosquitto.conf"
render cellular
expect "behind the buffer the keepalive is 30s on any profile" 30s "$(setting keep_alive_interval mqtt-forwarder.toml)"
expect "behind the buffer the forwarder talks to loopback" "tcp://127.0.0.1:18831" "$(setting server mqtt-forwarder.toml)"
rm -f "${RUN}/lora/mosquitto.conf"
sed -i.bak '/pulzr.lorawan.buffer/d' "${SANDBOX}/uci"

# ── pulzr-lora-profile ──────────────────────────────────────────────────────
#
# Its own `want` reads the stubbed on_cellular through a cellular.sh that
# answers from $SANDBOX/cellular. The config it re-renders with asks the same
# script for `current`.
PROFILE="${LORA}/usr/sbin/pulzr-lora-profile"
PSHARE="${SANDBOX}/pshare"
mkdir -p "${PSHARE}"
printf 'on_cellular() { [ "$(cat "${SANDBOX}/cellular" 2>/dev/null)" = yes ]; }\n' > "${PSHARE}/cellular.sh"
ln -s "${SHARE}/concentrator" "${SHARE}/region" "${PSHARE}/"
profile() { PULZR_SHARE="${PSHARE}" sh "${PROFILE}" "$@"; }
printf '#!/bin/sh\nPULZR_SHARE="%s" exec sh "%s" "$@"\n' "${PSHARE}" "${PROFILE}" > "${STUBS}/want"
chmod +x "${STUBS}/want"
settle() { PULZR_LORA_PROFILE_HOLD=3 PULZR_LORA_PROFILE_STEP=1 PULZR_SHARE="${PSHARE}" sh "${PROFILE}" settle; }

echo yes > "${SANDBOX}/cellular"
expect "auto on a SIM wants cellular" cellular "$(profile want)"
echo no > "${SANDBOX}/cellular"
expect "auto on a free link wants standard" standard "$(profile want)"
echo "pulzr.lorawan.profile=cellular" >> "${SANDBOX}/uci"
expect "the setting overrides auto" cellular "$(profile want)"
sed -i.bak '/pulzr.lorawan.profile/d' "${SANDBOX}/uci"
expect "before any is settled, current is what is wanted" standard "$(profile current)"
expect "and the facts ask for 30s" 30 "$(profile reported)"

# A running slot 0, rendered standard, with its two processes.
SLOT="${RUN}/lora/slot0"
render standard
mkdir -p "${SLOT}"; cp "${SANDBOX}/out/"* "${SLOT}/"
printf '4000001 /usr/bin/chirpstack-concentratord-sx1302 -c %s/concentratord.toml -c %s/region.toml\n4000002 /usr/bin/chirpstack-mqtt-forwarder -c %s/mqtt-forwarder.toml\n' \
    "${SLOT}" "${SLOT}" "${SLOT}" > "${SANDBOX}/procs"
: > "${SANDBOX}/killed"

# The first settle after a boot is at once.
echo yes > "${SANDBOX}/cellular"
settle
expect "the first settle takes the wanted profile at once" cellular "$(cat "${RUN}/lora/profile")"
expect "and the facts ask the LNS for 300s" 300 "$(profile reported)"
expect "status is JSON" '{"want":"cellular","current":"cellular","statsInterval":300}' "$(profile status)"
expect "only the direct forwarder restarts, for its keepalive; concentratord is left alone" \
    "-TERM 4000002" "$(tr '\n' ' ' < "${SANDBOX}/killed" | sed 's/ $//')"
expect "and its keepalive is now 60s" 60s "$(sed -n 's/^keep_alive_interval="\([^"]*\)"$/\1/p' "${SLOT}/mqtt-forwarder.toml")"

: > "${SANDBOX}/killed"
profile apply
expect "apply with nothing changed restarts nothing" "" "$(cat "${SANDBOX}/killed")"
settle
expect "settle with want and current agreeing does nothing" "" "$(cat "${SANDBOX}/killed")"

echo no > "${SANDBOX}/cellular"
expect "a change of uplink is wanted, not yet current" "standard cellular 300" \
    "$(profile want) $(profile current) $(profile reported)"
settle
expect "settle takes it once it has held" "standard 30" "$(profile current) $(profile reported)"
expect "settle leaves no lock behind" no "$([ -d "${RUN}/lora/settle.lock" ] && echo yes || echo no)"
echo yes > "${SANDBOX}/cellular"
mkdir "${RUN}/lora/settle.lock"
settle
expect "a second settle while one waits does nothing" standard "$(profile current)"
rmdir "${RUN}/lora/settle.lock"

# ── the other connections ───────────────────────────────────────────────────

SHIP="${ROOT_DIR}/feed/pulzr-adopt/files/usr/sbin/pulzr-logship"
echo yes > "${SANDBOX}/cellular"
expect "the log goes every 30 minutes on a SIM" 1800 "$(PULZR_SHARE="${PSHARE}" sh "${SHIP}" interval)"
echo no > "${SANDBOX}/cellular"
expect "and every minute otherwise" 60 "$(PULZR_SHARE="${PSHARE}" sh "${SHIP}" interval)"
expect "and every minute without the helper" 60 "$(PULZR_SHARE="${SANDBOX}/none" sh "${SHIP}" interval)"

AGENT="${ROOT_DIR}/feed/pulzr-mqtt/files/usr/sbin/pulzr-mqtt-agent"
echo yes > "${SANDBOX}/cellular"
expect "the agent pings every 240s on a SIM" 240 "$(PULZR_SHARE="${PSHARE}" sh "${AGENT}" --keepalive)"
echo no > "${SANDBOX}/cellular"
expect "and every 60s otherwise" 60 "$(PULZR_SHARE="${PSHARE}" sh "${AGENT}" --keepalive)"

expect "the bridge pings every 120s" "keepalive_interval 120" \
    "$(grep '^keepalive_interval' "${LORA}/usr/sbin/pulzr-lora-buffer")"
expect "the facts carry the interval asked for" 1 \
    "$(grep -cF 'pulzr-lora-profile reported 2>/dev/null' "${BASE}/usr/sbin/pulzr-gateway-facts")"
expect "the NTP hook re-renders through the profile" 1 \
    "$(grep -c '^exec /usr/sbin/pulzr-lora-profile apply$' "${LORA}/etc/hotplug.d/ntp/40-pulzr-lora-time")"
expect "an uplink change starts a settle" 1 \
    "$(grep -c 'pulzr-lora-profile settle' "${LORA}/etc/hotplug.d/iface/45-pulzr-lora-route")"

echo "${pass} passed, ${fail} failed"
exit "${fail}"
