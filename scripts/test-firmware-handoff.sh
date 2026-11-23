#!/usr/bin/env bash
#
# pulzr-firmware handoff brings an image that waited on the flash into RAM
# and upgrades from there, stopping services only when memory is short, and
# flashes nothing when it still is.
#
#   scripts/test-firmware-handoff.sh
#
# The console stages an image on the overlay when neither a card nor RAM has
# room (firmware.uc, flashRoom); sysupgrade overwrites the overlay, so it must
# never be handed an image there. Campo's GL-SFT1200 (115MB of RAM, 23MB
# available, an 18.5MB image) is the gateway this is for.

set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIRMWARE="${ROOT_DIR}/feed/pulzr-base/files/usr/sbin/pulzr-firmware"
fail=0

run_case() {   # <name> <MemAvailable kB before> <after stopping kB>
    local name="$1" before="$2" after="$3"
    local box; box="$(mktemp -d)"
    local stubs="${box}/bin" initd="${box}/init.d"
    mkdir -p "${stubs}" "${initd}" "${box}/tmp" "${box}/overlay"
    printf 'MemAvailable:   %s kB\n' "${before}" > "${box}/meminfo"

    stub() { printf '#!/bin/sh\n%s\n' "$2" > "${stubs}/$1"; chmod +x "${stubs}/$1"; }
    stub logger 'exit 0'
    stub uci 'exit 1'
    stub sync 'exit 0'
    stub sysupgrade "echo \"\$1\" > '${box}/flashed'"
    stub ubus "printf '{\\n\\t\"log\": {\\n\\t},\\n\\t\"network\": {\\n\\t},\\n\\t\"dnsmasq\": {\\n\\t},\\n\\t\"wpad\": {\\n\\t},\\n\\t\"nosuch\": {\\n\\t}\\n}\\n'"
    command -v sha256sum >/dev/null || stub sha256sum 'shasum -a 256 "$1"'
    for s in log network dnsmasq wpad; do
        printf '#!/bin/sh\necho "%s $1" >> "%s/actions"\n[ "$1" = stop ] && printf "MemAvailable:   %s kB\\n" > "%s/meminfo"\nexit 0\n' \
            "${s}" "${box}" "${after}" "${box}" > "${initd}/${s}"
        chmod +x "${initd}/${s}"
    done

    sed -e 's|^\. /etc/pulzr/board.conf|:|' \
        -e "s|^JOURNAL_DIR=.*|JOURNAL_DIR=${box}/journal|" \
        -e "s|/usr/sbin/pulzr-legacy back|:|" \
        -e "s|/proc/meminfo|${box}/meminfo|g" \
        -e "s|/proc/sys/vm/drop_caches|${box}/drop_caches|g" \
        -e "s|/etc/init.d/|${initd}/|g" \
        -e "s|staged=/tmp/pulzr-firmware.img|staged=${box}/tmp/pulzr-firmware.img|" \
        "${FIRMWARE}" > "${box}/pulzr-firmware"

    local image="${box}/overlay/pulzr-firmware.img"
    head -c $((2 * 1024 * 1024)) /dev/urandom > "${image}"
    PATH="${stubs}:${PATH}" sh "${box}/pulzr-firmware" pending "${image}" test
    PATH="${stubs}:${PATH}" sh "${box}/pulzr-firmware" handoff "${image}" move
    echo "${box}"
}

check() { if eval "$2"; then :; else echo "FAIL ($1): $3"; fail=1; fi; }

# Room in RAM from the start: nothing stopped, moved, flashed from /tmp.
box="$(run_case roomy 20000 20000 | tail -n1)"
check roomy "[ \"\$(cat '${box}/flashed' 2>/dev/null)\" = '${box}/tmp/pulzr-firmware.img' ]" "not flashed from RAM"
check roomy "[ ! -f '${box}/overlay/pulzr-firmware.img' ]" "the flash copy was kept"
check roomy "[ ! -s '${box}/actions' ]" "services were stopped with room to spare"
rm -rf "${box}"

# Short until services stop: they stop (not log or network), then it flashes.
box="$(run_case tight 3000 20000 | tail -n1)"
check tight "[ -f '${box}/flashed' ]" "not flashed after stopping services"
check tight "grep -q 'dnsmasq stop' '${box}/actions' && grep -q 'wpad stop' '${box}/actions'" "services not stopped"
check tight "! grep -qE '^(log|network) ' '${box}/actions'" "log or network was stopped"
rm -rf "${box}"

# Still short: nothing flashed, services started again, the journal says why.
box="$(run_case short 3000 4000 | tail -n1)"
check short "[ ! -f '${box}/flashed' ]" "flashed without the memory for it"
check short "grep -q 'dnsmasq start' '${box}/actions' && grep -q 'wpad start' '${box}/actions'" "services not started again"
check short "grep -q '^state=failed' '${box}/journal/journal'" "the journal does not say it failed"
check short "grep -q '^reason=Not enough memory' '${box}/journal/journal'" "no reason in the journal"
rm -rf "${box}"

[ "${fail}" -eq 0 ] && echo "ok: handoff moves to RAM, stops services only when short, flashes nothing when it cannot"
exit "${fail}"
