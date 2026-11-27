#!/usr/bin/env bash
#
# Run `pulzr-console-cert selfsigned` against a sandboxed /etc/pulzr/console.
#
#   scripts/test-console-cert.sh
#
# The certificate is what a browser checks the console's address against, and
# it is made once and kept across upgrades: one made without an address is a
# console no Chromium browser opens by that address, on every gateway, until
# something makes it again. So: the names it carries, that it is kept when
# they are right, and that every stale kind a gateway can be carrying from an
# older image is made again. With the host's openssl and uci stubbed.

set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CERT_CMD="${ROOT_DIR}/feed/pulzr-console/files/usr/sbin/pulzr-console-cert"
DEFAULTS="${ROOT_DIR}/feed/pulzr-console/files/etc/uci-defaults/30-pulzr-console"

command -v openssl >/dev/null 2>&1 || { echo "openssl is required" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "python3 is required" >&2; exit 2; }

SANDBOX="$(mktemp -d)"
trap 'rm -rf "${SANDBOX}"' EXIT
STUBS="${SANDBOX}/bin"
STATE="${SANDBOX}/console"
BOARD="${SANDBOX}/board.conf"
mkdir -p "${STUBS}" "${STATE}"

cat > "${STUBS}/uci" <<'EOF'
#!/bin/sh
[ "$1" = "-q" ] && shift
[ "$1 $2" = "get pulzr.identity.hostname" ] || exit 1
[ -n "${HOST:-}" ] || exit 1
echo "${HOST}"
EOF
cat > "${STUBS}/logger" <<'EOF'
#!/bin/sh
EOF
chmod +x "${STUBS}"/*

cat > "${BOARD}" <<'EOF'
PULZR_LAN_IPADDR="192.168.61.1"
PULZR_DEVLAN_IPADDR="192.168.64.1"
PULZR_SETUP_IPADDR="192.168.62.1"
PULZR_USB_IPADDR="192.168.63.1"
EOF

pass=0 fail=0
check() {
    local what="$1"; shift
    if "$@" >/dev/null; then pass=$((pass + 1)); else echo "FAIL: ${what}"; fail=1; fi
}
not() { ! "$@"; }
mode() { python3 -c 'import os,stat,sys; print(oct(stat.S_IMODE(os.stat(sys.argv[1]).st_mode))[2:])' "$1"; }

export HOST=pulzr-c49b1875
selfsigned() {
    PATH="${STUBS}:${PATH}" PULZR_CONSOLE_STATE="${STATE}" PULZR_BOARD_CONF="${BOARD}" \
        sh "${CERT_CMD}" selfsigned
}
cert() { openssl x509 -in "${STATE}/cert.pem" -noout "$@" 2>/dev/null; }
sans() { cert -ext subjectAltName | sed 1d | tr -d ' \n'; }
fingerprint() { cert -fingerprint -sha256; }
has_san() { case ",$(sans)," in *",$1,"*) return 0 ;; esac; return 1; }

# ── a first boot ────────────────────────────────────────────────────────────
check "a first boot makes one" selfsigned
check "it is PEM" cert -subject
for name in DNS:pulzr-c49b1875.local DNS:pulzr.local DNS:parkeze-c49b1875.local DNS:parkeze.local \
            IPAddress:192.168.61.1 IPAddress:169.254.61.1 IPAddress:192.168.64.1 \
            IPAddress:192.168.62.1 IPAddress:192.168.63.1; do
    check "it names ${name}" has_san "${name}"
done
check "the CN is the gateway's name" sh -c "openssl x509 -in '${STATE}/cert.pem' -noout -subject | grep -q 'CN *= *pulzr-c49b1875.local'"
check "it is not a CA" sh -c "openssl x509 -in '${STATE}/cert.pem' -noout -ext basicConstraints | grep -q 'CA:FALSE'"
check "it is for a TLS server" sh -c "openssl x509 -in '${STATE}/cert.pem' -noout -ext extendedKeyUsage | grep -q 'TLS Web Server Authentication'"
check "it lasts no more than 825 days" not cert -checkend $((826 * 86400))
check "it lasts more than two years" cert -checkend $((730 * 86400))
check "it is over the key beside it" \
    [ "$(cert -pubkey)" = "$(openssl pkey -in "${STATE}/key.pem" -pubout 2>/dev/null)" ]
check "the key is P-256" sh -c "openssl pkey -in '${STATE}/key.pem' -noout -text 2>/dev/null | grep -q 'prime256v1\|P-256'"
check "the key is 0600" [ "$(mode "${STATE}/key.pem")" = 600 ]
check "no temporary file is left" [ -z "$(find "${STATE}" -name '*.new')" ]

# ── kept when it is right ───────────────────────────────────────────────────
before="$(fingerprint)"
check "a later boot keeps it" selfsigned
check "the same certificate" [ "$(fingerprint)" = "${before}" ]

# ── made again when stale ───────────────────────────────────────────────────
remade() {
    local what="$1" before
    before="$(fingerprint)"
    check "${what}: runs" selfsigned
    check "${what}: made again" [ "$(fingerprint)" != "${before}" ]
    check "${what}: names the console address" has_san IPAddress:192.168.61.1
}

# What every gateway before this carried: a CN and no names. The openssl
# fallback's PEM, then px5g's DER in the same file name.
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 3650 \
    -keyout "${STATE}/key.pem" -out "${STATE}/cert.pem" \
    -subj "/C=US/ST=NY/O=Pulzar/CN=pulzr-c49b1875.local" 2>/dev/null
remade "a certificate with no names"

openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 3650 \
    -keyout "${SANDBOX}/k" -out "${SANDBOX}/c" -subj "/CN=pulzr-c49b1875.local" 2>/dev/null
openssl x509 -in "${SANDBOX}/c" -outform DER -out "${STATE}/cert.pem"
openssl pkey -in "${SANDBOX}/k" -outform DER -out "${STATE}/key.pem"
check "px5g's DER: runs" selfsigned
check "px5g's DER: now PEM" cert -subject
check "px5g's DER: names the console address" has_san IPAddress:192.168.61.1

echo 'PULZR_SETUP_IPADDR="192.168.72.1"' >> "${BOARD}"
remade "a board with another address"
check "the new address is named" has_san IPAddress:192.168.72.1
check "the old one is not" not has_san IPAddress:192.168.62.1

HOST=pulzr-0a0b0c0d
remade "a new hostname"
check "the new hostname is named" has_san DNS:pulzr-0a0b0c0d.local

# The right names, so only the date is wrong.
openssl req -x509 -new -key "${STATE}/key.pem" -days 10 -out "${STATE}/cert.pem" \
    -subj "/CN=pulzr-0a0b0c0d.local" \
    -addext "subjectAltName=$(sans | sed 's/IPAddress:/IP:/g')" 2>/dev/null
check "the ten-day one has the right names" has_san DNS:pulzr-0a0b0c0d.local
remade "a certificate ten days from its end"

openssl ecparam -name prime256v1 -genkey -noout -out "${STATE}/key.pem" 2>/dev/null
remade "a key that is not the certificate's"

rm -f "${STATE}/key.pem"
remade "a missing key"

# ── no identity yet ─────────────────────────────────────────────────────────
rm -f "${STATE}/cert.pem" "${STATE}/key.pem"
HOST=""
check "no hostname: runs" selfsigned
check "no hostname: pulzr.local" has_san DNS:pulzr.local
check "no hostname: no parkeze-<serial>" not sh -c "openssl x509 -in '${STATE}/cert.pem' -noout -ext subjectAltName | grep -q 'parkeze-'"

# ── the signed certificate is not this command's ────────────────────────────
printf 'signed\n' > "${STATE}/signed.pem"
printf 'key\n' > "${STATE}/signed.key"
HOST=pulzr-c49b1875
rm -f "${STATE}/cert.pem"
selfsigned
check "the CA's certificate is left alone" [ "$(cat "${STATE}/signed.pem")" = signed ]
check "the CA's key is left alone" [ "$(cat "${STATE}/signed.key")" = key ]

# ── first boot and every upgrade ask for it ─────────────────────────────────
check "30-pulzr-console calls it" grep -q '^/usr/sbin/pulzr-console-cert selfsigned' "${DEFAULTS}"

echo "${pass} passed"
exit "${fail}"
