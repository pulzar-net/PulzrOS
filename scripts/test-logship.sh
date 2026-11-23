#!/usr/bin/env bash
#
# pulzr-logship's filter and sender, against stubs.
#
#   scripts/test-logship.sh
#
# What it must do: send lines at the configured level and worse, stamped from
# logd's clock; never its own lines; escape what JSON needs escaped; hold to
# the token bucket and count what it held back; not send a line twice after a
# restart; keep a batch Pulzar Cloud did not take and send it with the next.
set -uo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SHIP="${ROOT_DIR}/feed/pulzr-adopt/files/usr/sbin/pulzr-logship"
SANDBOX="$(mktemp -d)"
trap 'rm -rf "${SANDBOX}"' EXIT
STUBS="${SANDBOX}/bin"
mkdir -p "${STUBS}"
export SANDBOX

cat > "${STUBS}/uci" <<'STUB'
#!/bin/sh
case "$*" in
    "-q get pulzr.logship.level") cat "${SANDBOX}/level" 2>/dev/null ;;
esac
STUB
cat > "${STUBS}/logger" <<'STUB'
#!/bin/sh
STUB
# The claim's syslog: keeps the body, answers as $SANDBOX/answer says.
cat > "${STUBS}/claim" <<'STUB'
#!/bin/sh
[ "$1" = syslog ] || exit 2
cp "$2" "${SANDBOX}/sent.$(ls "${SANDBOX}" | grep -c '^sent\.')"
[ "$(cat "${SANDBOX}/answer" 2>/dev/null)" != refuse ]
STUB
# The gateway's own awk is BusyBox's; use it when this host has one.
if command -v busybox >/dev/null 2>&1 && busybox awk 'BEGIN{}' 2>/dev/null; then
    printf '#!/bin/sh\nexec busybox awk "$@"\n' > "${STUBS}/awk"
    echo "using busybox awk"
fi
chmod +x "${STUBS}"/*

export PATH="${STUBS}:${PATH}" PULZR_LOGSHIP_DIR="${SANDBOX}/run" PULZR_CLAIM="${STUBS}/claim"

pass=0 fail=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1"; }
expect() {
    local name="$1" want="$2" got="$3"
    if [ "${got}" = "${want}" ]; then ok "${name}"; else bad "${name}: got [${got}], wanted [${want}]"; fi
}
spool() { cat "${SANDBOX}/run/spool" 2>/dev/null; }
valid_json() { python3 -c 'import json,sys; [json.loads(l) for l in sys.stdin if l.strip()]' ; }

line() { # epoch.ms facility.level text
    printf 'Sun Nov 22 18:00:00 2026 [%s] %s %s\n' "$1" "$2" "$3"
}

# ── the level, the stamp, the tag, its own lines ───────────────────────────
{
    line 1795370400.100 daemon.notice "netifd: Interface 'wan' is now up"
    line 1795370401.200 daemon.info "dnsmasq[1234]: query for something"
    line 1795370402.300 daemon.err 'odhcpd[88]: a "quoted" path C:\dir'
    line 1795370403.400 kern.warn 'kernel: [   12.345678] usb 1-1: new device'
    line 1795370404.500 daemon.err "logship: could not send"
    echo "a line logread did not write"
} | sh "${SHIP}" filter

expect "notice and worse, nothing else" 3 "$(spool | wc -l | tr -d ' ')"
expect "stamped from logd's clock" '1795370400' "$(spool | head -1 | sed 's/.*"t":\([0-9]*\).*/\1/')"
expect "tag without its pid" '"tag":"odhcpd"' "$(spool | sed -n 2p | grep -o '"tag":"[^"]*"')"
expect "kernel lines keep their tag" '"tag":"kernel"' "$(spool | sed -n 3p | grep -o '"tag":"[^"]*"')"
if spool | valid_json 2>/dev/null; then ok "quotes and backslashes escaped"; else bad "the spool is not JSON: $(spool)"; fi
expect "its own lines are not sent" "" "$(spool | grep logship)"

# ── a restart replays the log; nothing goes twice ──────────────────────────
{
    line 1795370402.300 daemon.err 'odhcpd[88]: a "quoted" path C:\dir'
    line 1795370403.400 kern.warn 'kernel: [   12.345678] usb 1-1: new device'
    line 1795370403.401 daemon.err "netifd: same second, later millisecond"
} | sh "${SHIP}" filter
expect "only what came after the last line sent" 4 "$(spool | wc -l | tr -d ' ')"

# ── the level is the gateway's setting ─────────────────────────────────────
rm -rf "${SANDBOX}/run"; echo warning > "${SANDBOX}/level"
line 1795370500.000 daemon.notice "netifd: up" | sh "${SHIP}" filter
expect "level warning drops notice" "" "$(spool)"
rm -f "${SANDBOX}/level"

# ── the bucket: 60 at once, then 10 a minute ───────────────────────────────
rm -rf "${SANDBOX}/run"
for i in $(seq 1 100); do line "1795371000.$(printf '%03d' "$i")" daemon.err "crashd: loop ${i}"; done \
    | sh "${SHIP}" filter
expect "a burst is held to 60" 60 "$(spool | grep -c '"t":')"
# Six minutes later: sixty more tokens, and the forty held back are counted first.
for i in $(seq 1 5); do line "1795371360.$(printf '%03d' "$i")" daemon.err "crashd: later ${i}"; done \
    | sh "${SHIP}" filter
expect "what was held back is counted" '{"dropped":40}' "$(spool | grep dropped)"
expect "the bucket refills" 65 "$(spool | grep -c '"t":')"

# ── sending ────────────────────────────────────────────────────────────────
sh "${SHIP}" flush
expect "one request" 1 "$(ls "${SANDBOX}" | grep -c '^sent\.')"
body="$(cat "${SANDBOX}/sent.0")"
if printf '{%s}' "${body}" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert len(d["lines"]) == 65 and d["dropped"] == 40' 2>/dev/null
then ok "the body is the lines and the count"; else bad "body: ${body:0:200}"; fi
expect "nothing left after it was taken" "" "$(ls "${SANDBOX}/run" | grep -E '^(spool|batch)')"

# Refused: kept, and sent with the next.
echo refuse > "${SANDBOX}/answer"
line 1795371400.000 daemon.err "netifd: one" | sh "${SHIP}" filter
sh "${SHIP}" flush
expect "a refused batch is kept" 1 "$(ls "${SANDBOX}/run" | grep -c '^batch')"
rm -f "${SANDBOX}/answer"
line 1795371401.000 daemon.err "netifd: two" | sh "${SHIP}" filter
sh "${SHIP}" flush
last="$(ls "${SANDBOX}" | grep '^sent\.' | sort -t. -k2 -n | tail -1)"
expect "sent with the next" 2 "$(printf '{%s}' "$(cat "${SANDBOX}/${last}")" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["lines"]))')"
expect "and gone once taken" 0 "$(ls "${SANDBOX}/run" | grep -c '^batch')"

# Nothing waiting: no request.
before="$(ls "${SANDBOX}" | grep -c '^sent\.')"
sh "${SHIP}" flush
expect "nothing to send, nothing sent" "${before}" "$(ls "${SANDBOX}" | grep -c '^sent\.')"

echo "${pass} passed, ${fail} failed"
[ "${fail}" = 0 ]
