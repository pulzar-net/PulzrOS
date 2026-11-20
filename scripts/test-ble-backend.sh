#!/usr/bin/env bash
#
# The config pulzr-ble writes for `pulzr-edge ble` (pulzr.ble.backend
# pulzr-edge), from /usr/libexec/pulzr/edge-config, against a uci stub.
#
#   scripts/test-ble-backend.sh
#
# pulzr-edge refuses unknown keys and an empty admit list without admit_all,
# so a config that parses as TOML can still stop the service; the keys and
# their types are checked here against what pulzr-edge's [ble] takes.

set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="${ROOT_DIR}/feed/pulzr-edge/files/usr/libexec/pulzr/edge-config"

command -v python3 >/dev/null 2>&1 || { echo "python3 is required (tomllib)" >&2; exit 2; }

SANDBOX="$(mktemp -d)"
trap 'rm -rf "${SANDBOX}"' EXIT
mkdir -p "${SANDBOX}/bin"
export SANDBOX

# `uci -q get pulzr.<section>.<option>` from ${SANDBOX}/uci/<section>.<option>.
cat > "${SANDBOX}/bin/uci" <<'EOF'
#!/bin/sh
[ "$1" = "-q" ] && shift
[ "$1" = get ] || exit 1
f="${SANDBOX}/uci/${2#pulzr.}"
[ -f "${f}" ] && cat "${f}"
EOF
printf '#!/bin/sh\necho "$*" >> "${SANDBOX}/log"\n' > "${SANDBOX}/bin/logger"
chmod +x "${SANDBOX}/bin/"*
export PATH="${SANDBOX}/bin:${PATH}"

set_uci() { mkdir -p "${SANDBOX}/uci"; printf '%s\n' "$2" > "${SANDBOX}/uci/$1"; }
clear_uci() { rm -rf "${SANDBOX}/uci" "${SANDBOX}/log"; }

FAIL=0
check() {
    if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: want [$2], got [$3]"; FAIL=1; fi
}

# The whole config, as pulzr-ble writes it, in a sandboxed run directory.
config() {
    sh -c '
        . "$1"
        EDGE_RUNDIR="${SANDBOX}/run" EDGE_PASSWORD="${SANDBOX}/run/password"
        top="$(edge_common)" || exit 1
        printf "%s\n\n" "${top}"; edge_ble
    ' sh "${LIB}"
}

# Checks the TOML against pulzr-edge's Config and BleCfg; prints one
# `key=value` line per [ble] key, sorted, or the reason it would be refused.
validate() {
    python3 -c '
import sys, tomllib
c = tomllib.loads(sys.stdin.read())
top = {"gateway_eui": str, "state_dir": str, "broker": dict, "ble": dict}
broker = {"host": str, "port": int, "ca": str, "username": str, "password_file": str}
ble = {"enabled": bool, "transport": str, "interval_secs": int, "admit": list,
       "admit_all": bool, "min_rssi": int, "active": bool, "parsed": bool,
       "commands": bool, "random_address": bool}
for table, keys in ((c, top), (c["broker"], broker), (c["ble"], ble)):
    for k, v in table.items():
        if k not in keys: sys.exit(f"unknown key {k}")
        if not isinstance(v, keys[k]): sys.exit(f"{k} is {type(v).__name__}")
b = c["ble"]
if not b.get("admit") and not b.get("admit_all"): sys.exit("admit empty without admit_all")
if not -128 <= b.get("min_rssi", -100) <= 127: sys.exit("min_rssi out of i8")
for k in sorted(b): print(f"{k}={b[k]}")
'
}

adopted() {
    set_uci adoption.state adopted
    set_uci identity.gateway_eui 0016C001F1500ABC
    set_uci mqtt.host mqtt.example.net
    set_uci mqtt.username gw-0016c001f1500abc
    set_uci mqtt.password 'not-a-real-secret'
}

# --- the defaults pulzr-ble seeds ------------------------------------------
clear_uci; adopted
set_uci ble.oui BC5729; set_uci ble.min_rssi -100; set_uci ble.interval 10
out="$(config | validate 2>&1)"
check "defaults: KKM's prefix, passive, hci0" \
    "$(printf 'admit=[%s]\nenabled=True\ninterval_secs=10\nmin_rssi=-100\ntransport=hci0' "'BC5729'")" "${out}"
check "the EUI in lower case" 'gateway_eui = "0016c001f1500abc"' "$(config | head -n1)"
check "the password beside the config, not in it" "not-a-real-secret" "$(cat "${SANDBOX}/run/password")"
check "the password file is the owner's only" "600" "$(stat -c %a "${SANDBOX}/run/password" 2>/dev/null || stat -f %Lp "${SANDBOX}/run/password")"
check "no password in the config" "0" "$(config | grep -c 'not-a-real-secret')"

# --- several prefixes, lower case, one not hex -------------------------------
clear_uci; adopted
set_uci ble.oui 'bc5729 ac233f XYZ'
out="$(config | validate 2>&1)"
check "prefixes upper-cased, the bad one skipped" "admit=['BC5729', 'AC233F']" "$(echo "${out}" | grep '^admit=')"
check "the bad prefix is logged" "1" "$(grep -c 'XYZ is not hex' "${SANDBOX}/log")"

# --- no prefix: every device, as pulzr-ble sends -------------------------------
clear_uci; adopted
out="$(config | validate 2>&1)"
check "empty oui is admit_all" "admit_all=True" "$(echo "${out}" | grep '^admit')"
check "unset interval and min_rssi take pulzr-ble's defaults" "interval_secs=10 min_rssi=-100" \
    "$(echo "${out}" | grep -E '^(interval_secs|min_rssi)=' | tr '\n' ' ' | sed 's/ $//')"

# --- garbage in the numbers --------------------------------------------------
clear_uci; adopted
set_uci ble.oui BC5729; set_uci ble.interval '10; rm -rf /'; set_uci ble.min_rssi abc
out="$(config | validate 2>&1)"
check "a bad interval or min_rssi falls back" "interval_secs=10 min_rssi=-100" \
    "$(echo "${out}" | grep -E '^(interval_secs|min_rssi)=' | tr '\n' ' ' | sed 's/ $//')"
for bad in 0 5- -200 --5; do
    set_uci ble.interval "${bad}"; set_uci ble.min_rssi "${bad}"
    out="$(config | validate 2>&1)"
    check "${bad}: falls back" "interval_secs=10 min_rssi=-100" \
        "$(echo "${out}" | grep -E '^(interval_secs|min_rssi)=' | tr '\n' ' ' | sed 's/ $//')"
done
set_uci ble.interval 30; set_uci ble.min_rssi -85
out="$(config | validate 2>&1)"
check "good values kept" "interval_secs=30 min_rssi=-85" \
    "$(echo "${out}" | grep -E '^(interval_secs|min_rssi)=' | tr '\n' ' ' | sed 's/ $//')"

# --- not adopted, or a login that cannot go into TOML --------------------------
clear_uci; adopted; set_uci adoption.state unadopted
config >/dev/null 2>&1; check "unadopted: no config" "1" "$?"
clear_uci; adopted; set_uci mqtt.username 'gw"x'
config >/dev/null 2>&1; check "a quote in the username: no config" "1" "$?"

exit "${FAIL}"
