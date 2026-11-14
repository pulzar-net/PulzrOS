// Numbers as the web console prints them — console/src/lib/format.ts, line
// for line, so the same gateway reads the same in a browser and a terminal.

// ucode does not hoist function declarations; see console/lib/util.uc.
let duration, countdown, bytes, count, pad2, ago, modemKind;

pad2 = function(n) { return sprintf('%02d', n); };

duration = function(s) {
    if (s == null) return null;
    s = int(s);
    const d = int(s / 86400), h = int((s % 86400) / 3600), m = int((s % 3600) / 60);
    if (d) return sprintf('%dd %dh', d, h);
    if (h) return sprintf('%dh %dm', h, m);
    if (m) return sprintf('%dm', m);
    return sprintf('%ds', s);
};

countdown = function(s) {
    s = int(s ?? 0);
    if (s < 0) s = 0;
    if (s >= 3600) return sprintf('%dh %sm', int(s / 3600), pad2(int((s % 3600) / 60)));
    return sprintf('%dm %ss', int(s / 60), pad2(s % 60));
};

bytes = function(v) {
    if (v == null) return null;
    const units = [ 'B', 'KB', 'MB', 'GB' ];
    // A double: ucode divides two integers as integers, and 1536 bytes is not 1.0 KB.
    let n = +v * 1.0, i = 0;
    while (n >= 1024 && i < 3) { n /= 1024; i++; }
    return i == 0 ? sprintf('%d %s', n, units[i]) : sprintf('%.1f %s', n, units[i]);
};

// Thousands separators, as toLocaleString() gives an en-US browser.
count = function(v) {
    if (v == null) return null;
    let s = sprintf('%d', v), out = '';
    const neg = substr(s, 0, 1) == '-';
    if (neg) s = substr(s, 1);
    while (length(s) > 3) {
        out = ',' + substr(s, length(s) - 3) + out;
        s = substr(s, 0, length(s) - 3);
    }
    return (neg ? '-' : '') + s + out;
};

const MODEM_KINDS = {
    qmi: 'QMI modem', mbim: 'MBIM modem', at: 'AT modem',
    hilink: 'HiLink dongle', tether: 'Tethered phone',
};

modemKind = function(kind) {
    return kind ? (MODEM_KINDS[kind] ?? null) : null;
};

return { bytes, count, countdown, duration, pad2, modemKind };
