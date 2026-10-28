#!/usr/bin/env bash
#
# parkeze-firmware pending must not delete the image it is about to install.
#
#   scripts/test-firmware-stash.sh
#
# The console stages an upload on the card in the same directory the stash
# lives in, and pending prunes that directory. Before this was checked the
# prune took the staged image with it, sysupgrade found nothing to flash, and
# the console had already answered 202.

set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIRMWARE="${ROOT_DIR}/feed/parkeze-base/files/usr/sbin/parkeze-firmware"

SANDBOX="$(mktemp -d)"
trap 'rm -rf "${SANDBOX}"' EXIT
STUBS="${SANDBOX}/bin"
DIR="${SANDBOX}/card/parkeze/firmware"
mkdir -p "${STUBS}" "${DIR}"

stub() { printf '#!/bin/sh\n%s\n' "$2" > "${STUBS}/$1"; chmod +x "${STUBS}/$1"; }
stub uci "case \"\$3\" in parkeze.storage.mount) echo '${SANDBOX}/card' ;; parkeze.storage.*) echo 1 ;; esac"
stub logger 'exit 0'
command -v sha256sum >/dev/null || stub sha256sum 'shasum -a 256 "$1"'

sed -e 's|^\. /etc/parkeze/board.conf|:|' \
    -e "s|^JOURNAL_DIR=.*|JOURNAL_DIR=${SANDBOX}/journal|" \
    "${FIRMWARE}" > "${SANDBOX}/parkeze-firmware"

IMAGE="${DIR}/parkeze-firmware.img"
head -c 4096 /dev/urandom > "${IMAGE}"
touch "${DIR}/stale.img"

PATH="${STUBS}:${PATH}" sh "${SANDBOX}/parkeze-firmware" pending "${IMAGE}" test

fail=0
[ -f "${IMAGE}" ] || { echo "FAIL: the staged image was deleted before sysupgrade"; fail=1; }
[ -f "${DIR}/stale.img" ] && { echo "FAIL: a stale image was kept"; fail=1; }
ls "${DIR}" | grep -qE '^[0-9a-f]{64}\.img$' || { echo "FAIL: nothing was stashed"; fail=1; }

[ "${fail}" -eq 0 ] && echo "ok: staged image kept, stale pruned, stash written"
exit "${fail}"
