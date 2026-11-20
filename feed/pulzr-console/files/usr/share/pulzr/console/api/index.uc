{%
// The Pulzar console API.
//
// ── THE uhttpd ucode HANDLER CONTRACT ───────────────────────────────────────
//
// Learned the hard way, on hardware, after the console failed to start on every
// image ever built. uhttpd refused with "The ucode handler declares no
// handle_request() callback" and the four obvious shapes all produced the same
// message, which is why this is written down.
//
//   1. TEMPLATE MODE. uhttpd compiles this file as a ucode *template*, so
//      everything outside {% %} is literal text. An unwrapped file therefore
//      defines nothing at all — which is exactly the failure above, reported as
//      if the callback were merely missing.
//
//   2. BARE GLOBAL ASSIGNMENT. The plugin reads handle_request out of the VM's
//      global scope (uc_vm_scope_get). `export function`, `function` and
//      `return { handle_request }` all leave it somewhere else. Only an
//      assignment to an undeclared name lands where the plugin looks.
//
//   3. NOT A MODULE. `export` is rejected outright here — "Exports may only
//      appear at top level of a module" — so the lib/ files cannot be ES
//      modules either. They end in `return { ... }` and are pulled in with
//      loadfile(), the pre-module convention.
//
//   4. CGI-STYLE RESPONSES. Nothing is returned to uhttpd. The response is
//      written with uhttpd.send(), and the status line is `Status: 200 OK`,
//      not `HTTP/1.1 200 OK` — the HTTP form is accepted and then produces an
//      empty body, which is its own afternoon.
//
// scripts/check-ucode.sh compiles these files with `-cmodule`, which is why
// none of this was caught: CI was validating them as something they are not.
//
// There is no framework underneath — the routing table below is the whole of
// it, and everything it needs is on `env`.

let _m_fs = require('fs');
let readfile = _m_fs.readfile;
let _m_uci = require('uci');
let cursor = _m_uci.cursor;
let auth = loadfile('/usr/share/pulzr/console/lib/auth.uc', { raw_mode: true })();
let system = loadfile('/usr/share/pulzr/console/lib/system.uc', { raw_mode: true })();
let network = loadfile('/usr/share/pulzr/console/lib/network.uc', { raw_mode: true })();
let lorawan = loadfile('/usr/share/pulzr/console/lib/lorawan.uc', { raw_mode: true })();
let claim = loadfile('/usr/share/pulzr/console/lib/claim.uc', { raw_mode: true })();
let io = loadfile('/usr/share/pulzr/console/lib/io.uc', { raw_mode: true })();
let access = loadfile('/usr/share/pulzr/console/lib/access.uc', { raw_mode: true })();
let firmware = loadfile('/usr/share/pulzr/console/lib/firmware.uc', { raw_mode: true })();
let bluetooth = loadfile('/usr/share/pulzr/console/lib/bluetooth.uc', { raw_mode: true })();
let lan = loadfile('/usr/share/pulzr/console/lib/lan.uc', { raw_mode: true })();
let dns = loadfile('/usr/share/pulzr/console/lib/dns.uc', { raw_mode: true })();
let uplinks = loadfile('/usr/share/pulzr/console/lib/uplinks.uc', { raw_mode: true })();
let ports = loadfile('/usr/share/pulzr/console/lib/ports.uc', { raw_mode: true })();
let apply = loadfile('/usr/share/pulzr/console/lib/apply.uc', { raw_mode: true })();
let speedtest = loadfile('/usr/share/pulzr/console/lib/speedtest.uc', { raw_mode: true })();
let addons = loadfile('/usr/share/pulzr/console/lib/addons.uc', { raw_mode: true })();
let radios = loadfile('/usr/share/pulzr/console/lib/radios.uc', { raw_mode: true })();
let thread = loadfile('/usr/share/pulzr/console/lib/thread.uc', { raw_mode: true })();
let radio = loadfile('/usr/share/pulzr/console/lib/radio.uc', { raw_mode: true })();
// What changes the gateway, shared with the terminal UI; see actions.uc.
let actions = loadfile('/usr/share/pulzr/console/lib/actions.uc', { raw_mode: true })();

const SESSION_COOKIE = 'pulzr_session';

// Seconds a change waits to be confirmed before the gateway puts the old
// configuration back (pulzr-apply).
const APPLY_WINDOW = 90;
const CELLULAR_WINDOW = 240;

// Routes reachable without a session. Everything needed to *get* a session,
// and nothing else.
const PUBLIC = {
    'POST /api/auth/login': true,
    'POST /api/auth/sso': true,
    'POST /api/auth/ticket': true,
    'GET  /api/auth/methods': true,
    'POST /api/auth/recovery/challenge': true,
    'POST /api/auth/recovery/verify': true,
    'GET  /api/health': true,

    // The captive portal renders before anybody has signed in, and needs to
    // know what it is looking at. Kept deliberately thin — see access.uc: it
    // reports whether an AP is up and whether DHCP is being served, and
    // nothing that names a customer or a credential.
    'GET  /api/access/status': true,

    // ── provisioning ────────────────────────────────────────────────────
    //
    // Not the claim code. Whoever holds it can adopt the gateway into any
    // organization they run, so it is shown only to a session (the label's
    // password signs in on an unadopted gateway) and on the gateway's own
    // physical consoles. It was open to anybody on the LAN, which made a new
    // gateway on a shared network anybody's to take.
    //
    // An offline bundle is open: it is Pulzar Cloud's signature over this
    // gateway's EUI, which nobody gets without having adopted it already.
    // It stops working the moment the gateway is adopted (PROVISIONING_ONLY).
    'POST /api/claim/apply': true,

    // Open for the same reason, and for the opposite state. The recovery
    // screen is reached without a session — that is the whole point of it —
    // and a gateway that was decommissioned needs to be able to say so from
    // there. Asking is all a caller can do: pulzr-adopt decides, from an
    // answer only Pulzar Cloud can give, and a wrong one costs a return to
    // local management rather than access to anything.
    'POST /api/claim/check-adoption': true,
    'GET  /api/claim/check-adoption': true,
};

// The claim routes answer only while the gateway is unadopted. Once it belongs
// to an organisation there is no claim to show.
const PROVISIONING_ONLY = {
    'GET  /api/claim/status': true,
    'GET  /api/claim/qr': true,
    'POST /api/claim/poll': true,
    'POST /api/claim/apply': true,
};

// Again while a claim waits to replace a revoked one, for the owner to scan
// (signed in, as the owner is, by Pulzar). Not `apply`: an offline bundle
// carries no claim, and this gateway is adopted.
const RECLAIM_OPEN = {
    'GET  /api/claim/status': true,
    'GET  /api/claim/qr': true,
    'POST /api/claim/poll': true,
};

// ── helpers ─────────────────────────────────────────────────────────────────

function respond(status, body, headers) {
    const out = {
        status: status,
        headers: {
            'Content-Type': 'application/json',
            // The console is a same-origin SPA; nothing should be embedding it
            // or sniffing its content type into something executable.
            'X-Content-Type-Options': 'nosniff',
            'X-Frame-Options': 'DENY',
            'Referrer-Policy': 'no-referrer',
            'Cache-Control': 'no-store',
        },
        body: sprintf('%J', body),
    };
    for (let k in (headers ? headers : {})) out.headers[k] = headers[k];
    return out;
}

function error(status, message) {
    return respond(status, { error: message });
}

function cookies(env) {
    const header = env.headers ? env.headers.cookie : null;
    const jar = {};
    if (!header) return jar;
    for (let pair in split(header, ';')) {
        const eq = index(pair, '=');
        if (eq < 0) continue;
        jar[trim(substr(pair, 0, eq))] = trim(substr(pair, eq + 1));
    }
    return jar;
}

function sessionCookie(token, maxAge) {
    // HttpOnly so a script cannot read it; Secure because the console is
    // served over TLS with the device's own certificate; SameSite=Strict so a
    // page on another origin cannot ride the session. Path=/ because the SPA
    // and the API share an origin.
    return sprintf('%s=%s; Path=/; Max-Age=%d; HttpOnly; Secure; SameSite=Strict',
                   SESSION_COOKIE, token, maxAge);
}

// The request body.
//
// env.content_length / env.content do not exist — that was written against an
// API uhttpd's ucode plugin does not have, so every POST arrived as an empty
// object and every login failed with "Incorrect username or password" no
// matter what was typed. The real interface is CGI-shaped: the length is in
// CONTENT_LENGTH, and the bytes are pulled with uhttpd.recv().
//
// recv() returns what is available, not necessarily everything, so this loops
// until it has the declared length or the client stops sending.
const MAX_BODY = 64 * 1024;

function body(env) {
    const len = int(env.CONTENT_LENGTH ?? 0);
    if (len <= 0) return {};

    // Nothing this API accepts is anywhere near this large. A cap matters
    // because the alternative is letting an unauthenticated caller decide how
    // much memory a 64MB gateway allocates.
    if (len > MAX_BODY) return {};

    let raw = '';
    while (length(raw) < len) {
        const chunk = uhttpd.recv(len - length(raw));
        if (chunk == null || !length(chunk)) break;
        raw += chunk;
    }

    try {
        const parsed = json(raw);
        return type(parsed) == 'object' ? parsed : {};
    }
    catch (e) { return {}; }
}

function clientAddr(env) {
    // uhttpd gives us the peer address. There is no reverse proxy in front of
    // the console on the device itself, so REMOTE_ADDR is trustworthy here and
    // X-Forwarded-For deliberately is not consulted — honouring a header the
    // client controls would let anyone reset their own lockout counter by
    // changing it.
    return env.REMOTE_ADDR ? env.REMOTE_ADDR : 'unknown';
}

// A Thread change (lib/thread.uc), audited by what was done, never with the
// request: a form, a join or a permit carries a secret.
function threadPost(op) {
    return (env, req, s) => {
        const result = thread.change(op, req, s);
        if (result.error) return error(result.status, result.error);
        auth.audit(sprintf('system.thread.%s', op), { by: s.subject });
        return respond(200, result.result);
    };
}

// A radio network change (lib/radio.uc), audited by what was done and on which
// radio, never with the request: a form, a restore, a provision or a PIN
// carries a secret.
function radioPost(op) {
    return (env, req, s) => {
        const result = radio.change(op, req, s);
        if (result.error) return error(result.status, result.error);
        auth.audit(sprintf('system.radio.%s', op), { by: s.subject, radio: req.radio });
        return respond(200, result.result);
    };
}

// ── routing ─────────────────────────────────────────────────────────────────

const ROUTES = {
    'GET  /api/health': () => respond(200, { ok: true }),

    'GET  /api/auth/methods': (env) => respond(200, auth.loginMethods(env.SERVER_ADDR)),

    'POST /api/auth/login': (env, req) => {
        const result = auth.loginLocal(req.username, req.password, clientAddr(env));
        if (result.error) return error(result.status, result.error);
        return respond(200, {
            subject: result.session.subject,
            kind: result.session.kind,
            csrf: result.session.csrf,
            mustChangePassword: !!result.session.mustChangePassword,
        }, { 'Set-Cookie': sessionCookie(result.session.token, 3600) });
    },

    'POST /api/auth/sso': (env, req) => {
        const result = auth.loginSso(req.token, clientAddr(env));
        if (result.error) return error(result.status, result.error);
        return respond(200, {
            subject: result.session.subject,
            kind: result.session.kind,
            csrf: result.session.csrf,
        }, { 'Set-Cookie': sessionCookie(result.session.token, 3600) });
    },

    'POST /api/auth/ticket': (env, req) => {
        const result = auth.loginTicket(req.ticket, clientAddr(env));
        if (result.error) return error(result.status, result.error);
        const ttl = result.session.expires - time();
        return respond(200, {
            subject: result.session.subject,
            kind: result.session.kind,
            csrf: result.session.csrf,
            expiresIn: ttl,
        }, { 'Set-Cookie': sessionCookie(result.session.token, ttl) });
    },

    'POST /api/auth/recovery/challenge': () => {
        const result = auth.recoveryChallenge();
        if (result.error) return error(result.status, result.error);
        return respond(200, result);
    },

    'POST /api/auth/recovery/verify': (env, req) => {
        const result = auth.recoveryVerify(req.signature, clientAddr(env));
        if (result.error) return error(result.status, result.error);
        return respond(200, {
            subject: result.session.subject,
            kind: result.session.kind,
            csrf: result.session.csrf,
            // The UI banners recovery sessions differently and counts down to
            // their expiry, because a recovery session is an exceptional state
            // and should not feel like a normal login.
            expiresIn: result.session.expires - time(),
        }, { 'Set-Cookie': sessionCookie(result.session.token, 1800) });
    },

    'POST /api/auth/logout': (env, req, session, token) => {
        auth.destroySession(token);
        return respond(200, { ok: true },
                       { 'Set-Cookie': sessionCookie('', 0) });
    },

    'GET  /api/auth/session': (env, req, session) => respond(200, {
        subject: session.subject,
        kind: session.kind,
        csrf: session.csrf,
        expiresIn: session.expires - time(),
    }),

    'POST /api/auth/password': (env, req, session) => {
        // A recovery session may set a password — that is much of the point of
        // recovering — but must re-state the old one if one is set, so that a
        // recovery code alone is not a silent takeover of the local account.
        const result = actions.setPassword(req, session);
        if (result.error) return error(result.status, result.error);
        return respond(200, result);
    },

    // ── system ──────────────────────────────────────────────────────────────
    'GET  /api/system/summary':   () => respond(200, system.summary()),
    'GET  /api/system/features':  () => respond(200, { features: system.features() }),
    'GET  /api/system/stats':     () => respond(200, system.stats()),
    'GET  /api/system/history':   (env) => respond(200, system.history(env.QUERY_STRING)),
    'GET  /api/system/processes': () => respond(200, system.processes()),
    'GET  /api/system/logs':      (env, req) => respond(200, system.logs(env.QUERY_STRING)),
    'POST /api/system/reboot':    (env, req, s) => respond(200, actions.reboot(req, s)),
    'GET  /api/system/uart':      () => respond(200, system.uart()),
    'POST /api/system/uart':      (env, req, s) => {
        const result = actions.setUart(req, s);
        if (result.error) return error(400, result.error);
        return respond(200, result);
    },
    'POST /api/system/firmware':  (env, req, s) => {
        auth.audit('system.firmware.upload', { by: s.subject, bytes: int(env.CONTENT_LENGTH ?? 0) });
        const result = firmware.upload(env, s.subject, !!s.shell);
        if (result.error) return error(result.status, result.error);
        auth.audit('system.firmware.apply', { by: s.subject, bytes: result.bytes });
        return respond(202, result);
    },

    // ── add-ons, see lib/addons.uc ──────────────────────────────────────────
    //
    // Read by anybody signed in; changed only by Pulzar Net (an sso session).
    // Like every POST here, these need the CSRF header.
    'GET  /api/system/addons':    () => respond(200, addons.status()),
    'POST /api/system/addons':    (env, req, s) => {
        const result = addons.request(req, s);
        if (result.error) return error(result.status, result.error);
        auth.audit(sprintf('system.addon.%s', result.action), { by: s.subject, name: result.name });
        return respond(202, { ok: true, name: result.name, action: result.action, purge: result.purge });
    },
    'POST /api/system/addons/deny': (env, req, s) => {
        const result = addons.deny(req, s);
        if (result.error) return error(result.status, result.error);
        auth.audit('system.addon.deny', { by: s.subject, deny: req.deny, reason: req.reason ?? '' });
        return respond(200, { deny: result.deny });
    },

    // ── Thread, see lib/thread.uc ───────────────────────────────────────────
    //
    // Read by anybody signed in; changed only by Pulzar Net (an sso session).
    'GET  /api/system/thread': () => {
        const result = thread.status();
        return result.error ? error(result.status ?? 409, result.error) : respond(200, result);
    },
    'POST /api/system/thread/use':         threadPost('use'),
    'POST /api/system/thread/release':     threadPost('release'),
    'POST /api/system/thread/scan':        threadPost('scan'),
    'POST /api/system/thread/form':        threadPost('form'),
    'POST /api/system/thread/join':        threadPost('join'),
    'POST /api/system/thread/leave':       threadPost('leave'),
    'POST /api/system/thread/permit':      threadPost('permit'),
    'POST /api/system/thread/permit-stop': threadPost('permit-stop'),
    'POST /api/system/thread/dataset':     threadPost('dataset'),

    // ── radio networks, see lib/radio.uc ────────────────────────────────────
    //
    // Read by anybody signed in; changed only by Pulzar Net (an sso session).
    'GET  /api/system/radio': () => respond(200, radio.status()),
    'POST /api/system/radio/use':          radioPost('use'),
    'POST /api/system/radio/release':      radioPost('release'),
    'POST /api/system/radio/scan':         radioPost('scan'),
    'POST /api/system/radio/form':         radioPost('form'),
    'POST /api/system/radio/restore':      radioPost('restore'),
    'POST /api/system/radio/backup':       radioPost('backup'),
    'POST /api/system/radio/leave':        radioPost('leave'),
    'POST /api/system/radio/permit':       radioPost('permit'),
    'POST /api/system/radio/permit-stop':  radioPost('permit-stop'),
    'POST /api/system/radio/provision':    radioPost('provision'),
    'POST /api/system/radio/grant':        radioPost('grant'),
    'POST /api/system/radio/dsk':          radioPost('dsk'),
    'POST /api/system/radio/abort':        radioPost('abort'),
    'POST /api/system/radio/remove':       radioPost('remove'),
    'POST /api/system/radio/replace':      radioPost('replace'),
    'POST /api/system/radio/channel':      radioPost('channel'),
    'POST /api/system/radio/map':          radioPost('map'),
    'POST /api/system/radio/region':       radioPost('region'),

    // ── network ─────────────────────────────────────────────────────────────
    'GET  /api/bluetooth/status': () => respond(200, bluetooth.status()),
    'POST /api/bluetooth':        (env, req, s) => {
        const result = actions.setBluetooth(req, s);
        if (result.error) return error(400, result.error);
        return respond(200, result);
    },
    'GET  /api/network/status':   () => respond(200, network.status()),
    'GET  /api/network/backhaul': () => respond(200, network.backhaul()),
    // Every network setter below that can cut off whoever makes it is armed
    // with a rollback window (apply.guard) and answers with `pending`; the
    // caller confirms through /api/apply/confirm once it reaches the gateway
    // again. Re-attaching with a new APN can take a minute, so cellular
    // gets longer than the rest.
    'POST /api/network/cellular': (env, req, s) => {
        const result = apply.guard(CELLULAR_WINDOW, s, () => actions.setCellular(req, s));
        return result.error ? error(409, result.error) : respond(200, result);
    },

    // ── apply: the rollback window, see lib/apply.uc ────────────────────────
    'GET  /api/apply/status':     () => respond(200, apply.status()),
    'POST /api/apply/confirm':    (env, req, s) => {
        const result = apply.confirm();
        return result.error ? error(409, result.error) : respond(200, result);
    },
    'POST /api/apply/revert':     (env, req, s) => {
        const result = apply.revert();
        return result.error ? error(409, result.error) : respond(200, result);
    },

    // ── ports: roles, VLANs and each uplink's addressing, see lib/ports.uc ──
    //
    // A change is undone unless `confirm` follows within its window: the
    // page confirms once it reaches the gateway again afterwards.
    'GET  /api/ports/status':     () => respond(200, ports.status()),
    'POST /api/ports':            (env, req, s) => {
        const result = actions.setPorts(req, s);
        return result.error ? error(400, result.error) : respond(200, result);
    },
    'POST /api/ports/addressing': (env, req, s) => {
        const result = actions.setUplinkAddressing(req, s);
        return result.error ? error(400, result.error) : respond(200, result);
    },
    'POST /api/ports/confirm':    (env, req, s) => {
        const result = actions.confirmPorts(req, s);
        return result.error ? error(409, result.error) : respond(200, result);
    },
    'POST /api/ports/revert':     (env, req, s) => {
        const result = actions.revertPorts(req, s);
        return result.error ? error(409, result.error) : respond(200, result);
    },

    // ── provisioning ────────────────────────────────────────────────────────
    'GET  /api/claim/status': () => respond(200, claim.status()),
    'GET  /api/claim/qr':     () => respond(200, claim.qr()),
    'POST /api/claim/poll':   (env, req) => respond(200, actions.claimPoll(req)),
    'POST /api/claim/check-adoption': (env, req) => respond(200, actions.checkAdoption(req)),
    'GET  /api/claim/check-adoption': () => respond(200, claim.adoptionCheckResult()),
    'POST /api/claim/apply':  (env, req) => {
        const result = actions.claimApply(req);
        return result.error ? error(400, result.error) : respond(200, result);
    },

    // ── access: the setup AP, the portal, LAN DHCP ──────────────────────────
    //
    // `status` is the only readable one without a session, and it is in the
    // PUBLIC table below for the captive portal's benefit. Everything that
    // changes anything requires a session — which on an adopted gateway means
    // the offline recovery signature, since local login is off.
    'GET  /api/access/status':    () => respond(200, access.status()),
    'GET  /api/access/key':       (env, req, s) => respond(200, access.key()),
    'GET  /api/access/scan':      (env, req, s) => respond(200, access.scan()),
    'POST /api/access/ap':        (env, req, s) => {
        const result = actions.setAp(req, s);
        return result.error ? error(400, result.error) : respond(200, result);
    },
    'POST /api/access/ap/up':     (env, req, s) => respond(200, actions.raiseAp(req, s)),
    'POST /api/access/ap/down':   (env, req, s) => respond(200, actions.lowerAp(req, s)),
    'POST /api/access/wifi/forget': (env, req, s) => {
        const result = apply.guard(APPLY_WINDOW, s, () => actions.forgetWifi(req, s));
        return result.error ? error(409, result.error) : respond(200, result);
    },
    'POST /api/access/wifi':      (env, req, s) => {
        const result = apply.guard(APPLY_WINDOW, s, () => actions.joinWifi(req, s));
        if (result.error) return error(400, result.error);
        return respond(200, result);
    },
    'GET  /api/access/wifi':      (env, req, s) => respond(200, access.wifiDetail()),
    'POST /api/access/wifi/probe': (env, req, s) => {
        const result = actions.probeWifi(req, s);
        if (result.error) return error(400, result.error);
        return respond(202, result);
    },
    'GET  /api/access/wifi/probe': (env, req, s) => respond(200, access.probeResult()),
    'POST /api/access/wifi/check': (env, req, s) => {
        const result = actions.checkWifi(req, s);
        if (result.error) return error(409, result.error);
        return respond(202, result);
    },
    'POST /api/access/wifi/signin': (env, req, s) => {
        const result = actions.startSignin(req, s, clientAddr(env));
        if (result.error) return error(409, result.error);
        return respond(200, result);
    },

    // ── radios: what each WiFi radio runs, see lib/radios.uc ───────────────
    //
    // Every change goes through the rollback window: a channel change drops
    // the clients of that radio, and the uplink on the wrong radio is the
    // tunnel gone. The uplink's join is access.joinWifi's, with its radio
    // chosen and, for a repeater, an access point written with it.
    'GET  /api/radios':           () => respond(200, radios.status()),
    'POST /api/radios/radio':     (env, req, s) => {
        const result = apply.guard(APPLY_WINDOW, s, () => actions.setRadio(req, s));
        return result.error ? error(400, result.error) : respond(200, result);
    },
    'POST /api/radios/ap':        (env, req, s) => {
        const result = apply.guard(APPLY_WINDOW, s, () => actions.setRadioAp(req, s));
        return result.error ? error(400, result.error) : respond(200, result);
    },
    'POST /api/radios/ap/remove': (env, req, s) => {
        const result = apply.guard(APPLY_WINDOW, s, () => actions.removeRadioAp(req, s));
        return result.error ? error(400, result.error) : respond(200, result);
    },
    'POST /api/radios/uplink':    (env, req, s) => {
        const result = apply.guard(APPLY_WINDOW, s, () => actions.joinRadioUplink(req, s));
        return result.error ? error(400, result.error) : respond(200, result);
    },

    // ── lan: the devlan zone; no tunnel forwards, see lib/lan.uc ───────────
    'GET  /api/lan/status':  () => respond(200, lan.status()),
    'POST /api/lan/cellular': (env, req, s) => {
        const result = actions.setLanCellular(req, s);
        return result.error ? error(400, result.error) : respond(200, result);
    },
    'POST /api/lan/expose':  (env, req, s) => {
        const result = actions.setLanExpose(req, s);
        return result.error ? error(400, result.error) : respond(200, result);
    },
    'POST /api/lan/policy':  (env, req, s) => {
        const result = actions.setLanPolicy(req, s);
        return result.error ? error(400, result.error) : respond(200, result);
    },
    'POST /api/lan/reserve': (env, req, s) => {
        const result = actions.setLanReserve(req, s);
        return result.error ? error(400, result.error) : respond(200, result);
    },

    // ── dns: the resolver, see lib/dns.uc ───────────────────────────────────
    'GET  /api/dns/status':    () => respond(200, dns.status()),
    'POST /api/dns/upstream':  (env, req, s) => {
        const result = apply.guard(APPLY_WINDOW, s, () => actions.setDnsUpstream(req, s));
        return result.error ? error(400, result.error) : respond(200, result);
    },
    'POST /api/dns/host':      (env, req, s) => {
        const result = actions.setDnsHost(req, s);
        return result.error ? error(400, result.error) : respond(200, result);
    },
    'POST /api/dns/rebind':    (env, req, s) => {
        const result = actions.setDnsRebind(req, s);
        return result.error ? error(400, result.error) : respond(200, result);
    },
    'POST /api/dns/ddns':      (env, req, s) => {
        const result = actions.setDnsDdns(req, s);
        return result.error ? error(400, result.error) : respond(200, result);
    },

    // ── uplinks: order and failover, see lib/uplinks.uc ─────────────────────
    'GET  /api/uplinks/status':   () => respond(200, uplinks.status()),
    'POST /api/uplinks/order':    (env, req, s) => {
        const result = apply.guard(APPLY_WINDOW, s, () => actions.setUplinkOrder(req, s));
        return result.error ? error(400, result.error) : respond(200, result);
    },
    'POST /api/uplinks/track':    (env, req, s) => {
        const result = apply.guard(APPLY_WINDOW, s, () => actions.setUplinkTrack(req, s));
        return result.error ? error(400, result.error) : respond(200, result);
    },
    'POST /api/uplinks/tracking': (env, req, s) => {
        const result = apply.guard(APPLY_WINDOW, s, () => actions.setUplinkTracking(req, s));
        return result.error ? error(400, result.error) : respond(200, result);
    },

    // ── speed tests, see lib/speedtest.uc ──────────────────────────────────
    'GET  /api/speedtest/status':   () => respond(200, speedtest.status()),
    'POST /api/speedtest/run':      (env, req, s) => {
        const result = actions.startSpeedtest(req, s);
        return result.error ? error(409, result.error) : respond(202, result);
    },
    'POST /api/speedtest/schedule': (env, req, s) => {
        const result = actions.setSpeedtestSchedule(req, s);
        return result.error ? error(400, result.error) : respond(200, result);
    },

    // ── io ──────────────────────────────────────────────────────────────────
    'GET  /api/io/status': () => respond(200, io.status()),
    'POST /api/io/test':   (env, req, s) => respond(200, actions.ioTest(req, s)),

    // ── lorawan ─────────────────────────────────────────────────────────────
    'GET  /api/lorawan/status':       () => respond(200, lorawan.status()),
    'GET  /api/lorawan/concentrator': () => respond(200, lorawan.concentrator()),
    'POST /api/lorawan/concentrator': (env, req, s) => respond(200, actions.setConcentrator(req, s)),
    'POST /api/lorawan/detect':       (env, req, s) => respond(200, actions.detect(req, s)),

    'GET  /api/lorawan/forwarders': () => respond(200, lorawan.forwarders()),

    // ── gnss ────────────────────────────────────────────────────────────────
    'GET  /api/gnss':        () => respond(200, lorawan.gps()),
    'POST /api/gnss/source': (env, req, s) => {
        const result = actions.setGpsSource(req, s);
        if (result.error) return error(400, result.error);
        return respond(200, result);
    },
    'POST /api/gnss/detect': (env, req, s) => respond(200, actions.detectGps(req, s)),
    'POST /api/gnss/sync':   (env, req, s) => {
        const result = actions.syncGps(req, s);
        if (result.error) return error(409, result.error);
        return respond(200, result);
    },
    'POST /api/lorawan/backhaul':     (env, req, s) => respond(200, actions.setBackhaul(req, s)),
    'POST /api/lorawan/restart':      (env, req, s) => respond(200, actions.restart(req, s)),
};

// Routes whose body is not JSON but the payload itself — read by the handler,
// in chunks, after authentication. Everything else goes through body(), which
// runs before the session check and is capped at 64KB on purpose.
const STREAMED = {
    'POST /api/system/firmware': true,
};

// Endpoints that belong to a feature, by path prefix. On a board without the
// feature they answer 404: the scripts behind them are not in its image, and
// a 500 from a missing binary reads as a fault rather than as absent.
const FEATURE_PREFIXES = [
    ['/api/lorawan/',          'lorawan'],
    ['/api/gnss',              'gnss'],
    ['/api/bluetooth',         'bluetooth'],
    ['/api/network/cellular',  'cellular'],
    ['/api/access/wifi',       'wifi'],
    ['/api/access/scan',       'wifi'],
    ['/api/access/ap',         'wifi'],
    ['/api/access/key',        'wifi'],
    ['/api/radios',            'wifi'],
    ['/api/lan/',              'lan'],
    ['/api/dns/',              'dns'],
    ['/api/uplinks/',          'failover'],
    ['/api/speedtest/',        'speedtest'],
];

function featureOf(path) {
    for (let entry in FEATURE_PREFIXES)
        if (substr(path, 0, length(entry[0])) == entry[0]) return entry[1];
    return null;
}

// Normalised so 'GET  /api/x' in the tables above matches a real request
// regardless of how many spaces the table used to line its columns up.
function routeKey(method, path) {
    return sprintf('%-4s %s', method, path);
}

// The tunnel's plain-HTTP console (8080, see 30-pulzr-console) answers the
// hub and nothing else. The firewall opens 8080 only on wg0, and WireGuard
// admits only the hub's address there; this still holds if either is changed.
// Without it, one rule opening 8080 on a LAN would put the sign-in on that
// LAN in clear text.
function fromHub(env) {
    if (env.SERVER_PORT != '8080') return true;
    let tunnel = null;
    try { tunnel = json(readfile('/etc/pulzr/wireguard/tunnel.json') ?? 'null'); } catch (e) { }
    return !!(tunnel && tunnel.hubAddress && env.REMOTE_ADDR == tunnel.hubAddress);
}

// ── the tunnel's speed, measured from Pulzar Cloud's end ──────────────────────
//
// the cloud takes bytes from `source` and sends them to `sink` over the
// WireGuard tunnel, and times both (pulzr-speedtest's tunnel test). On the
// tunnel port only, so only the hub ever reaches them (fromHub), and without
// a session: they answer with nothing but filler and a byte count. Capped, so
// a caller cannot hold the uplink for longer than a test.
const TUNNEL_MAX_BYTES = 268435456;
let tunnelChunk = null;

function tunnelSource(env) {
    const m = match(env.QUERY_STRING ?? '', /(^|&)bytes=([0-9]{1,10})(&|$)/);
    let bytes = m ? int(m[2]) : 0;
    if (bytes < 1 || bytes > TUNNEL_MAX_BYTES) return error(400, 'bytes is 1 to 268435456.');
    if (!tunnelChunk) {
        tunnelChunk = 'x';
        while (length(tunnelChunk) < 65536) tunnelChunk += tunnelChunk;
    }
    uhttpd.send(sprintf('Status: 200 OK\r\nContent-Type: application/octet-stream\r\n' +
                        'Cache-Control: no-store\r\nContent-Length: %d\r\n\r\n', bytes));
    while (bytes > 0) {
        const n = bytes < 65536 ? bytes : 65536;
        // false once the far end has gone: the cloud closes when its
        // time is up, well before the byte count runs out.
        if (uhttpd.send(n == 65536 ? tunnelChunk : substr(tunnelChunk, 0, n)) === false) break;
        bytes -= n;
    }
    return { streamed: true };
}

function tunnelSink(env) {
    const len = int(env.CONTENT_LENGTH ?? 0);
    if (len < 1 || len > TUNNEL_MAX_BYTES) return error(400, 'A body of 1 to 268435456 bytes.');
    const started = clock();
    let received = 0;
    while (received < len) {
        const chunk = uhttpd.recv(len - received < 65536 ? len - received : 65536);
        if (chunk == null || !length(chunk)) break;
        received += length(chunk);
    }
    const t = clock();
    return respond(200, { received, seconds: (t[0] - started[0]) + (t[1] - started[1]) / 1e9 });
}

function route(env) {
    if (!fromHub(env)) return respond(403, { error: 'Not from the management hub.' });
    if (env.SERVER_PORT == '8080' && 'speedtest' in system.features()) {
        const tpath = (env.SCRIPT_NAME ?? '') + (env.PATH_INFO ?? '/');
        if (env.REQUEST_METHOD == 'GET' && tpath == '/api/speedtest/tunnel/source') return tunnelSource(env);
        if (env.REQUEST_METHOD == 'POST' && tpath == '/api/speedtest/tunnel/sink') return tunnelSink(env);
    }
    const method = env.REQUEST_METHOD;
    // SCRIPT_NAME + PATH_INFO, not PATH_INFO alone. uhttpd mounts this handler
    // at a prefix and strips it: a request for /api/auth/methods arrives with
    // SCRIPT_NAME=/api and PATH_INFO=/auth/methods. The route table is written
    // in full paths, which is what anyone reading it expects, so the prefix is
    // put back here rather than stripped from forty table entries.
    const path = (env.SCRIPT_NAME ?? '') + (env.PATH_INFO ?? '/');
    const key = routeKey(method, path);

    let handler = ROUTES[key];

    // One parameterised route: /api/lorawan/slots/<n>. Matched here rather
    // than by giving the whole router a pattern matcher, because it is the
    // only one and a regex table for a single case is worse than this.
    let slotIndex = null;
    if (!handler && method == 'POST') {
        const m = match(path, /^\/api\/lorawan\/slots\/([0-9]{1,2})$/);
        if (m) {
            slotIndex = int(m[1]);
            handler = (e, r, s) => { r.index = slotIndex; return respond(200, actions.setSlot(r, s)); };
        }
    }

    if (!handler) return error(404, 'No such endpoint.');

    const feature = featureOf(path);
    if (feature && !(feature in system.features()))
        return error(404, 'Not on this board.');

    // Provisioning endpoints exist only until the gateway belongs to somebody.
    if (PROVISIONING_ONLY[key] && claim.isAdopted()
            && !(RECLAIM_OPEN[key] && claim.reclaiming()))
        return error(404, 'This gateway is already adopted.');

    // Not for a streamed route: its body is the payload, and must not be read
    // here — before authentication — at all.
    const req = STREAMED[key] ? {} :
        ((method == 'POST' || method == 'PUT') ? body(env) : {});

    if (PUBLIC[key])
        return handler(env, req, null, null);

    // ParkezeOS's cookie name is read too, so a platform or browser that
    // still sends parkeze_session keeps its session across the rename.
    const jar = cookies(env);
    const token = jar[SESSION_COOKIE] ?? jar['parkeze_session'];
    const session = auth.readSession(token);
    if (!session)
        return error(401, 'Not signed in.');

    // CSRF: any state-changing request must echo the session's CSRF token in a
    // header. A cross-origin page can cause the cookie to be sent but cannot
    // read the token to echo it.
    if (method != 'GET') {
        const sent = env.headers ? (env.headers['x-pulzr-csrf'] ?? env.headers['x-parkeze-csrf']) : null;
        if (!auth.constantTimeEqual(sent ? sent : '', session.csrf))
            return error(403, 'Missing or invalid CSRF token.');
    }

    return handler(env, req, session, token);
}

// ── the uhttpd entry point ──────────────────────────────────────────────────
//
// route() builds the {status, headers, body} object every handler returns;
// this turns that into bytes and hands them to uhttpd. Kept separate so the
// route table stays about routing and the transport detail lives in one place.
// String keys: ucode object literals take identifiers or quoted strings, not
// bare integers, and lookups are by string too.
const STATUS_TEXT = {
	'200': 'OK', '201': 'Created', '202': 'Accepted', '204': 'No Content',
	'301': 'Moved Permanently', '302': 'Found', '304': 'Not Modified',
	'400': 'Bad Request', '401': 'Unauthorized', '403': 'Forbidden',
	'404': 'Not Found', '405': 'Method Not Allowed', '409': 'Conflict',
	'413': 'Payload Too Large', '429': 'Too Many Requests',
	'500': 'Internal Server Error', '503': 'Service Unavailable',
};

handle_request = function(env) {
	let r;

	// A ucode exception inside a handler would otherwise take the whole
	// response with it and uhttpd would close the connection with nothing
	// written, which looks identical to the server being down. Answer 500 and
	// keep the detail out of the body.
	try {
		r = route(env);
		// Already written to the client: the tunnel test's source.
		if (r?.streamed) return;
	}
	catch (e) {
		warn(sprintf('pulzr-console: %s\n%s\n', e.message ?? e, e.stacktrace ?? ''));
		r = { status: 500,
		      headers: { 'Content-Type': 'application/json' },
		      body: '{"error":"Internal error."}' };
	}

	let out = sprintf('Status: %d %s\r\n', r.status, STATUS_TEXT[sprintf('%d', r.status)] ?? 'OK');
	for (let k in (r.headers ?? {}))
		out += sprintf('%s: %s\r\n', k, r.headers[k]);

	// Explicit length: without it uhttpd has to close the connection to signal
	// the end of the body, which costs a round trip on every request the SPA
	// makes.
	const body = r.body ?? '';
	out += sprintf('Content-Length: %d\r\n\r\n%s', length(body), body);

	uhttpd.send(out);
};
%}
