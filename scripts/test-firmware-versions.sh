#!/usr/bin/env bash
#
# The gateway's release ordering (lib/firmware.uc, olderThan), which decides
# whether a signed image is an upgrade or a downgrade only staff may make.
# Tags were undotted to 0.4.0-rc8 and are dotted from 0.4.0-rc.9; read as
# before, rc.9 was rc 0, older than rc8, and every rc gateway refused it.
#
#   UCODE=/path/to/ucode scripts/test-firmware-versions.sh

set -euo pipefail

UCODE="${UCODE:-ucode}"
command -v "${UCODE}" >/dev/null 2>&1 || { echo "ucode not found; set UCODE=/path/to/ucode" >&2; exit 2; }
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "${T}"' EXIT
LIB="${ROOT}/feed/pulzr-console/files/usr/share/pulzr/console/lib"

# As shipped, but for uci, which ordering does not touch, and the absolute
# path the module loads its siblings from.
sed -e "s/require('uci')/{ cursor: () => null }/" \
    -e "s#/usr/share/pulzr/console/lib/#${LIB}/#g" "${LIB}/firmware.uc" > "${T}/firmware.uc"

cat > "${T}/test.uc" <<'UC'
let fw = loadfile(ARGV[0])();
let bad = 0;
const want = (a, b, expect) => {
    const got = fw.olderThan(a, b);
    if (got !== expect) { print(`olderThan(${a}, ${b}) is ${got}, not ${expect}\n`); bad++; }
};
const order = ['0.3.6', '0.4.0-rc2', '0.4.0-rc8', 'v0.4.0-rc.9', '0.4.0-rc.10', '0.4.0', '0.5.0-rc.1', 'v0.5.0'];
for (let i = 0; i < length(order); i++)
    for (let j = 0; j < length(order); j++)
        want(order[i], order[j], i < j);
// The release job signs rc.9 undotted (rc9) for the gateways still on the old
// ordering; both spellings are one release here.
want('v0.4.0-rc9', '0.4.0-rc.9', false);
want('0.4.0-rc.9', 'v0.4.0-rc9', false);
want('1.0.0-alpha', '1.0.0-alpha.1', true);
want('1.0.0-alpha.1', '1.0.0-alpha.beta', true);
want('1.0.0-beta', '1.0.0-rc.1', true);
want('garbage', '0.1.0', null);
if (bad) exit(1);
print('release ordering: ok\n');
UC

"${UCODE}" -L "$(dirname "$(command -v "${UCODE}")")" "${T}/test.uc" "${T}/firmware.uc"
