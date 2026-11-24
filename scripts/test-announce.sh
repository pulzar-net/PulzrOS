#!/usr/bin/env bash
#
# An SDK device's announce on the LAN (feed/pulzr-lan/files/usr/share/pulzr/
# lan/announce.uc), against a scratch directory and a fake ARP table:
#
#   UCODE=/path/to/ucode scripts/test-announce.sh
#
# Believed only for the MAC the ARP table gives the caller's address on the
# bridge; malformed ones refused; repeated too soon refused; a few at a time;
# listed without the CSR; an answer handed over once, then forgotten.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UCODE="${UCODE:-ucode}"
command -v "${UCODE}" >/dev/null 2>&1 || { echo "ucode not found; set UCODE=/path/to/ucode" >&2; exit 2; }
MODULES="$(dirname "$(command -v "${UCODE}")")"

T="$(mktemp -d)"
trap 'rm -rf "${T}"' EXIT

sed -e "s|'/var/run/pulzr/announce'|'${T}/announce'|" -e "s|'/var/run/pulzr'|'${T}'|" \
    -e "s|'/proc/net/arp'|'${T}/arp'|" \
    "${ROOT}/feed/pulzr-lan/files/usr/share/pulzr/lan/announce.uc" > "${T}/announce.uc"

cat > "${T}/arp" <<'EOF'
IP address       HW type     Flags       HW address            Mask     Device
192.168.64.157   0x1         0x2         02:80:e1:9c:0f:3f     *        br-devlan
192.168.64.158   0x1         0x0         02:80:e1:9c:0f:40     *        br-devlan
10.0.0.9         0x1         0x2         02:80:e1:9c:0f:41     *        wan
192.168.64.160   0x1         0x2         02:00:00:00:00:01     *        br-devlan
192.168.64.161   0x1         0x2         02:00:00:00:00:02     *        br-devlan
192.168.64.162   0x1         0x2         02:00:00:00:00:03     *        br-devlan
192.168.64.163   0x1         0x2         02:00:00:00:00:04     *        br-devlan
EOF

"${UCODE}" -L "${MODULES}" -D "T=${T}" -e '
let fs = require("fs");
let a = loadfile(T + "/announce.uc", { raw_mode: true })();
let failed = 0;
function check(name, got, want) {
    let ok = sprintf("%J", got) == sprintf("%J", want);
    printf("  %s  %s%s\n", ok ? "ok  " : "FAIL", name, ok ? "" : sprintf("  got %J, want %J", got, want));
    if (!ok) failed++;
}
const CSR = "-----BEGIN CERTIFICATE REQUEST-----\nMIIB\n-----END CERTIFICATE REQUEST-----\n";
const OPTA = { mac: "02:80:E1:9C:0F:3F", csr: CSR, hw: { model: "arduino_opta", fw: "0.2.0" },
               package: "sha256:" + join("", map(split(sprintf("%064d", 0), ""), (c) => "a")) };
const IP = "192.168.64.157";

check("another MAC at that address", a.receive(IP, { ...OPTA, mac: "02:80:e1:9c:0f:40" }, "br-devlan")[0], 403);
check("an incomplete ARP entry is no proof", a.receive("192.168.64.158", { ...OPTA, mac: "02:80:e1:9c:0f:40" }, "br-devlan")[0], 403);
check("not from the bridge", a.receive("10.0.0.9", { ...OPTA, mac: "02:80:e1:9c:0f:41" }, "br-devlan")[0], 403);
check("no CSR", a.receive(IP, { ...OPTA, csr: "hello" }, "br-devlan")[0], 400);
check("a bad package", a.receive(IP, { ...OPTA, package: "md5:x" }, "br-devlan")[0], 400);
check("heard", a.receive(IP, OPTA, "br-devlan"), [202, { retryAfter: 300 }]);
check("again too soon", a.receive(IP, OPTA, "br-devlan")[0], 429);
let listed = a.list();
check("listed by its lower-case MAC", map(listed, (r) => r.mac), ["02:80:e1:9c:0f:3f"]);
check("without the CSR", "csr" in listed[0], false);
check("the record keeps it, for the cloud", a.get("02:80:e1:9c:0f:3f").csr, CSR);

for (let i = 1; i <= 3; i++)
    check(sprintf("another device %d", i),
          a.receive(sprintf("192.168.64.%d", 159 + i), { ...OPTA, mac: sprintf("02:00:00:00:00:%02d", i) }, "br-devlan")[0], 202);
check("no more than four at a time",
      a.receive("192.168.64.163", { ...OPTA, mac: "02:00:00:00:00:04" }, "br-devlan")[0], 429);

check("an answer needs what enroll gives", a.answer("02:80:e1:9c:0f:3f", { hello: 1 }).error != null, true);
check("not for a MAC that never announced", a.answer("02:00:00:00:00:09", { eui: "x", certificate: "y" }).error != null, true);
const ANSWER = { eui: "028" + "0e1fffe9c0f3f", certificate: "-----BEGIN CERTIFICATE-----\nMIIC\n", caChain: "x",
                 broker: { host: "mqtt.pulzr.net", port: 8883 }, assertionKey: "k", wireguard: null };
check("an answer is held", a.answer("02:80:E1:9C:0F:3F", ANSWER), { mac: "02:80:e1:9c:0f:3f", answered: true });
check("and listed as answered", filter(a.list(), (r) => r.mac == "02:80:e1:9c:0f:3f")[0].answered, true);
check("handed over on the next announce", a.receive(IP, OPTA, "br-devlan"), [200, ANSWER]);
check("then forgotten", a.get("02:80:e1:9c:0f:3f"), null);

let stale = a.get("02:00:00:00:00:01");
stale.lastAt -= 7200;
fs.writefile(T + "/announce/020000000001.json", sprintf("%J", stale));
check("an hour quiet is gone", length(filter(a.list(), (r) => r.mac == "02:00:00:00:00:01")), 0);

printf(failed ? "FAILED: %d\n" : "announce: all ok\n", failed);
exit(failed ? 1 : 0);
'
