// What the terminal UI reads and changes: the web console's own modules.
//
// Reads call lib/ directly, as api/index.uc's GET routes do. Changes go
// through lib/actions.uc and nowhere else (act), so an action taken here is
// validated and audited exactly as the same action taken in a browser.
//
// As root (a serial, HDMI or USB console, or Pulzr Cloud's) the modules are
// loaded here. As anybody else — `ssh pulzr@<gateway>`, which runs as the
// unprivileged `pulzr` account — each call goes to pulzr-console-broker over
// ubus, which runs it as root after its own checks. The same names either
// way, so nothing above this file needs to know which.

let _m_fs = require('fs');

const LIB = '/usr/share/pulzr/console/lib/';
const load = (name) => loadfile(LIB + name + '.uc', { raw_mode: true })();

const uid = int(match(_m_fs.readfile('/proc/self/status') ?? '', /\nUid:\s+([0-9]+)/)?.[1] ?? '0');

if (uid == 0) {
    const out = { unprivileged: false, useToken: () => null };
    for (let name in [ 'auth', 'system', 'network', 'ports', 'lorawan', 'claim', 'io',
                       'access', 'bluetooth', 'addons', 'actions', 'diag' ])
        out[name] = load(name);
    out.act = (name, req, session) => out.actions[name](req, session);
    return out;
}

let conn = null, token = null;

const broker = (method, args) => {
    if (!conn) conn = require('ubus').connect();
    const r = conn ? conn.call('pulzr.console', method, { ...args, token: token ?? '' }) : null;
    if (r == null) die('The console service is not answering.');
    return r;
};

// ucode has no catch-all for property names, so the calls are named: exactly
// the ones the broker allows, which are all the terminal makes.
const NAMES = {
    auth: [ 'loginLocal', 'loginMethods', 'recoveryChallenge', 'recoveryVerify',
            'terminalStart', 'terminalCollect', 'readSession', 'destroySession' ],
    system: [ 'summary', 'stats', 'processes', 'logs', 'history', 'features' ],
    network: [ 'status', 'backhaul' ],
    lorawan: [ 'status', 'concentrator', 'gps', 'forwarders' ],
    ports: [ 'status' ],
    io: [ 'status' ],
    bluetooth: [ 'status' ],
    addons: [ 'status' ],
    access: [ 'status', 'scan', 'wifiDetail', 'probeResult', 'key' ],
    claim: [ 'status', 'qr', 'isAdopted', 'reclaiming', 'adoptionCheckResult' ],
};

const out = { unprivileged: true };
for (let module in keys(NAMES)) {
    out[module] = {};
    for (let fn in NAMES[module]) {
        const m = module, f = fn;
        out[m][f] = function(...args) {
            const r = broker('call', { module: m, fn: f, args });
            return r.error ? { error: r.error } : r.result;
        };
    }
}

// Any action by name; the broker checks the name and the session, and uses
// its own copy of the session rather than this one.
out.act = (name, req) => {
    const r = broker('call', { module: 'actions', fn: name, args: [ req ?? {} ] });
    return r.error ? { error: r.error } : r.result;
};
out.useToken = (t) => { token = t; };
out.diag = { output: (command, args) => broker('diag', { command, args }) };
return out;
