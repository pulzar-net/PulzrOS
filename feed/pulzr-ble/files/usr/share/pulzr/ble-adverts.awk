# Advertising reports from `hcidump -R`, batched into one JSON line per
# interval for mosquitto_pub -l. Run by pulzr-ble; see there for why.
#
#   -v oui       MAC prefixes to keep, space-separated; empty keeps all
#   -v min_rssi  weaker reports are dropped
#   -v interval  seconds per line
#   -v stats     a file rewritten each interval with how many beacons it held
#                and how many advertisements they sent
#
# hcidump prints one HCI packet per `>` (from the controller) or `<` (to it)
# line, continued on lines that start with spaces.

function hex(s,   i, n) {
    n = 0
    for (i = 1; i <= length(s); i++) n = n * 16 + index("0123456789ABCDEF", substr(s, i, 1)) - 1
    return n
}
function wanted(mac,   i, n, p) {
    if (oui == "") return 1
    n = split(oui, p, " ")
    for (i = 1; i <= n; i++) if (index(mac, p[i]) == 1) return 1
    return 0
}
# One LE Advertising Report: 04 3E len 02 count type addrtype addr*6
# datalen data* rssi. Controllers send one report per event; an event
# carrying several lays them out field by field, and is skipped.
function report(   mac, i, len, data, rssi) {
    if (nb < 15 || b[1] != "04" || b[2] != "3E" || b[4] != "02" || b[5] != "01") return
    mac = b[13] b[12] b[11] b[10] b[9] b[8]
    if (!wanted(mac)) return
    len = hex(b[14])
    if (nb < 15 + len) return
    data = ""
    for (i = 15; i < 15 + len; i++) data = data b[i]
    rssi = hex(b[15 + len]); if (rssi > 127) rssi -= 256
    if (rssi < min_rssi) return
    seen[mac] = data
    if (!(mac in best) || rssi > best[mac]) best[mac] = rssi
    adverts++
}
function flush(now,   mac, out, n) {
    out = ""; n = 0
    for (mac in seen) {
        out = out (n++ ? "," : "") "{\"mac\":\"" mac "\",\"rssi\":" best[mac] ",\"data\":\"" tolower(seen[mac]) "\"}"
        delete seen[mac]; delete best[mac]
    }
    if (n) { printf "{\"time\":%d,\"adverts\":[%s]}\n", now, out; fflush() }
    printf "{\"at\":%d,\"beacons\":%d,\"adverts\":%d}\n", now, n, adverts > stats; close(stats)
    adverts = 0
    started = now
}
BEGIN { started = systime() }
/^>/ { report(); nb = 0; incoming = 1 }
/^</ { report(); nb = 0; incoming = 0 }
/^ / || /^>/ {
    if (!incoming) next
    for (i = 1; i <= NF; i++) if ($i != ">") b[++nb] = toupper($i)
    if (systime() - started >= interval) flush(systime())
}
