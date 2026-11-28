// Signing the gateway in to a WiFi network's portal, from a browser that is
// somewhere else.
//
// ── WHAT IT IS ─────────────────────────────────────────────────────────────
//
// A guest network carries nothing until somebody clicks through its page, and
// that somebody has to be the gateway: a portal lets in the device that loaded
// it, by its MAC and its address on that network. So the gateway loads the
// page — out of the WiFi radio and nowhere else — and hands it to whoever is
// signing in, over whatever reaches the console: a cable, the setup AP, or
// Pulzr Cloud over cellular. signin.uc is the proxy; this is what it and the
// console share.
//
// ── WHY ITS OWN PORT ───────────────────────────────────────────────────────
//
// A portal's page is somebody else's HTML and script. Served from the
// console's origin it could call the console's API with the session of
// whoever is signing in, so it never is: the proxy is a second uhttpd on
// SIGNIN_PORT, which the browser treats as another origin, and Pulzr Cloud
// gives it another device host for the same reason. The console's own
// listener has no /signin at all.
//
// ── HOW SOMEBODY GETS IN ───────────────────────────────────────────────────
//
// The console, signed in, mints a ticket: one use, a minute. The proxy trades
// it for a cookie on its own origin, good for half an hour. Neither opens
// anything the console's session does.
//
// ── WHEN IT ANSWERS ────────────────────────────────────────────────────────
//
// While pulzr-wifi-uplink says the network is not open, and for ten minutes
// after it opens, so the page a portal shows once you are through still
// loads. Not after that: an open network makes the proxy a way into whatever
// is on the far side of the customer's WiFi, which is nobody's errand.

let _m_fs = require('fs');
let readfile = _m_fs.readfile;
let writefile = _m_fs.writefile;
let unlink = _m_fs.unlink;
let mkdir = _m_fs.mkdir;
let lsdir = _m_fs.lsdir;
let _m_uci = require('uci');
let cursor = _m_uci.cursor;
let _m_util = loadfile('/usr/share/pulzr/console/lib/util.uc', { raw_mode: true })();

// ucode does not hoist function declarations; see util.uc.
let randomId, uplink, available, mintTicket, redeem, session, trust, active,
    viaPulzarNet, readJson;

const SIGNIN_PORT = 8443;
const DIR = '/tmp/pulzr-signin';
const UPLINK = '/var/run/pulzr/wifi-uplink.json';
const TICKET_TTL = 60;
const SESSION_TTL = 1800;
const GRACE = 600;

readJson = function(path) {
    const raw = readfile(path);
    if (!raw) return null;
    try { return json(raw); } catch (e) { return null; }
};

// 64 hex characters from two kernel UUIDs. ucode has no random source of its
// own without ucode-mod-math, and this one is the kernel's CSPRNG.
randomId = function() {
    let id = '';
    for (let i = 0; i < 2; i++)
        id += replace(readfile('/proc/sys/kernel/random/uuid') || '', /[^0-9a-f]/g, '');
    return length(id) == 64 ? id : null;
};

// pulzr-wifi-uplink's last answer: { state, ssid, step, host, detail, url,
// hijack, since, checkedAt }. Only about the network the radio is on now: the
// file outlives a join until the next check, and an answer about the network
// before is no answer about this one.
uplink = function() {
    const u = readJson(UPLINK);
    const ssid = cursor().get('wireless', 'pulzr_sta', 'ssid');
    if (!u || !ssid || u.ssid != ssid) return { state: 'unchecked' };
    return u;
};

// Whether the proxy may fetch anything right now. { ok } or { error }.
available = function() {
    if (!cursor().get('wireless', 'pulzr_sta', 'ssid'))
        return { error: 'No WiFi network is joined.' };
    const u = uplink();
    if (u.state == 'portal' || u.state == 'offline') return { ok: true, uplink: u };
    if (u.state == 'open' && time() - int(u.since ?? 0) < GRACE) return { ok: true, uplink: u };
    if (u.state == 'open') return { error: 'The WiFi network is open. There is nothing to sign in to.' };
    return { error: 'The WiFi network has not been checked yet.' };
};

// Whether the request came over Pulzr Cloud — the tunnel, or the SIM that
// the cloud reaches through 1NCE — rather than from somebody here. The
// console needs to know which URL opens the proxy: Pulzr Cloud gives it a
// device host of its own, and locally it is this address on SIGNIN_PORT.
viaPulzarNet = function(addr) {
    if (!addr || !match(addr, /^[0-9.]+$/)) return false;
    const route = _m_util.run(sprintf("ip -4 route get '%s' 2>/dev/null", addr)) || '';
    const dev = match(route, /\sdev\s+(\S+)/);
    if (!dev) return false;
    if (dev[1] == 'wg0') return true;
    const cell = _m_util.runJson('ubus call network.interface.wwan status') || {};
    return cell.l3_device != null && dev[1] == cell.l3_device;
};

mintTicket = function(subject, addr) {
    const can = available();
    if (can.error) return can;
    const id = randomId();
    if (!id) return { error: 'Could not start a sign-in.' };
    mkdir(DIR, 0700);
    mkdir(DIR + '/tickets', 0700);
    writefile(DIR + '/tickets/' + id,
              sprintf('%J', { subject: subject, expires: time() + TICKET_TTL }));
    return {
        ok: true,
        port: SIGNIN_PORT,
        path: '/signin/session?t=' + id,
        via: viaPulzarNet(addr) ? 'Pulzar Cloud' : 'local',
    };
};

// A ticket, once, for a session id. Null when it is unknown, used or late.
redeem = function(ticket) {
    if (type(ticket) != 'string' || !match(ticket, /^[0-9a-f]{64}$/)) return null;
    const path = DIR + '/tickets/' + ticket;
    const t = readJson(path);
    // Gone before it is judged, so two requests racing one ticket cannot both
    // get a session out of it.
    unlink(path);
    if (!t || int(t.expires ?? 0) < time()) return null;
    const id = randomId();
    if (!id) return null;
    mkdir(DIR + '/sessions', 0700);
    writefile(DIR + '/sessions/' + id, sprintf('%J', {
        subject: t.subject, expires: time() + SESSION_TTL, trust: [],
    }));
    return id;
};

session = function(id) {
    if (type(id) != 'string' || !match(id, /^[0-9a-f]{64}$/)) return null;
    const s = readJson(DIR + '/sessions/' + id);
    if (!s || int(s.expires ?? 0) < time()) return null;
    s.id = id;
    return s;
};

// A host whose certificate whoever is signing in chose to accept, as a
// browser asks. Remembered for the session, not beyond it.
trust = function(s, host) {
    if (index(s.trust ?? [], host) >= 0) return;
    push(s.trust, host);
    writefile(DIR + '/sessions/' + s.id, sprintf('%J', {
        subject: s.subject, expires: s.expires, trust: s.trust,
    }));
};

// Somebody is signing in now. roam() leaves the network alone meanwhile:
// moving the radio to another network would take the page out from under them.
active = function() {
    for (let name in (lsdir(DIR + '/sessions') || []))
        if (session(name)) return true;
    return false;
};

return { SIGNIN_PORT, active, available, mintTicket, redeem, session, trust, uplink };
