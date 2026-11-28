#!/usr/bin/env bash
#
# Drive the reset button, the setup AP and the question "does any uplink work"
# against a sandbox.
#
#   scripts/test-setup-mode.sh
#
# All of it is shell that otherwise only runs on a gateway, behind a physical
# button, and the mistakes are expensive: a gesture that factory resets, a hold
# that does not, a radio raised on a site that did not need one, or an AP that
# never comes up for the person who moved the gateway. So the real scripts run
# here, with their absolute paths pointed into a sandbox and everything they
# call replaced by a stub that writes down what it was asked.
#
# Under dash where there is one, which is what busybox ash descends from. bash
# differs where it matters here: `set -e` inside a command substitution, which
# is how an empty SSID got past a test run under bash.
#
# What this cannot say is that the kernel sends these events, that procd runs
# the link, or that a radio does what uci says. Those need a gateway.

set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FEED="${ROOT_DIR}/feed"

command -v python3 >/dev/null 2>&1 || { echo "python3 is required (for the stubs)" >&2; exit 2; }

SANDBOX="$(mktemp -d)"
trap 'touch "${SANDBOX}/go"; rm -rf "${SANDBOX}"' EXIT
BIN="${SANDBOX}/bin"
LOG="${SANDBOX}/calls"
mkdir -p "${BIN}" "${SANDBOX}/etc/pulzr" "${SANDBOX}/run" "${SANDBOX}/lib"

failures=0
check() {
    local what="$1" want="$2" got="$3"
    if [ "${got}" = "${want}" ]; then
        echo "ok   ${what}"
    else
        echo "FAIL ${what}: want '${want}', got '${got}'"
        failures=$((failures + 1))
    fi
}
called() { grep -c -- "^$1" "${LOG}" 2>/dev/null || true; }

SHELL_FOR_DEVICE="$(command -v dash || echo /bin/sh)"

# The script as a gateway has it, with its paths moved into the sandbox.
install_script() {
    sed -e "1s|^#!/bin/sh|#!${SHELL_FOR_DEVICE}|" \
        -e "s#/usr/sbin/#${BIN}/#g" \
        -e "s#/usr/libexec/#${BIN}/#g" \
        -e "s#/etc/pulzr#${SANDBOX}/etc/pulzr#g" \
        -e "s#/var/run/pulzr#${SANDBOX}/run#g" \
        -e "s#/usr/share/pulzr/cellular.sh#${SANDBOX}/lib/cellular.sh#g" \
        -e "s#/usr/share/pulzr/wired.sh#${SANDBOX}/lib/wired.sh#g" \
        -e "s#/lib/functions/network.sh#${SANDBOX}/lib/network.sh#g" \
        "$1" > "${BIN}/$(basename "$1")"
    chmod +x "${BIN}/$(basename "$1")"
}

# A stub that records its arguments and exits with what ${NAME}_RC says.
stub() {
    local var; var="$(echo "$1" | tr 'a-z-' 'A-Z_')_RC"
    cat > "${BIN}/$1" <<EOF
#!/bin/sh
echo "$1 \$*" >> "${LOG}"
exit \${${var}:-0}
EOF
    chmod +x "${BIN}/$1"
}

for name in logger reboot factoryreset jffs2reset pulzr-adopt pulzr-backhaul-check wifi; do
    stub "${name}"
done

# pulzr-led is only ever asked. --has says there is a cloud LED, --held no.
cat > "${BIN}/pulzr-led" <<EOF
#!/bin/sh
echo "pulzr-led \$*" >> "${LOG}"
[ "\$1" = "--held" ] && exit 1
exit 0
EOF
chmod +x "${BIN}/pulzr-led"

# The settle wait is the one sleep that matters: it stands until the test says
# the button has been left alone. Every other sleep is instant.
cat > "${BIN}/sleep" <<EOF
#!/bin/sh
if [ "\$1" = "77" ]; then
    while [ ! -e "${SANDBOX}/go" ]; do /bin/sleep 0.02; done
fi
exit 0
EOF
chmod +x "${BIN}/sleep"

export PATH="${BIN}:${PATH}"

# ── the reset button ────────────────────────────────────────────────────────

install_script "${FEED}/pulzr-io/files/usr/libexec/pulzr-reset-button"

cat > "${SANDBOX}/board.conf" <<'EOF'
PULZR_BUTTON_RESET_HOLD="10"
EOF
echo "/dev/ubi0_1 /overlay ubifs rw 0 0" > "${SANDBOX}/mounts"
stub pulzr-ap

export PULZR_BOARD_CONF="${SANDBOX}/board.conf"
export PULZR_BUTTON_RUN="${SANDBOX}/run/button"
export PULZR_UPTIME="${SANDBOX}/uptime"
export PULZR_MOUNTS="${SANDBOX}/mounts"
export PULZR_BUTTON_SETTLE=77

clock=1000
at() { clock=$((clock + $1)); echo "${clock}.50 0" > "${PULZR_UPTIME}"; }

fresh() {
    rm -rf "${PULZR_BUTTON_RUN}" "${SANDBOX}/go"
    : > "${LOG}"
    at 100000
}
button() { ACTION="$1" SEEN="${2:-0}" BUTTON=reset "${BIN}/pulzr-reset-button"; }
tap() { at "${1:-1}"; button pressed; button released 0; }
# Press it, and let the settle run out.
leave_alone() {
    touch "${SANDBOX}/go"
    # Until the settle has finished whatever it decided, not for a guessed
    # time: the first run of a new stub can take longer than any guess.
    local i=0
    while pgrep -f "${BIN}/pulzr-reset-button" >/dev/null && [ "${i}" -lt 200 ]; do
        /bin/sleep 0.05; i=$((i + 1))
    done
}
held() { at 0; button pressed; button released "$1"; }

fresh; at 0; button pressed; check "pressing asks to hear back at the hold threshold" 10 "$?"

fresh; tap; tap; tap; tap; leave_alone
check "four presses ask for setup mode" 1 "$(called 'pulzr-ap button')"
check "four presses do not report status" 0 "$(called 'pulzr-backhaul-check')"
check "four presses do not reset" 0 "$(called 'factoryreset')"
check "four presses do not release the gateway" 0 "$(called 'pulzr-adopt')"
check "four presses do not reboot" 0 "$(called 'reboot')"
check "a raised AP is not signalled as a refusal" 0 "$(called 'pulzr-led status alert')"

fresh; tap; leave_alone
check "one press reports status" 1 "$(called 'pulzr-backhaul-check')"
check "one press is not setup mode" 0 "$(called 'pulzr-ap button')"
check "one press does not reboot, as stock did" 0 "$(called 'reboot')"

fresh; tap; tap; tap; leave_alone
check "three presses do nothing" 0 "$(called 'pulzr-ap')"
check "three presses report nothing" 0 "$(called 'pulzr-backhaul-check')"

fresh; tap; tap; tap; tap; tap; leave_alone
check "five presses are not four" 0 "$(called 'pulzr-ap')"

fresh; tap; tap; tap; tap 3; leave_alone
check "a pause starts a new sequence" 0 "$(called 'pulzr-ap')"
check "and the press after it is a press of its own" 1 "$(called 'pulzr-backhaul-check')"

fresh; tap; tap; at 0; button pressed; button released 2; tap; tap; leave_alone
check "a two-second press breaks the sequence" 0 "$(called 'pulzr-ap')"

fresh; held 12
check "a hold past the threshold releases the gateway" 1 "$(called 'pulzr-adopt --release')"
check "and resets it" 1 "$(called 'factoryreset -y')"
check "and reboots" 1 "$(called 'reboot')"

fresh; tap; tap; tap; tap; held 12; leave_alone
check "four presses then a hold is a hold" 1 "$(called 'factoryreset -y')"
check "with no setup mode behind it" 0 "$(called 'pulzr-ap')"

fresh; tap; tap; tap; tap; held 5; leave_alone
check "four presses then the dead zone is nothing" 0 "$(called 'pulzr-ap')"
check "and no reset" 0 "$(called 'factoryreset')"

fresh; held 9
check "a press just short of the threshold resets nothing" 0 "$(called 'factoryreset')"
check "and releases nothing" 0 "$(called 'pulzr-adopt')"

fresh; tap; tap; tap; tap; at 0; button pressed; leave_alone
check "the sequence is not read while the button is down" 0 "$(called 'pulzr-ap')"
rm -f "${SANDBOX}/go"
button released 12
check "and what it turned out to be is read on release" 1 "$(called 'factoryreset -y')"

export PULZR_AP_RC=2
fresh; tap; tap; tap; tap; leave_alone
check "a refusal lights the alert" 1 "$(called 'pulzr-led status alert')"
check "on every light" 1 "$(called 'pulzr-led cloud alert')"
check "held from the daemon, then let go" 1 "$(called 'pulzr-led --hold 0')"
unset PULZR_AP_RC

echo "tmpfs /tmp tmpfs rw 0 0" > "${SANDBOX}/mounts"
fresh; held 12
check "no overlay: the gateway is not released for a reset that cannot happen" 0 "$(called 'pulzr-adopt')"
check "no overlay: nothing is reset" 0 "$(called 'factoryreset')"
echo "/dev/ubi0_1 /overlay ubifs rw 0 0" > "${SANDBOX}/mounts"

mv "${BIN}/factoryreset" "${BIN}/factoryreset.off"
fresh; held 12
check "24.10 has only jffs2reset" 1 "$(called 'jffs2reset -y')"
mv "${BIN}/factoryreset.off" "${BIN}/factoryreset"

# ── what makes the button reach that script at all ──────────────────────────

mkdir -p "${SANDBOX}/rc.button"
stub uci
sed -e "s#/etc/pulzr/board.conf#${SANDBOX}/rc.conf#" \
    -e "s#/etc/rc.button/#${SANDBOX}/rc.button/#" \
    "${FEED}/pulzr-io/files/etc/uci-defaults/50-pulzr-io" > "${SANDBOX}/50-pulzr-io"
echo 'PULZR_BUTTON_RESET="reset"' > "${SANDBOX}/rc.conf"
echo stock > "${SANDBOX}/rc.button/reset"
sh "${SANDBOX}/50-pulzr-io"
check "/etc/rc.button/reset is the handler, not stock" /usr/libexec/pulzr-reset-button \
    "$(readlink "${SANDBOX}/rc.button/reset")"
rm -f "${SANDBOX}/rc.button/reset"
echo 'PULZR_BUTTON_RESET=""' > "${SANDBOX}/rc.conf"
sh "${SANDBOX}/50-pulzr-io"
check "a board with no button gets no link" "" "$(ls "${SANDBOX}/rc.button")"

# ── the setup AP ────────────────────────────────────────────────────────────

rm -f "${BIN}/pulzr-ap" "${BIN}/uci"
install_script "${FEED}/pulzr-ap/files/usr/sbin/pulzr-ap"
touch "${SANDBOX}/etc/pulzr/board.conf"

# uci over a key=value file, with what pulzr-ap uses of it.
UCI_DB="${SANDBOX}/uci.db"; export UCI_DB
cat > "${BIN}/uci" <<'EOF'
#!/usr/bin/env python3
import os, re, sys
path = os.environ['UCI_DB']
def load():
    db = {}
    for line in open(path):
        k, _, v = line.rstrip('\n').partition('=')
        db[k] = v
    return db
def save(db):
    with open(path, 'w') as f:
        for k, v in db.items():
            f.write(f'{k}={v}\n')
def run(db, args):
    cmd = args[0]
    if cmd == 'get':
        if args[1] not in db: return 1
        print(db[args[1]])
    elif cmd == 'set':
        k, _, v = args[1].partition('=')
        db[k] = v.strip("'")
    elif cmd == 'delete':
        k = args[1]
        gone = [x for x in db if x == k or x.startswith(k + '.')]
        for x in gone: del db[x]
        return 0 if gone else 1
    elif cmd == 'show':
        for k, v in db.items():
            if k.startswith(args[1] + '.'): print(f"{k}={v}")
    elif cmd == 'commit':
        pass
    return 0
args = [a for a in sys.argv[1:] if a != '-q']
db = load()
if args[0] == 'batch':
    for line in sys.stdin:
        line = line.strip()
        if line: run(db, line.split(None, 1))
    rc = 0
else:
    rc = run(db, args)
save(db)
sys.exit(rc)
EOF
chmod +x "${BIN}/uci"

cat > "${BIN}/jsonfilter" <<'EOF'
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
print(json.dumps(value) if isinstance(value, bool) else value)
EOF
chmod +x "${BIN}/jsonfilter"

cat > "${BIN}/ubus" <<'EOF'
#!/bin/sh
echo "${UBUS_WWIFI:-{\"up\":false\}}"
EOF
chmod +x "${BIN}/ubus"
command -v sha256sum >/dev/null 2>&1 || {
    printf '#!/bin/sh\nexec shasum -a 256 "$@"\n' > "${BIN}/sha256sum"; chmod +x "${BIN}/sha256sum"; }

AP="${BIN}/pulzr-ap"
db() { uci -q get "$1" 2>/dev/null; }
reset_ap() {
    cat > "${UCI_DB}" <<'EOF'
wireless.radio0=wifi-device
wireless.radio0.disabled=1
pulzr.ap=ap
pulzr.ap.enabled=0
pulzr.ap.window=1800
pulzr.identity.serial=0123456789ab
EOF
    rm -rf "${SANDBOX}/run/ap" "${SANDBOX}/etc/pulzr/ap"
    : > "${LOG}"
    unset PULZR_BACKHAUL_CHECK_RC
    export PULZR_BACKHAUL_CHECK_RC=1
}

reset_ap
rc=0; "${AP}" button >/dev/null || rc=$?
check "master switch off: the button still raises it" 0 "${rc}"
check "on the setup network" setup "$(db wireless.pulzr_setup_ap.network)"
check "unadopted: open" none "$(db wireless.pulzr_setup_ap.encryption)"
check "for the configured window" 1800 "$(cat "${SANDBOX}/run/ap/window")"
check "and journalled as the button" 1 "$(grep -c '"reason":"button"' "${SANDBOX}/etc/pulzr/ap/raises.log")"
# The shape, not the value: a machine with an eth0 uses its MAC.
check "its name reads Pulzar, and ends in six hex" yes \
    "$("${AP}" ssid | grep -qE '^Pulzar-[0-9a-f]{6}$' && echo yes || echo no)"

reset_ap
echo 'pulzr.adoption.state=adopted' >> "${UCI_DB}"
"${AP}" button >/dev/null
check "adopted: never open" psk2+ccmp "$(db wireless.pulzr_setup_ap.encryption)"
key="$(db wireless.pulzr_setup_ap.key)"
check "adopted: a 16 character key" 16 "${#key}"
check "the report carries that key" "${key}" \
    "$("${AP}" report | jsonfilter -e '@.key')"
check "and the same one each time" "${key}" "$("${AP}" key)"

reset_ap
check "unadopted: nothing to report" null "$("${AP}" report)"

reset_ap
export PULZR_BACKHAUL_CHECK_RC=0
rc=0; "${AP}" button >/dev/null || rc=$?
check "a working uplink refuses, with its own exit" 2 "${rc}"
check "and raises nothing" "" "$(db wireless.pulzr_setup_ap.mode)"
check "and leaves no marker" no "$([ -e "${SANDBOX}/run/ap/button" ] && echo yes || echo no)"

reset_ap
echo 'pulzr.ap.button=0' >> "${UCI_DB}"
rc=0; "${AP}" button >/dev/null || rc=$?
check "turned off for the button" 4 "${rc}"
check "and raises nothing" "" "$(db wireless.pulzr_setup_ap.mode)"

reset_ap
sed -i.bak '/^wireless.radio0/d' "${UCI_DB}"
rc=0; "${AP}" button >/dev/null || rc=$?
check "no radio" 3 "${rc}"

reset_ap
rc=0; "${AP}" up 600 >/dev/null || rc=$?
check "anything but the button still obeys the master switch" 1 "${rc}"

reset_ap
"${AP}" button >/dev/null
echo 1 > "${SANDBOX}/run/ap/raised"
rc=0; "${AP}" button >/dev/null || rc=$?
check "pressing again while it is up succeeds" 0 "${rc}"
check "and starts its window again" yes "$([ "$(cat "${SANDBOX}/run/ap/raised")" -gt 1 ] && echo yes || echo no)"

# The stale station: a moved gateway's old network is not in range, and hostapd
# holds the AP down until a station on the radio has associated.
station() { cat >> "${UCI_DB}" <<'EOF'
wireless.pulzr_sta=wifi-iface
wireless.pulzr_sta.device=radio0
wireless.pulzr_sta.ssid=old-site
EOF
}
reset_ap; station
"${AP}" button >/dev/null
check "the old station comes off the radio" 1 "$(db wireless.pulzr_sta.disabled)"
"${AP}" down
check "and goes back when the AP comes down" 0 "$(db wireless.pulzr_sta.disabled)"
check "the AP is gone" "" "$(db wireless.pulzr_setup_ap.mode)"
check "and so are its markers" "" "$(ls "${SANDBOX}/run/ap")"

reset_ap; station
echo 'wireless.pulzr_sta.disabled=1' >> "${UCI_DB}"
"${AP}" button >/dev/null
"${AP}" down
check "a station somebody turned off stays off" 1 "$(db wireless.pulzr_sta.disabled)"

reset_ap; station
"${AP}" button >/dev/null
uci set wireless.pulzr_sta.disabled=0      # the console joined a network
"${AP}" station-check
check "a join gets its time" 0 "$(db wireless.pulzr_sta.disabled)"
echo 1 > "${SANDBOX}/run/ap/joining"
"${AP}" station-check
check "a join that goes nowhere gives the radio back to the AP" 1 "$(db wireless.pulzr_sta.disabled)"

reset_ap; station
"${AP}" button >/dev/null
uci set wireless.pulzr_sta.disabled=0
echo 1 > "${SANDBOX}/run/ap/joining"
UBUS_WWIFI='{"up":true}' "${AP}" station-check
check "an association is left alone" 0 "$(db wireless.pulzr_sta.disabled)"

# ── what goes up on the report ──────────────────────────────────────────────

reset_ap
report_json() { "${AP}" report | python3 -c 'import json,sys; v=json.load(sys.stdin); print(v if not isinstance(v,dict) else v["ssid"]+"|"+("key" if len(v["key"])==16 else "nokey"))'; }
echo 'pulzr.adoption.state=adopted' >> "${UCI_DB}"
check "an adopted gateway reports its AP" "Pulzar-abc123|key" "$(PATH="${BIN}:${PATH}" report_json | sed 's/Pulzar-[0-9a-f]*/Pulzar-abc123/')"
echo "pulzr.ap.ssid=Bob's \"AP\"" >> "${UCI_DB}"
check "a configured SSID stays JSON" "Bob's \"AP\"|key" "$(report_json)"
sed -i.bak '/^pulzr.ap.ssid=/d' "${UCI_DB}"
sed -i.bak '/^pulzr.adoption.state=/d' "${UCI_DB}"
check "nothing to say on an unadopted gateway is null, not gone" "None" "$(report_json)"
echo 'pulzr.ap.button=0' >> "${UCI_DB}"
echo 'pulzr.ap.enabled=0' >> "${UCI_DB}"
check "no way to raise it says so" "False" "$(report_json)"
sed -i.bak -e '/^pulzr.ap.button=/d' -e '/^pulzr.ap.enabled=/d' "${UCI_DB}"
sed -i.bak '/=wifi-device$/d' "${UCI_DB}"
check "nor does a board with no radio" "False" "$(report_json)"

# ── the watchdog ────────────────────────────────────────────────────────────

install_script "${FEED}/pulzr-ap/files/usr/sbin/pulzr-ap-watchdog"
mv "${BIN}/pulzr-ap" "${BIN}/pulzr-ap.real"
stub pulzr-ap

# One pass of its loop: the second sleep ends it.
cat > "${BIN}/sleep" <<EOF
#!/bin/sh
if [ -e "${SANDBOX}/slept" ]; then rm -f "${SANDBOX}/slept"; kill \$PPID; exit 0; fi
touch "${SANDBOX}/slept"
EOF
one_pass() { rm -f "${SANDBOX}/slept"; : > "${LOG}"; "${BIN}/pulzr-ap-watchdog" 2>/dev/null & wait $! 2>/dev/null; }

raised() {
    mkdir -p "${SANDBOX}/run/ap"
    date +%s > "${SANDBOX}/run/ap/raised"
    rm -f "${SANDBOX}/run/ap/button"
    [ "${1:-}" = button ] && touch "${SANDBOX}/run/ap/button"
}

reset_ap; raised button; export PULZR_BACKHAUL_CHECK_RC=1; one_pass
check "master switch off does not take down what the button raised" 0 "$(called 'pulzr-ap down')"
check "it asks about every uplink" 1 "$(called 'pulzr-backhaul-check --any')"
check "and looks after the station" 1 "$(called 'pulzr-ap station-check')"

reset_ap; raised; export PULZR_BACKHAUL_CHECK_RC=1; one_pass
check "master switch off takes down anything else" 1 "$(called 'pulzr-ap down')"

reset_ap; raised button; export PULZR_BACKHAUL_CHECK_RC=0; one_pass
check "an uplink coming back takes the button's AP down" 1 "$(called 'pulzr-ap down')"

reset_ap; raised button; echo 1 > "${SANDBOX}/run/ap/raised"; export PULZR_BACKHAUL_CHECK_RC=1; one_pass
check "and so does its window" 1 "$(called 'pulzr-ap down')"

reset_ap; export PULZR_BACKHAUL_CHECK_RC=1
echo 'pulzr.ap.fallback=1' >> "${UCI_DB}"
echo 'pulzr.ap.fallback_after=0' >> "${UCI_DB}"
one_pass
check "master switch off still stops the fallback" 0 "$(called 'pulzr-ap up')"

# ── does any uplink work ────────────────────────────────────────────────────

install_script "${FEED}/pulzr-base/files/usr/sbin/pulzr-backhaul-check"
sed -e "s#/lib/functions/network.sh#${SANDBOX}/lib/network.sh#" \
    "${FEED}/pulzr-base/files/usr/share/pulzr/cellular.sh" > "${SANDBOX}/lib/cellular.sh"
sed -e "s#/lib/functions/network.sh#${SANDBOX}/lib/network.sh#" \
    "${FEED}/pulzr-base/files/usr/share/pulzr/wired.sh" > "${SANDBOX}/lib/wired.sh"
{ echo 'network.wan=interface'; echo 'network.wan_lan1=interface'; } >> "${UCI_DB}"

# netifd, as far as these scripts ask it: UP names the interfaces that are up.
cat > "${SANDBOX}/lib/network.sh" <<'EOF'
network_flush_cache() { :; }
network_is_up() { case " ${UP:-} " in *" $1 "*) return 0 ;; esac; return 1; }
network_get_device() { network_is_up "$2" || return 1; eval "$1=dev-$2"; }
network_get_gateway() { network_is_up "$2" || return 1; eval "$1=10.0.0.1"; }
EOF

# curl answers for the devices in CONNECTS, and only those.
cat > "${BIN}/curl" <<'EOF'
#!/bin/sh
while [ $# -gt 0 ]; do
    [ "$1" = "--interface" ] && dev="$2"
    shift
done
case " ${CONNECTS:-} " in *" ${dev:-none} "*) printf '0.123456' ;; *) printf '0.000000' ;; esac
EOF
chmod +x "${BIN}/curl"

stub pulzr-wifi-uplink
stub wg
any() { "${BIN}/pulzr-backhaul-check" --any; }

export UP="" CONNECTS=""
got="$(any)"; check "nothing up: nothing works" "1:" "$?:${got}"

export UP="wan" CONNECTS=""
got="$(any)"; check "a lease that goes nowhere is not an uplink" "1:" "$?:${got}"

export UP="wan" CONNECTS="dev-wan"
got="$(any)"; check "wired" "0:wired" "$?:${got}"

export UP="wan wan_lan1" CONNECTS="dev-wan_lan1"
got="$(any)"; check "a second wired uplink counts, with the first one dead" "0:wired" "$?:${got}"

export UP="wan_lan1" CONNECTS=""
got="$(any)"; check "and goes nowhere like any other" "1:" "$?:${got}"

export UP="wwifi" CONNECTS="" PULZR_WIFI_UPLINK_RC=0
got="$(any)"; check "WiFi" "0:wifi" "$?:${got}"

export UP="wwifi" CONNECTS="dev-wwifi" PULZR_WIFI_UPLINK_RC=1
got="$(any)"; check "WiFi at a sign-in page does not count, whatever it connects to" "1:" "$?:${got}"

export UP="wwan" CONNECTS="dev-wwan"
got="$(any)"; check "cellular" "0:cellular" "$?:${got}"

export UP="wan wwan" CONNECTS="dev-wwan"
got="$(any)"; check "a dead wired lease does not hide cellular" "0:cellular" "$?:${got}"

mkdir -p "${SANDBOX}/etc/pulzr/wireguard"
echo '{}' > "${SANDBOX}/etc/pulzr/wireguard/tunnel.json"
cat > "${BIN}/wg" <<'EOF'
#!/bin/sh
echo "peer $(date +%s)"
EOF
chmod +x "${BIN}/wg"
export UP="" CONNECTS=""
got="$(any)"; check "a live tunnel is an uplink, with nothing to ask" "0:tunnel" "$?:${got}"

# ── what the LAN ports reach ────────────────────────────────────────────────

lan="${FEED}/pulzr-lan/files/etc/uci-defaults/25-pulzr-lan"
check "the console is open to the LAN ports" "set firewall.devlan_console.dest_port='80 443 8443'" \
    "$(grep 'devlan_console.dest_port' "${lan}")"
check "SSH is not" 0 "$(grep -c "dest_port='[^']*\b22\b" "${lan}")"

# ── what the setup network hands out ────────────────────────────────────────

ap="${FEED}/pulzr-ap/files/etc/uci-defaults/60-pulzr-ap"
check "the setup AP advertises no router" 1 "$(grep -c "dhcp.setup.dhcp_option='3'" "${ap}")"
check "and no DNS server" 1 "$(grep -c "dhcp.setup.dhcp_option='6'" "${ap}")"
check "and forwards nothing" 1 "$(grep -c "setup_zone.forward='REJECT'" "${ap}")"

echo
if [ "${failures}" -gt 0 ]; then
    echo "${failures} failed"
    exit 1
fi
echo "all passed"
