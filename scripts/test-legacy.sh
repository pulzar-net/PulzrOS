#!/usr/bin/env bash
#
# A gateway running ParkezeOS upgrades to PulzrOS and may be rolled back.
#
#   scripts/test-legacy.sh
#
# Builds a fake root laid out the way a ParkezeOS gateway keeps its state,
# with sample configuration and keys, restores it onto a fake PulzrOS root the
# way sysupgrade would, runs the first-boot migration (pulzr-legacy forward)
# and asserts that every file and value came across byte for byte. Then it
# does the rollback: pulzr-legacy back, and the old paths must hold the
# state the new system ended with. Finally it checks the pieces around the
# migration that a rollback or an upgraded gateway depends on: the keep lists,
# the unchanged fleet keys, the package renames, the mDNS and SSH aliases.
#
# The scripts that need a gateway (uci, procd, umdns) are not run; what is
# asserted about them is what they ship.

set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LEGACY="${ROOT_DIR}/feed/pulzr-base/files/usr/sbin/pulzr-legacy"
SANDBOX="$(mktemp -d)"
trap 'rm -rf "${SANDBOX}"' EXIT

pass=0
fail=0
check() {
    local what="$1"; shift
    if "$@" >/dev/null 2>&1; then pass=$((pass + 1)); echo "ok   ${what}"
    else fail=$((fail + 1)); echo "FAIL ${what}"; fi
}
same() { cmp -s "$1" "$2"; }

legacy() { PULZR_ROOT="$1" sh "${LEGACY}" "$2"; }

# ── a ParkezeOS gateway's state ─────────────────────────────────────────────

mkroot_old() {
    local r="$1"
    mkdir -p "${r}/etc/config" "${r}/etc/parkeze/"{claim/next,console,wireguard,upgrade,speedtest,ap,lan} \
             "${r}/etc/ssh" "${r}/etc/dropbear"

    cat > "${r}/etc/config/parkeze" <<'EOF'
config identity 'identity'
	option serial '10000000d3a1234ab'
	option gateway_eui 'a84041ffff1234ab'
	option hostname 'parkeze-d3a1234ab'

config adoption 'adoption'
	option state 'adopted'
	option org 'org-sample'
	option since '2026-10-01T12:00:00Z'

config console 'console'
	option local_login '0'

config mqtt 'mqtt'
	option host 'mqtt.parkeze.com'
	option port '8883'
	option username 'gw-a84041ffff1234ab'
	option password 'sample-broker-password'
	option topic_prefix 'us915'

config lan_client 'lan_client_1'
	option mac 'c2:6c:1d:d1:f7:b3'
	option policy 'internet'
EOF
    printf 'CLAIM-SAMPLE-ID\n'            > "${r}/etc/parkeze/claim/id"
    printf 'sample-claim-secret-0001\n'   > "${r}/etc/parkeze/claim/secret"
    printf 'NEXT-SAMPLE-ID\n'             > "${r}/etc/parkeze/claim/next/id"
    printf 'parkeze\n'                    > "${r}/etc/parkeze/console/username"
    printf '$6$salt$samplehash\n'         > "${r}/etc/parkeze/console/password"
    printf -- '-----BEGIN CERTIFICATE-----\nsample\n-----END CERTIFICATE-----\n' > "${r}/etc/parkeze/console/cert.pem"
    printf -- '-----BEGIN PRIVATE KEY-----\nsample\n-----END PRIVATE KEY-----\n' > "${r}/etc/parkeze/console/key.pem"
    chmod 0600 "${r}/etc/parkeze/console/key.pem"
    printf '{"at":1,"event":"login"}\n'   > "${r}/etc/parkeze/console/audit.log"
    printf 'sample-wireguard-private-key=\n' > "${r}/etc/parkeze/wireguard/private"
    chmod 0600 "${r}/etc/parkeze/wireguard/private"
    printf '{"endpoint":"wg.net.parkeze.com:51820","address":"10.99.4.17"}\n' > "${r}/etc/parkeze/wireguard/tunnel.json"
    printf 'ssh-ed25519 AAAAC3NzaC1sample recovery\n' > "${r}/etc/parkeze/recovery.pub"
    printf 'ssh-ed25519 AAAAC3NzaC1sample tech@site\n' > "${r}/etc/parkeze/site-keys"
    printf 'state=good\nfrom_image=/mnt/sd/parkeze/firmware/abc.img\n' > "${r}/etc/parkeze/upgrade/journal"
    printf '[{"at":1,"down":1}]\n'        > "${r}/etc/parkeze/speedtest/history.json"
    printf 'sample-ap-secret\n'           > "${r}/etc/parkeze/ap/secret"
    printf '1 button\n'                   > "${r}/etc/parkeze/ap/raises.log"
    printf '1 forward\n'                  > "${r}/etc/parkeze/lan/forwards.log"
    printf '12345\n'                      > "${r}/etc/parkeze/cellular-usage"
    printf 'PARKEZE_VERSION="0.3.13"\n'   > "${r}/etc/parkeze/board.conf"
    # What sysupgrade carries and this migration must not touch.
    printf 'sample-host-key\n'            > "${r}/etc/ssh/ssh_host_ed25519_key"
    printf 'sample-dropbear-key\n'        > "${r}/etc/dropbear/dropbear_ed25519_host_key"
}

# The PulzrOS image's own files, which the restore lays the old state over.
mkroot_new() {
    local r="$1"
    mkdir -p "${r}/etc/config" "${r}/etc/pulzr"
    printf "config adoption 'adoption'\n\toption state 'unadopted'\n" > "${r}/etc/config/pulzr"
    printf 'PULZR_VERSION="0.3.14"\n'      > "${r}/etc/pulzr/board.conf"
    printf 'ssh-ed25519 AAAAC3NzaC1image firmware\n' > "${r}/etc/pulzr/firmware.pub"
    printf 'ssh-ed25519 AAAAC3NzaC1image recovery\n' > "${r}/etc/pulzr/recovery.pub"
}

# Every file of the old state, as paths relative to /etc/parkeze.
OLD_FILES="claim/id claim/secret claim/next/id console/username console/password
console/cert.pem console/key.pem console/audit.log wireguard/private
wireguard/tunnel.json recovery.pub site-keys upgrade/journal
speedtest/history.json ap/secret ap/raises.log lan/forwards.log cellular-usage"

# ── forward: the first boot of PulzrOS ──────────────────────────────────────

R="${SANDBOX}/gw"
mkroot_old "${R}"
mkroot_new "${R}"
cp -pR "${R}/etc/parkeze" "${SANDBOX}/old-snapshot"
cp -p "${R}/etc/config/parkeze" "${SANDBOX}/old-config"
cp -p "${R}/etc/ssh/ssh_host_ed25519_key" "${SANDBOX}/host-key"
cp -p "${R}/etc/pulzr/firmware.pub" "${SANDBOX}/image-firmware.pub"
cp -p "${R}/etc/pulzr/board.conf" "${SANDBOX}/image-board.conf"

legacy "${R}" forward
check "forward exits 0" test $? -eq 0

check "the UCI file moved: /etc/config/pulzr is /etc/config/parkeze, byte for byte" \
    same "${SANDBOX}/old-config" "${R}/etc/config/pulzr"
for f in ${OLD_FILES}; do
    check "kept byte for byte: ${f}" same "${SANDBOX}/old-snapshot/${f}" "${R}/etc/pulzr/${f}"
done
check "the key file keeps its mode" test "$(stat -c %a "${R}/etc/pulzr/console/key.pem" 2>/dev/null || stat -f %Lp "${R}/etc/pulzr/console/key.pem")" = 600
check "the claim secret value is intact" grep -qx 'sample-claim-secret-0001' "${R}/etc/pulzr/claim/secret"
check "the WireGuard private key is intact" grep -qx 'sample-wireguard-private-key=' "${R}/etc/pulzr/wireguard/private"
check "the broker credentials are intact" grep -q "option password 'sample-broker-password'" "${R}/etc/config/pulzr"
check "the broker host is not rewritten" grep -q "option host 'mqtt.parkeze.com'" "${R}/etc/config/pulzr"
check "the hub host is not rewritten" grep -q 'wg.net.parkeze.com:51820' "${R}/etc/pulzr/wireguard/tunnel.json"
check "adoption state is intact" grep -q "option state 'adopted'" "${R}/etc/config/pulzr"
check "the image's board.conf is not replaced by the old one" same "${SANDBOX}/image-board.conf" "${R}/etc/pulzr/board.conf"
check "the image's firmware.pub is not touched" same "${SANDBOX}/image-firmware.pub" "${R}/etc/pulzr/firmware.pub"
check "the old board.conf is not carried" test "$(grep -c PARKEZE_VERSION "${R}/etc/pulzr/board.conf")" = 0
check "SSH host keys are untouched (no rotation)" same "${SANDBOX}/host-key" "${R}/etc/ssh/ssh_host_ed25519_key"
check "the old paths are still there for a rollback" same "${SANDBOX}/old-config" "${R}/etc/config/parkeze"
for f in ${OLD_FILES}; do
    check "old path intact: ${f}" same "${SANDBOX}/old-snapshot/${f}" "${R}/etc/parkeze/${f}"
done
check "the marker says the new paths are current" test -e "${R}/etc/parkeze/.synced-from-pulzr"

legacy "${R}" forward
check "a second forward is a no-op" same "${SANDBOX}/old-config" "${R}/etc/config/pulzr"

# ── the new system runs, changes state, then upgrades again by hand ─────────

printf 'sample-claim-secret-0001\n' > "${R}/etc/pulzr/claim/secret"
sed -i.bak "s/option org 'org-sample'/option org 'org-moved'/" "${R}/etc/config/pulzr"; rm -f "${R}/etc/config/pulzr.bak"
printf 'new-file\n' > "${R}/etc/pulzr/console/new-file"
legacy "${R}" forward
check "forward with the marker present leaves newer state alone" grep -q "org-moved" "${R}/etc/config/pulzr"

# ── rollback: the old paths must carry what the new system ended with ──────

rm -f "${R}/etc/pulzr/ap/raises.log"
legacy "${R}" back
check "back exits 0" test $? -eq 0
check "rollback: /etc/config/parkeze has the latest state" grep -q "org-moved" "${R}/etc/config/parkeze"
check "rollback: /etc/config/parkeze is /etc/config/pulzr" same "${R}/etc/config/pulzr" "${R}/etc/config/parkeze"
check "rollback: a file added since is there" grep -qx new-file "${R}/etc/parkeze/console/new-file"
check "rollback: a file removed since is gone" test ! -e "${R}/etc/parkeze/ap/raises.log"
check "rollback: claim identity unchanged" same "${SANDBOX}/old-snapshot/claim/id" "${R}/etc/parkeze/claim/id"
check "rollback: WireGuard key unchanged" same "${SANDBOX}/old-snapshot/wireguard/private" "${R}/etc/parkeze/wireguard/private"
check "rollback: broker credentials unchanged" grep -q "sample-broker-password" "${R}/etc/config/parkeze"
check "rollback: the old board.conf is left to its image" same "${SANDBOX}/old-snapshot/board.conf" "${R}/etc/parkeze/board.conf"
check "rollback: SSH host keys untouched" same "${SANDBOX}/host-key" "${R}/etc/ssh/ssh_host_ed25519_key"

# ── the old image ran and changed things; then a second upgrade ────────────
#
# ParkezeOS's keep list does not name the marker, so it is not in the backup
# the old image makes. The old paths are then current.

rm -f "${R}/etc/parkeze/.synced-from-pulzr"
sed -i.bak "s/option org 'org-moved'/option org 'org-by-old-image'/" "${R}/etc/config/parkeze"; rm -f "${R}/etc/config/parkeze.bak"
printf 'changed-on-old\n' > "${R}/etc/parkeze/claim/secret"
legacy "${R}" forward
check "rollback then forward: what the old image changed wins" grep -q "org-by-old-image" "${R}/etc/config/pulzr"
check "rollback then forward: files too" grep -qx changed-on-old "${R}/etc/pulzr/claim/secret"

# ── a fresh PulzrOS flash has nothing to migrate ───────────────────────────

F="${SANDBOX}/fresh"
mkroot_new "${F}"
legacy "${F}" forward
check "a fresh flash: forward changes nothing" test "$(grep -c 'unadopted' "${F}/etc/config/pulzr")" = 1
check "a fresh flash: no marker, no old paths" test ! -e "${F}/etc/parkeze"

# ── keep lists ──────────────────────────────────────────────────────────────

KEEP="${SANDBOX}/keep"
cat "${ROOT_DIR}"/feed/*/files/lib/upgrade/keep.d/* | grep -v '^#' | grep . | sort -u > "${KEEP}"
# What ParkezeOS's own keep lists named, from the last ParkezeOS release.
for p in /etc/parkeze/claim/ /etc/parkeze/console/ /etc/parkeze/wireguard/ /etc/parkeze/recovery.pub \
         /etc/parkeze/upgrade/ /etc/parkeze/site-keys /etc/parkeze/speedtest/ /etc/parkeze/ap/ /etc/parkeze/lan/ \
         /etc/ssh/ssh_host_ed25519_key /etc/ssh/ssh_host_ed25519_key.pub /etc/ssh/ssh_host_rsa_key \
         /etc/ssh/ssh_host_rsa_key.pub /etc/dropbear/dropbear_ed25519_host_key /etc/dropbear/dropbear_rsa_host_key; do
    check "keep list has the old path ${p}" grep -qxF "${p}" "${KEEP}"
    case "${p}" in
        /etc/parkeze/*)
            check "keep list has the new path for ${p}" grep -qxF "/etc/pulzr/${p#/etc/parkeze/}" "${KEEP}" ;;
    esac
done
check "keep list names the marker" grep -qxF /etc/parkeze/.synced-from-pulzr "${KEEP}"
check "board.conf is in no keep list" test "$(grep -c board.conf "${KEEP}")" = 0

# ── keys that must not change ──────────────────────────────────────────────

sha() { shasum -a 256 "$1" | awk '{ print $1 }'; }
check "SSH CA is the same key, byte for byte" \
    test "$(sha "${ROOT_DIR}/boards/common/ssh/pulzr_user_ca.pub")" = dce6c47f6c77ba87051e898a37245bc4686c13f5316c1a95c94d78944134012d
check "fleet adoption key is the same key, byte for byte" \
    test "$(sha "${ROOT_DIR}/boards/common/ssh/fleet/pulzr-fleet.pub")" = 2746efde3f89fad6d75e123f44c0630eb490f5b5976f7220ca092fd2ff78309a

# ── packages ────────────────────────────────────────────────────────────────

STAGE="${SANDBOX}/stage"
# The pulzr-edge module binaries and pulzr-probe are sdk/build.sh's output,
# which this job does not build; only package metadata is checked here, so
# stub binaries stand in for them. <package>:<the binary its fetch takes>.
SDK_STUB="${SANDBOX}/sdk"
for pair in pulzr-modbus:pulzr-edge pulzr-zigbee:pulzr-edge-zigbee pulzr-zwave:pulzr-edge-zwave \
            pulzr-matter:pulzr-edge-matter pulzr-ble:pulzr-edge-ble pulzr-ip:pulzr-edge-ip pulzr-probe:pulzr-probe; do
    pkg="${pair%%:*}" bin="${pair#*:}"
    while read -r arch _; do
        case "${arch}" in ''|'#'*) continue ;; esac
        mkdir -p "${SDK_STUB}/${arch}" && printf '#!/bin/sh\n' > "${SDK_STUB}/${arch}/${bin}"
        chmod +x "${SDK_STUB}/${arch}/${bin}"
    done < "${ROOT_DIR}/feed/${pkg}/arches"
done
PULZR_SDK_OUT="${SDK_STUB}" bash "${ROOT_DIR}/scripts/build-feed.sh" "${ROOT_DIR}/feed" "${STAGE}" 0.0.1 1 >/dev/null 2>&1 \
    || { fail=$((fail + 1)); echo "FAIL build-feed.sh stages the feed"; }
# Packages ParkezeOS never shipped have no old name to answer for, and nor do
# add-ons: apk installs one only from the add-on repository, after the
# sysupgrade to PulzrOS has already dropped the image's old packages
# (parkeze-ble was in the Pi images; pulzr-ble is an add-on). Listed by hand,
# so a renamed package cannot drop out of this check by accident.
NO_OLD_NAME="pulzr-probe pulzr-thread pulzr-modbus pulzr-zigbee pulzr-zwave pulzr-matter pulzr-ble pulzr-ip"
for dir in "${ROOT_DIR}"/feed/pulzr-*/; do
    n="$(basename "${dir}")"; old="parkeze-${n#pulzr-}"
    case " ${NO_OLD_NAME} " in *" ${n} "*) continue ;; esac
    # Per architecture for one with an arches file (pulzr-cellular, built
    # into the RAKs' images): every build carries the same names.
    tar="${STAGE}/${n}_noarch.tar"
    [ -f "${tar}" ] || tar="$(ls "${STAGE}/${n}"_*.tar 2>/dev/null | head -n1)"
    info="$(tar -xOf "${tar}" ./info 2>/dev/null)"
    check "${n} provides ${old}"  grep -q "^provides:${old}=" <<<"${info}"
    check "${n} replaces ${old}"  grep -q "^replaces:${old}\$" <<<"${info}"
    check "${n} conflicts with ${old}" grep -q "^depends:.*!${old}\( \|\$\)" <<<"${info}"
done

# ── mDNS, SSH, boot-time pieces ────────────────────────────────────────────

check "mDNS answers pulzr.local" grep -q '"pulzr.local"' "${ROOT_DIR}/feed/pulzr-console/files/etc/umdns/pulzr-local.json"
check "mDNS answers parkeze.local" grep -q '"parkeze.local"' "${ROOT_DIR}/feed/pulzr-console/files/etc/umdns/parkeze-local.json"
check "mDNS answers parkeze-<serial>.local" grep -q 'parkeze-%s.local' "${ROOT_DIR}/feed/pulzr-console/files/etc/uci-defaults/30-pulzr-console"
check "sshd runs the console for both account names" grep -qx 'Match User pulzr,parkeze' "${ROOT_DIR}/feed/pulzr-base/files/usr/share/pulzr/ssh/sshd_config"
check "the inittab path of ParkezeOS still resolves" test "$(readlink "${ROOT_DIR}/feed/pulzr-tui/files/usr/libexec/parkeze-tui-console")" = pulzr-tui-console
check "the migration is the first uci-defaults script" \
    test "$(ls "${ROOT_DIR}"/feed/*/files/etc/uci-defaults | grep -v ':$' | grep . | sort | head -n1)" = 01-pulzr-migrate
check "the migration has the IPKG_INSTROOT guard" grep -q '^\[ -n "${IPKG_INSTROOT}" \] && exit 0' \
    "${ROOT_DIR}/feed/pulzr-base/files/etc/uci-defaults/01-pulzr-migrate"
check "pulzr-firmware writes the old-path copy before sysupgrade" \
    grep -q 'pulzr-legacy back' "${ROOT_DIR}/feed/pulzr-base/files/usr/sbin/pulzr-firmware"
check "no old-name package files shipped besides the aliases" \
    test -z "$(find "${ROOT_DIR}/feed" -name 'parkeze*' ! -path '*/umdns/*' ! -name parkeze-tui-console)"

echo
echo "${pass} passed, ${fail} failed"
exit $((fail > 0))
