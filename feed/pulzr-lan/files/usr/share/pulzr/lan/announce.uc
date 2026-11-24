// A device on the LAN that runs the Pulzr SDK and is not enrolled yet says it
// is here, and Pulzr Cloud lists it to this gateway's organization to adopt.
//
//   POST https://<this gateway>/api/announce   (the console, lib-less route)
//   { mac, csr, eui?, hw?: { model, mac, fw }, package? }
//
//   202 { retryAfter }       heard; not adopted yet
//   200 <enroll answer>      adopted: the same body as Pulzr's
//                            POST /api/v1/devices/enroll, handed over once
//   400 / 403 / 429          malformed / not that MAC on this LAN / too soon
//
// WHY THROUGH THE GATEWAY
//
// A MAC is printed on a label and seen by anything on the wire, so Pulzr
// Cloud cannot take one on trust from the internet: whoever announced a
// device's MAC first would be adopted as it. Here the announce is believed
// only when it comes from the LAN bridge and the kernel's ARP entry for its
// source address is that MAC, so faking one means being on this LAN. The
// device's own key (the CSR) is what gets certified on adoption, so the
// answer is useless to anybody else, and nothing in either direction is a
// secret: the MQTT channel that carries it to Pulzr Cloud is not one for
// secrets (pulzr-mqtt-agent).
//
// Kept on tmpfs, a few at a time, an hour at most: an announce is repeated
// every five minutes by a device that is still there. pulzr-lan's `status`
// lists them (without the CSR) and `announce get|answer` serve the agent's
// lan-announce and lan-adopted ops; the console's /api/announce receives.

let fs = require('fs');

const DIR = '/var/run/pulzr/announce';
const ARP = '/proc/net/arp';
const MAX = 4;
const KEEP = 3600;
const EVERY = 300;
const SOONEST = 20;
const MAC = /^([0-9a-f]{2}:){5}[0-9a-f]{2}$/;
const CSR_HEAD = '-----BEGIN CERTIFICATE REQUEST-----';

function file(mac, kind) {
    return DIR + '/' + replace(mac, /:/g, '') + kind;
}

function read(path) {
    try { return json(fs.readfile(path) ?? 'null'); } catch (e) { return null; }
}

function write(path, doc) {
    fs.mkdir('/var/run/pulzr');
    fs.mkdir(DIR);
    fs.writefile(path + '.new', sprintf('%J', doc));
    fs.rename(path + '.new', path);
}

function forget(mac) {
    fs.unlink(file(mac, '.json'));
    fs.unlink(file(mac, '.answer.json'));
}

// The MAC the kernel holds for an address on the bridge, from a complete
// (0x2) entry only: an incomplete one is a guess, not an answer.
function macAt(ip, bridge) {
    for (let line in split(fs.readfile(ARP) ?? '', '\n')) {
        let f = split(trim(line), /\s+/);
        if (length(f) >= 6 && f[0] == ip && f[5] == bridge && f[2] == '0x2')
            return lc(f[3]);
    }
    return null;
}

function records() {
    let out = [], now = time();
    for (let name in (fs.lsdir(DIR) ?? [])) {
        if (!match(name, /^[0-9a-f]{12}\.json$/)) continue;
        let r = read(DIR + '/' + name);
        if (!r || now - (r.lastAt ?? 0) > KEEP) {
            if (r?.mac) forget(r.mac);
            continue;
        }
        push(out, r);
    }
    return out;
}

function short(value, max) {
    return type(value) == 'string' && length(value) <= max ? value : null;
}

return {
    // For `pulzr-lan status`: what Pulzr Cloud lists, without the CSR.
    list: () => map(records(), (r) => ({
        mac: r.mac, ip: r.ip, eui: r.eui, model: r.hw?.model, fw: r.hw?.fw,
        package: r.package, at: r.at, lastAt: r.lastAt,
        answered: !!fs.stat(file(r.mac, '.answer.json')),
    })),

    // For the agent's lan-announce: the whole record, CSR included, which
    // Pulzr Cloud signs when somebody adopts the device.
    get: (mac) => {
        mac = lc(mac ?? '');
        return match(mac, MAC) ? read(file(mac, '.json')) : null;
    },

    // For the agent's lan-adopted: the enroll answer, held for the device's
    // next announce and then forgotten with its record.
    answer: (mac, doc) => {
        mac = lc(mac ?? '');
        if (!match(mac, MAC) || !read(file(mac, '.json')))
            return { error: 'no announce from that MAC' };
        if (type(doc) != 'object' || type(doc.certificate) != 'string' || type(doc.eui) != 'string')
            return { error: 'an answer has the eui and certificate enroll gives' };
        write(file(mac, '.answer.json'), doc);
        return { mac, answered: true };
    },

    // The console's /api/announce. [status, body].
    receive: (ip, req, bridge) => {
        let mac = lc(type(req?.mac) == 'string' ? req.mac : '');
        if (!match(mac, MAC))
            return [400, { error: 'mac is the device\'s MAC, aa:bb:cc:dd:ee:ff.' }];
        if (macAt(ip, bridge) != mac)
            return [403, { error: 'Not that MAC on this gateway\'s LAN.' }];
        let csr = req.csr;
        if (type(csr) != 'string' || length(csr) > 2048 || index(csr, CSR_HEAD) != 0)
            return [400, { error: 'csr is a PEM certificate request of at most 2048 characters.' }];
        let eui = req.eui ? lc(req.eui) : null;
        if (eui != null && !match(eui, /^[0-9a-f]{16}$/))
            return [400, { error: 'eui is 16 hex digits.' }];
        let pkg = req.package ?? null;
        if (pkg != null && !match(pkg, /^sha256:[0-9a-f]{64}$/))
            return [400, { error: 'package is sha256:<64 hex digits>.' }];

        let answer = read(file(mac, '.answer.json'));
        if (answer) {
            forget(mac);
            return [200, answer];
        }
        let now = time(), had = read(file(mac, '.json'));
        if (had && now - (had.lastAt ?? 0) < SOONEST)
            return [429, { retryAfter: EVERY }];
        if (!had && length(records()) >= MAX)
            return [429, { retryAfter: EVERY }];
        write(file(mac, '.json'), {
            mac, ip, csr, eui, package: pkg,
            hw: { model: short(req.hw?.model, 64), mac: short(req.hw?.mac, 17), fw: short(req.hw?.fw, 64) },
            at: had?.at ?? now, lastAt: now,
        });
        return [202, { retryAfter: EVERY }];
    },
};
