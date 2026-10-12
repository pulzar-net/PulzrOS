{%
// The Parkeze console API.
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
let auth = loadfile('/usr/share/parkeze/console/lib/auth.uc', { raw_mode: true })();
let system = loadfile('/usr/share/parkeze/console/lib/system.uc', { raw_mode: true })();
let network = loadfile('/usr/share/parkeze/console/lib/network.uc', { raw_mode: true })();
let lorawan = loadfile('/usr/share/parkeze/console/lib/lorawan.uc', { raw_mode: true })();
let claim = loadfile('/usr/share/parkeze/console/lib/claim.uc', { raw_mode: true })();
let io = loadfile('/usr/share/parkeze/console/lib/io.uc', { raw_mode: true })();
let access = loadfile('/usr/share/parkeze/console/lib/access.uc', { raw_mode: true })();
let firmware = loadfile('/usr/share/parkeze/console/lib/firmware.uc', { raw_mode: true })();
let bluetooth = loadfile('/usr/share/parkeze/console/lib/bluetooth.uc', { raw_mode: true })();

const SESSION_COOKIE = 'parkeze_session';

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

    // ── one-touch provisioning ──────────────────────────────────────────
    //
    // Reachable without a session, and that is the point rather than an
    // oversight: a gateway out of the box has a password nobody has read off
    // the serial console yet, and requiring a login before it can be claimed
    // would defeat the whole flow. Somebody who can reach this is on the
    // gateway's LAN, and all they can learn is a claim code that is worthless
    // without a Parkeze account to bind it to.
    //
    // Everything here stops working the moment the gateway is adopted — see
    // the guard in handle_request.
    'GET  /api/claim/status': true,
    'GET  /api/claim/qr': true,
    'POST /api/claim/poll': true,
    'POST /api/claim/apply': true,

    // Open for the same reason, and for the opposite state. The recovery
    // screen is reached without a session — that is the whole point of it —
    // and a gateway that was decommissioned needs to be able to say so from
    // there. Asking is all a caller can do: parkeze-adopt decides, from an
    // answer only parkeze.net can give, and a wrong one costs a return to
    // local management rather than access to anything.
    'POST /api/claim/check-adoption': true,
    'GET  /api/claim/check-adoption': true,
};

// The provisioning routes above are open only while there is nothing to
// protect. Once a gateway belongs to an organisation, its claim state is
// somebody's business and not the public's.
const PROVISIONING_ONLY = {
    'GET  /api/claim/status': true,
    'GET  /api/claim/qr': true,
    'POST /api/claim/poll': true,
    'POST /api/claim/apply': true,
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

// ── routing ─────────────────────────────────────────────────────────────────

const ROUTES = {
    'GET  /api/health': () => respond(200, { ok: true }),

    'GET  /api/auth/methods': () => respond(200, auth.loginMethods()),

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
        const result = auth.setPassword(req.username, req.password);
        if (result.error) return error(result.status, result.error);
        return respond(200, result);
    },

    // ── system ──────────────────────────────────────────────────────────────
    'GET  /api/system/summary':   () => respond(200, system.summary()),
    'GET  /api/system/stats':     () => respond(200, system.stats()),
    'GET  /api/system/history':   (env) => respond(200, system.history(env.QUERY_STRING)),
    'GET  /api/system/processes': () => respond(200, system.processes()),
    'GET  /api/system/logs':      (env, req) => respond(200, system.logs(env.QUERY_STRING)),
    'POST /api/system/reboot':    (env, req, s) => { auth.audit('system.reboot', { by: s.subject }); return respond(200, system.reboot()); },
    'GET  /api/system/uart':      () => respond(200, system.uart()),
    'POST /api/system/uart':      (env, req, s) => {
        const result = system.setUart(req.role);
        if (result.error) return error(400, result.error);
        auth.audit('system.uart', { by: s.subject, role: req.role });
        return respond(200, result);
    },
    'POST /api/system/firmware':  (env, req, s) => {
        auth.audit('system.firmware.upload', { by: s.subject, bytes: int(env.CONTENT_LENGTH ?? 0) });
        const result = firmware.upload(env, s.subject);
        if (result.error) return error(result.status, result.error);
        auth.audit('system.firmware.apply', { by: s.subject, bytes: result.bytes });
        return respond(202, result);
    },

    // ── network ─────────────────────────────────────────────────────────────
    'GET  /api/bluetooth/status': () => respond(200, bluetooth.status()),
    'POST /api/bluetooth':        (env, req, s) => {
        const result = bluetooth.set(req);
        if (result.error) return error(400, result.error);
        auth.audit('bluetooth.set', { by: s.subject, enabled: req.enabled });
        return respond(200, result);
    },
    'GET  /api/network/status':   () => respond(200, network.status()),
    'GET  /api/network/backhaul': () => respond(200, network.backhaul()),
    'POST /api/network/cellular': (env, req, s) => respond(200, network.setCellular(req, s)),
    'POST /api/network/ethernet': (env, req, s) => {
        const result = network.setEthernet(req, s);
        if (result.error) return error(400, result.error);
        auth.audit('network.ethernet', { by: s.subject, mode: req.mode,
                                         address: req.address, gateway: req.gateway });
        return respond(200, result);
    },

    // ── provisioning ────────────────────────────────────────────────────────
    'GET  /api/claim/status': () => respond(200, claim.status()),
    'GET  /api/claim/qr':     () => respond(200, claim.qr()),
    'POST /api/claim/poll':   () => respond(200, claim.poll()),
    'POST /api/claim/check-adoption': () => respond(200, claim.checkAdoption()),
    'GET  /api/claim/check-adoption': () => respond(200, claim.adoptionCheckResult()),
    'POST /api/claim/apply':  (env, req) => {
        const result = claim.applyBundle(req);
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
        const result = access.setAp(req);
        return result.error ? error(400, result.error) : respond(200, result);
    },
    'POST /api/access/ap/up':     (env, req, s) => { auth.audit('ap.raise', { by: s.subject }); return respond(200, access.raiseAp(req)); },
    'POST /api/access/ap/down':   (env, req, s) => { auth.audit('ap.lower', { by: s.subject }); return respond(200, access.lowerAp()); },
    'POST /api/access/wifi/forget': (env, req, s) => {
        auth.audit('wifi.forget', { by: s.subject, ssid: req.ssid });
        return respond(200, access.forgetWifi(req));
    },
    'POST /api/access/wifi':      (env, req, s) => {
        const result = access.joinWifi(req);
        if (result.error) return error(400, result.error);
        auth.audit('wifi.join', { by: s.subject, ssid: req.ssid,
                                  security: req.eap ? 'eap' : (req.key ? 'psk' : 'open') });
        return respond(200, result);
    },
    'GET  /api/access/wifi':      (env, req, s) => respond(200, access.wifiDetail()),
    'POST /api/access/wifi/probe': (env, req, s) => {
        const result = access.probeWifi(req);
        if (result.error) return error(400, result.error);
        auth.audit('wifi.probe', { by: s.subject, ssid: req.ssid });
        return respond(202, result);
    },
    'GET  /api/access/wifi/probe': (env, req, s) => respond(200, access.probeResult()),

    // ── io ──────────────────────────────────────────────────────────────────
    'GET  /api/io/status': () => respond(200, io.status()),
    'POST /api/io/test':   (env, req, s) => { auth.audit('io.test', { by: s.subject }); return respond(200, io.test()); },

    // ── lorawan ─────────────────────────────────────────────────────────────
    'GET  /api/lorawan/status':       () => respond(200, lorawan.status()),
    'GET  /api/lorawan/concentrator': () => respond(200, lorawan.concentrator()),
    'POST /api/lorawan/concentrator': (env, req, s) => respond(200, lorawan.setConcentrator(req, s)),
    'POST /api/lorawan/detect':       (env, req, s) => { auth.audit('lorawan.detect', { by: s.subject }); return respond(200, lorawan.detect()); },

    'GET  /api/lorawan/forwarders': () => respond(200, lorawan.forwarders()),

    // ── gnss ────────────────────────────────────────────────────────────────
    'GET  /api/gnss':        () => respond(200, lorawan.gps()),
    'POST /api/gnss/source': (env, req, s) => {
        const result = lorawan.setGpsSource(req);
        if (result.error) return error(400, result.error);
        auth.audit('gps.source', { by: s.subject, source: req.source, slot: req.slot, device: req.device });
        return respond(200, result);
    },
    'POST /api/gnss/detect': (env, req, s) => { auth.audit('gps.detect', { by: s.subject }); return respond(200, lorawan.detectGps()); },
    'POST /api/gnss/sync':   (env, req, s) => {
        const result = lorawan.syncGps();
        if (result.error) return error(409, result.error);
        auth.audit('gps.sync', { by: s.subject });
        return respond(200, result);
    },
    'POST /api/lorawan/backhaul':     (env, req, s) => { auth.audit('lorawan.backhaul', { by: s.subject, allowCellular: req.allowCellular, buffer: req.buffer }); return respond(200, lorawan.setBackhaul(req, s)); },
    'POST /api/lorawan/restart':      (env, req, s) => { auth.audit('lorawan.restart', { by: s.subject }); return respond(200, lorawan.restart()); },
};

// Routes whose body is not JSON but the payload itself — read by the handler,
// in chunks, after authentication. Everything else goes through body(), which
// runs before the session check and is capped at 64KB on purpose.
const STREAMED = {
    'POST /api/system/firmware': true,
};

// Normalised so 'GET  /api/x' in the tables above matches a real request
// regardless of how many spaces the table used to line its columns up.
function routeKey(method, path) {
    return sprintf('%-4s %s', method, path);
}

function route(env) {
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
            handler = (e, r, s) => respond(200, lorawan.setSlot(slotIndex, r, s));
        }
    }

    if (!handler) return error(404, 'No such endpoint.');

    // Provisioning endpoints exist only until the gateway belongs to somebody.
    if (PROVISIONING_ONLY[key] && claim.isAdopted())
        return error(404, 'This gateway is already adopted.');

    // Not for a streamed route: its body is the payload, and must not be read
    // here — before authentication — at all.
    const req = STREAMED[key] ? {} :
        ((method == 'POST' || method == 'PUT') ? body(env) : {});

    if (PUBLIC[key])
        return handler(env, req, null, null);

    const token = cookies(env)[SESSION_COOKIE];
    const session = auth.readSession(token);
    if (!session)
        return error(401, 'Not signed in.');

    // CSRF: any state-changing request must echo the session's CSRF token in a
    // header. A cross-origin page can cause the cookie to be sent but cannot
    // read the token to echo it.
    if (method != 'GET') {
        const sent = env.headers ? env.headers['x-parkeze-csrf'] : null;
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
	}
	catch (e) {
		warn(sprintf('parkeze-console: %s\n%s\n', e.message ?? e, e.stacktrace ?? ''));
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
