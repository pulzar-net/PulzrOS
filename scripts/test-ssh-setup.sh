#!/usr/bin/env bash
#
# Run parkeze-ssh-setup against a sandboxed /etc/ssh.
#
#   scripts/test-ssh-setup.sh
#
# What it writes decides whether parkeze.net can open a shell on a gateway at
# all: the principal a certificate must name, the CA sshd trusts, and the host
# key parkeze.net has pinned. A wrong principal is a gateway that refuses every
# certificate, and one marked as trusting the CA is never tried with the fleet
# key; a new host key is a gateway refused as an impostor. None of it can be
# checked without a gateway except like this, with dropbearconvert, ssh-keygen,
# sshd and uci stubbed.

set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SETUP="${ROOT_DIR}/feed/parkeze-base/files/usr/sbin/parkeze-ssh-setup"
SHIPPED_CONFIG="${ROOT_DIR}/feed/parkeze-base/files/usr/share/parkeze/ssh/sshd_config"
SHIPPED_CA="${ROOT_DIR}/keys/ca/parkeze_user_ca.pub"
KEYS_ONLY="${ROOT_DIR}/feed/parkeze-console/files/usr/libexec/parkeze-root-keys-only"

command -v python3 >/dev/null 2>&1 || { echo "python3 is required" >&2; exit 2; }

SANDBOX="$(mktemp -d)"
trap 'rm -rf "${SANDBOX}"' EXIT
STUBS="${SANDBOX}/bin"
mkdir -p "${STUBS}"

# ── stubs ───────────────────────────────────────────────────────────────────

cat > "${STUBS}/uci" <<'EOF'
#!/bin/sh
[ "$1" = "-q" ] && shift
[ "$1 $2" = "get parkeze.identity.gateway_eui" ] || exit 1
[ -n "${EUI:-}" ] || exit 1
echo "${EUI}"
EOF

cat > "${STUBS}/logger" <<'EOF'
#!/bin/sh
echo "$*" >> "${SANDBOX}/log"
EOF

# The converted key carries the dropbear key's content, so a test can tell a
# converted key from a generated one.
cat > "${STUBS}/dropbearconvert" <<'EOF'
#!/bin/sh
[ "$1 $2" = "dropbear openssh" ] || exit 1
{ echo "OPENSSH FROM"; cat "$3"; } > "$4"
EOF

cat > "${STUBS}/ssh-keygen" <<'EOF'
#!/bin/sh
# ssh-keygen -y -f <key>          the public line, derived from the content
# ssh-keygen -q -t <type> -N '' -f <key>
type="" file="" public=""
while [ $# -gt 0 ]; do
    case "$1" in
        -y) public=1 ;;
        -t) type="$2"; shift ;;
        -f) file="$2"; shift ;;
        -N) shift ;;
    esac
    shift
done
if [ -n "${public}" ]; then
    [ -s "${file}" ] || exit 1
    case "${file}" in *rsa*) type=rsa ;; *) type=ed25519 ;; esac
    echo "ssh-${type} AAAA$(cksum < "${file}" | cut -d' ' -f1) root@gateway"
    exit 0
fi
echo "GENERATED ${type}" > "${file}"
echo "ssh-${type} AAAAGENERATED root@gateway" > "${file}.pub"
EOF

cat > "${STUBS}/pidof" <<'EOF'
#!/bin/sh
[ "${SSHD_RUNNING:-0}" = 1 ]
EOF

# sshd -T -f <config>: the effective values, as sshd prints them, from the
# Included conf files. Lowercased keywords, as the real one does.
cat > "${STUBS}/sshd" <<'EOF'
#!/bin/sh
[ "$1" = "-T" ] || exit 1
dir="$(dirname "$3")"
cat "${dir}"/sshd_config.d/*.conf 2>/dev/null | awk '{ print tolower($1)" "$2 }'
echo "port 22"
EOF

chmod +x "${STUBS}"/*

export PATH="${STUBS}:${PATH}"
export SANDBOX
SSH="${SANDBOX}/etc/ssh"
SHARE="${SANDBOX}/share"
DROPBEAR="${SANDBOX}/etc/dropbear"
export PARKEZE_SSH_DIR="${SSH}" PARKEZE_SSH_SHARE="${SHARE}" PARKEZE_DROPBEAR_DIR="${DROPBEAR}"
PASSWD="${SANDBOX}/etc/passwd"
SHADOW_FILE="${SANDBOX}/etc/shadow"
export PARKEZE_PASSWD="${PASSWD}" PARKEZE_SHADOW="${SHADOW_FILE}"

# ── helpers ─────────────────────────────────────────────────────────────────

fail=0
pass=0
check() {
    local what="$1"; shift
    if "$@"; then pass=$((pass + 1)); else echo "FAIL: ${what}"; fail=1; fi
}
not() { ! "$@"; }
setup() { bash "${SETUP}" "$@" 2>/dev/null; }
mode() { python3 -c 'import os,stat,sys; print(oct(stat.S_IMODE(os.stat(sys.argv[1]).st_mode))[2:])' "$1"; }
mtimes() { find "${SSH}" -type f -exec python3 -c 'import os,sys; [print(p, os.stat(p).st_mtime_ns) for p in sys.argv[1:]]' {} + | sort; }

fresh() {
    rm -rf "${SANDBOX}/etc" "${SHARE}" "${SANDBOX}/log"
    mkdir -p "${DROPBEAR}" "${SHARE}"
    cp "${SHIPPED_CONFIG}" "${SHARE}/sshd_config"
    cp "${SHIPPED_CA}" "${SHARE}/parkeze_user_ca.pub"
    echo "dropbear ed25519 key" > "${DROPBEAR}/dropbear_ed25519_host_key"
    echo "dropbear rsa key" > "${DROPBEAR}/dropbear_rsa_host_key"
    printf '%s\n' 'root:x:0:0:root:/root:/bin/ash' 'daemon:*:1:1:daemon:/var:/bin/false' > "${PASSWD}"
    printf '%s\n' 'root:*:19000:0:99999:7:::' 'daemon:*:0:0:99999:7:::' > "${SHADOW_FILE}"
    chmod 0644 "${PASSWD}"; chmod 0600 "${SHADOW_FILE}"
}

# ── a gateway upgraded from a dropbear image ────────────────────────────────

fresh
export EUI=AC1F09FFFE0A1B2C SSHD_RUNNING=0
setup; rc=$?
check "setup exits 0" [ "${rc}" = 0 ]
check "sshd_config is the shipped one" cmp -s "${SHARE}/sshd_config" "${SSH}/sshd_config"
check "the principal is the EUI, lowercased" [ "$(cat "${SSH}/auth_principals/root")" = "ac1f09fffe0a1b2c" ]
check "the principal is one line" [ "$(wc -l < "${SSH}/auth_principals/root" | tr -d ' ')" = 1 ]
check "the principals file is 0644" [ "$(mode "${SSH}/auth_principals/root")" = 644 ]
check "the CA is where parkeze.net's docs say" cmp -s "${SHIPPED_CA}" "${SSH}/parkeze_user_ca.pub"
check "the CA config is exactly the documented two lines" [ "$(cat "${SSH}/sshd_config.d/parkeze-ca.conf")" = "TrustedUserCAKeys ${SSH}/parkeze_user_ca.pub
AuthorizedPrincipalsFile ${SSH}/auth_principals/%u" ]
check "dropbear's ed25519 key is carried over" grep -q "dropbear ed25519 key" "${SSH}/ssh_host_ed25519_key"
check "dropbear's rsa key is carried over" grep -q "dropbear rsa key" "${SSH}/ssh_host_rsa_key"
check "host keys are 0600" [ "$(mode "${SSH}/ssh_host_ed25519_key")" = 600 ]
check "with its public half (ed25519)" [ -s "${SSH}/ssh_host_ed25519_key.pub" ]
check "with its public half (rsa)" [ -s "${SSH}/ssh_host_rsa_key.pub" ]
check "dropbear's keys stay for a rollback" [ -s "${DROPBEAR}/dropbear_ed25519_host_key" ]
check "the shipped config includes the CA config first" \
    [ "$(grep -v '^#' "${SSH}/sshd_config" | grep . | head -n1)" = "Include /etc/ssh/sshd_config.d/*.conf" ]
check "the shipped config offers only ed25519 and rsa" \
    [ "$(grep '^HostKey' "${SSH}/sshd_config" | tr '\n' ' ')" = "HostKey /etc/ssh/ssh_host_ed25519_key HostKey /etc/ssh/ssh_host_rsa_key " ]

reported="$(setup --host-key)"
check "the reported key is the converted ed25519 key" [ "${reported}" = "$(awk '{ print $1" "$2 }' "${SSH}/ssh_host_ed25519_key.pub")" ]
check "the reported key has no comment" [ "$(echo "${reported}" | wc -w | tr -d ' ')" = 2 ]

before="$(mtimes)"
sleep 1
setup
check "a second boot writes nothing" [ "$(mtimes)" = "${before}" ]

# ── a converted key is never replaced ───────────────────────────────────────

echo "dropbear key that changed" > "${DROPBEAR}/dropbear_ed25519_host_key"
setup
check "an existing sshd host key is kept" grep -q "dropbear ed25519 key" "${SSH}/ssh_host_ed25519_key"

# ── does sshd trust the CA ──────────────────────────────────────────────────

check "not while sshd is down" not setup --trusts-ca
export SSHD_RUNNING=1
check "yes once sshd runs with it" setup --trusts-ca
echo "0000000000000000" > "${SSH}/auth_principals/root"
check "not when the principal is another gateway's" not setup --trusts-ca
setup
check "the next boot puts the principal right" setup --trusts-ca

# ── no EUI, or not an EUI ───────────────────────────────────────────────────

for eui in "" "ac1f09fffe0a1b2" "ac1f09fffe0a1b2cd" "zz1f09fffe0a1b2c" "ac1f09ff fe0a1b2c"; do
    export EUI="${eui}"
    setup
    check "no principal for '${eui}'" [ ! -e "${SSH}/auth_principals/root" ]
    check "no CA config for '${eui}'" [ ! -e "${SSH}/sshd_config.d/parkeze-ca.conf" ]
    check "no CA for '${eui}'" [ ! -e "${SSH}/parkeze_user_ca.pub" ]
    check "not trusted for '${eui}'" not setup --trusts-ca
done
check "the reason is logged" grep -q "no valid gateway EUI" "${SANDBOX}/log"
export EUI=ac1f09fffe0a1b2c

# ── no CA in the image, or not one CA ───────────────────────────────────────

fresh
rm "${SHARE}/parkeze_user_ca.pub"
setup
check "no CA config without a CA" [ ! -e "${SSH}/sshd_config.d/parkeze-ca.conf" ]
check "no principal without a CA" [ ! -e "${SSH}/auth_principals/root" ]
check "sshd_config still written" [ -s "${SSH}/sshd_config" ]

fresh
cat "${SHIPPED_CA}" "${SHIPPED_CA}" > "${SHARE}/parkeze_user_ca.pub"
setup
check "two CA lines are refused" [ ! -e "${SSH}/sshd_config.d/parkeze-ca.conf" ]

fresh
echo "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQ parkeze-net-ssh-ca" > "${SHARE}/parkeze_user_ca.pub"
setup
check "a CA that is not ed25519 is refused" [ ! -e "${SSH}/sshd_config.d/parkeze-ca.conf" ]

# ── a gateway flashed with this image ───────────────────────────────────────

fresh
rm -f "${DROPBEAR}"/*
setup
check "an ed25519 host key is made" grep -q "GENERATED ed25519" "${SSH}/ssh_host_ed25519_key"
check "and reported" [ "$(setup --host-key)" = "ssh-ed25519 AAAAGENERATED" ]
check "no RSA key is made" [ ! -e "${SSH}/ssh_host_rsa_key" ]

# ── the console account ─────────────────────────────────────────────────────

fresh
setup
check "parkeze is in passwd, uid 0, after root" [ "$(tail -n1 "${PASSWD}")" = "parkeze:x:0:0:Parkeze console:/root:/bin/ash" ]
check "root is still the first uid 0" [ "$(awk -F: '$3 == 0 { print $1; exit }' "${PASSWD}")" = root ]
check "parkeze has an empty password field" grep -qx 'parkeze::0:0:99999:7:::' "${SHADOW_FILE}"
check "root's shadow entry is untouched" grep -qx 'root:\*:19000:0:99999:7:::' "${SHADOW_FILE}"
check "shadow stays 0600" [ "$(mode "${SHADOW_FILE}")" = 600 ]
check "passwd stays 0644" [ "$(mode "${PASSWD}")" = 644 ]
before="$(mtimes)"
setup
check "a second boot rewrites neither" [ "$(mtimes)" = "${before}" ]
echo 'parkeze:x:1000:1000::/home/parkeze:/bin/ash' >> "${PASSWD}"
setup
check "a stray parkeze line is replaced, not doubled" [ "$(grep -c '^parkeze:' "${PASSWD}")" = 1 ]
check "and it is the console's" grep -qx 'parkeze:x:0:0:Parkeze console:/root:/bin/ash' "${PASSWD}"
check "the shipped config forces the TUI for parkeze" grep -qx '    ForceCommand /usr/sbin/parkeze-tui --console' "${SHIPPED_CONFIG}"
check "the parkeze block is the last thing in the file" [ "$(awk '/^Match /{m=NR} END{print (m > 0)}' "${SHIPPED_CONFIG}")" = 1 ]
check "nothing after it but its own indented lines" [ -z "$(awk 'f && !/^    / && NF {print} /^Match User parkeze$/{f=1}' "${SHIPPED_CONFIG}")" ]

# ── root signs in by key or certificate only ────────────────────────────────

check "root by key or certificate only" grep -qx "PermitRootLogin prohibit-password" "${SHIPPED_CONFIG}"
check "no password logins" grep -qx "PasswordAuthentication no" "${SHIPPED_CONFIG}"
check "no empty-password logins" grep -qx "PermitEmptyPasswords no" "${SHIPPED_CONFIG}"

shadow="${SANDBOX}/shadow"
keys_only() { PARKEZE_SHADOW="${shadow}" TMPDIR="${SANDBOX}" sh "${KEYS_ONLY}"; }
printf '%s\n' 'root:$6$rounds=100000$salt$hash:19000:0:99999:7:::' 'daemon:*:0:0:99999:7:::' > "${shadow}"
keys_only
check "a console password on root is taken away" grep -qx 'root:\*:19000:0:99999:7:::' "${shadow}"
check "nobody else's entry changes" grep -qx 'daemon:\*:0:0:99999:7:::' "${shadow}"
check "the file is 0600" [ "$(mode "${shadow}")" = 600 ]
printf '%s\n' 'root:!:19000:0:99999:7:::' > "${shadow}"
keys_only
check "a locked root becomes * so keys still open it" grep -qx 'root:\*:19000:0:99999:7:::' "${shadow}"
before="$(python3 -c 'import os,sys; print(os.stat(sys.argv[1]).st_mtime_ns)' "${shadow}")"
keys_only
check "already * writes nothing" [ "$(python3 -c 'import os,sys; print(os.stat(sys.argv[1]).st_mtime_ns)' "${shadow}")" = "${before}" ]

echo "${pass} passed"
exit "${fail}"
