// The Parkeze console API.
//
// Served by uhttpd's ucode handler: uhttpd calls `handle_request(env)` for
// every request under /api/, and whatever this returns is the response. There
// is no framework underneath — the routing table below is the whole of it,
// which is appropriate for a surface this small and keeps the console off the
// ~30MB that a Python or Node runtime would cost on a flash-constrained board.
//
// Every route is authenticated unless it appears in PUBLIC. That is the
// default direction on purpose: a new route added without thinking about auth
// is closed, not open.

import { readfile } from 'fs';
import { cursor } from 'uci';
import * as auth from '../lib/auth.uc';
import * as system from '../lib/system.uc';
import * as network from '../lib/network.uc';
import * as lorawan from '../lib/lorawan.uc';
import * as claim from '../lib/claim.uc';
import * as io from '../lib/io.uc';
import * as access from '../lib/access.uc';

const SESSION_COOKIE = 'parkeze_session';

// Routes reachable without a session. Everything needed to *get* a session,
// and nothing else.
const PUBLIC = {
    'POST /api/auth/login': true,
    'POST /api/auth/sso': true,
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

function body(env) {
    if (!env.content_length) return {};
    try { return json(env.content) ? json(env.content) : {}; }
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
    'GET  /api/system/logs':      (env, req) => respond(200, system.logs(env.QUERY_STRING)),
    'POST /api/system/reboot':    (env, req, s) => { auth.audit('system.reboot', { by: s.subject }); return respond(200, system.reboot()); },

    // ── network ─────────────────────────────────────────────────────────────
    'GET  /api/network/status':   () => respond(200, network.status()),
    'GET  /api/network/backhaul': () => respond(200, network.backhaul()),
    'POST /api/network/cellular': (env, req, s) => respond(200, network.setCellular(req, s)),

    // ── provisioning ────────────────────────────────────────────────────────
    'GET  /api/claim/status': () => respond(200, claim.status()),
    'GET  /api/claim/qr':     () => respond(200, claim.qr()),
    'POST /api/claim/poll':   () => respond(200, claim.poll()),
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
    'POST /api/access/wifi':      (env, req, s) => {
        const result = access.joinWifi(req);
        if (result.error) return error(400, result.error);
        auth.audit('wifi.join', { by: s.subject, ssid: req.ssid });
        return respond(200, result);
    },

    // ── io ──────────────────────────────────────────────────────────────────
    'GET  /api/io/status': () => respond(200, io.status()),
    'POST /api/io/test':   (env, req, s) => { auth.audit('io.test', { by: s.subject }); return respond(200, io.test()); },

    // ── lorawan ─────────────────────────────────────────────────────────────
    'GET  /api/lorawan/status':       () => respond(200, lorawan.status()),
    'GET  /api/lorawan/concentrator': () => respond(200, lorawan.concentrator()),
    'POST /api/lorawan/concentrator': (env, req, s) => respond(200, lorawan.setConcentrator(req, s)),
    'POST /api/lorawan/detect':       (env, req, s) => { auth.audit('lorawan.detect', { by: s.subject }); return respond(200, lorawan.detect()); },

    // ── gnss ────────────────────────────────────────────────────────────────
    'GET  /api/lorawan/gps':        () => respond(200, lorawan.gps()),
    'POST /api/lorawan/gps/detect': (env, req, s) => { auth.audit('gps.detect', { by: s.subject }); return respond(200, lorawan.detectGps()); },
    'POST /api/lorawan/gps/sync':   (env, req, s) => {
        const result = lorawan.syncGps();
        if (result.error) return error(409, result.error);
        auth.audit('gps.sync', { by: s.subject });
        return respond(200, result);
    },
    'POST /api/lorawan/restart':      (env, req, s) => { auth.audit('lorawan.restart', { by: s.subject }); return respond(200, lorawan.restart()); },
};

// Normalised so 'GET  /api/x' in the tables above matches a real request
// regardless of how many spaces the table used to line its columns up.
function routeKey(method, path) {
    return sprintf('%-4s %s', method, path);
}

export function handle_request(env) {
    const method = env.REQUEST_METHOD;
    const path = env.PATH_INFO ? env.PATH_INFO : '/';
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

    const req = (method == 'POST' || method == 'PUT') ? body(env) : {};

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
