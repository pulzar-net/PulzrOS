// One-touch provisioning, as the console sees it.
//
// The heavy lifting is in `parkeze-claim`; this exposes it to the UI. Keeping
// the logic in the shell script rather than here is deliberate — the same flow
// has to work over SSH on a gateway whose console is not reachable, and a
// second implementation in ucode would be a second thing to keep correct.

let _m_fs = require('fs');
let open = _m_fs.open;
let _m_uci = require('uci');
let cursor = _m_uci.cursor;
let _m_util = loadfile('/usr/share/parkeze/console/lib/util.uc', { raw_mode: true })();

// ── forward declarations ────────────────────────────────────────────────────
//
// ucode does not hoist function declarations. A `function f()` defined below
// a function that calls it is simply not in scope there, and the call fails at
// RUNTIME with "left-hand side is not a function" — never at compile time, so
// nothing catches it until the request that needs it.
//
// Declaring the names first makes every one of them a known local before any
// body is compiled, so closures capture the binding rather than a missing
// global and definition order stops mattering. auth.uc alone had six of these.
let status, qr, poll, applyBundle, writeBundle, isAdopted, reclaiming, platformUrl;
let checkAdoption, adoptionCheckResult;

let run = _m_util.run;; let runJson = _m_util.runJson;

status = function() {
    const state = runJson('/usr/sbin/parkeze-claim status');
    if (!state) return { error: 'Claim subsystem is not responding.' };

    const uci = cursor();
    return {
        claimId: state.claimId,
        // 'unadopted' | 'adopting' | 'adopted' | 'reclaiming' — the last is
        // adopted, with a revoked claim and a new one to show.
        adoption: state.state,
        // Whether parkeze.net already knows about this pending claim. When it
        // does the QR is a short URL; when it does not the QR carries the
        // gateway's identity inline so a scan still works from a basement.
        registered: state.registered,
        online: state.online,
        url: state.url,
        org: uci.get('parkeze', 'adoption', 'org'),
        hostname: uci.get('parkeze', 'identity', 'hostname'),
        gatewayEui: uci.get('parkeze', 'identity', 'gateway_eui'),
        board: uci.get('parkeze', 'identity', 'board_name'),

        // Where the management platform actually lives, read from board.conf
        // rather than spelled out in the UI. The deployment has moved once
        // already; the console shows whatever this says, so the next move is
        // one line in board.conf and not a hunt through React strings.
        platform: platformUrl(),
    };
};

// Ask parkeze.net whether this gateway is still adopted.
//
// The recovery screen is for an adopted gateway that cannot reach Parkeze. A
// gateway that was decommissioned from the console is looking at the wrong
// screen entirely — there is nobody left to sign its challenge — and this is
// how it finds out.
//
// Only parkeze-adopt may act on the answer, and only on one it got from
// parkeze.net over verified TLS, twice. Nothing here decides anything: this
// starts the check and reads the file it leaves behind. A caller on the LAN
// can ask; it cannot answer.
checkAdoption = function() {
    // Detached, because the check deliberately takes a minute and an HTTP
    // handler may not block for one. The UI polls adoptionCheckResult.
    run('/usr/sbin/parkeze-adopt --check >/dev/null 2>&1 &');
    return { checking: true };
};

adoptionCheckResult = function() {
    return runJson('/usr/sbin/parkeze-adopt --check-result') ?? { checking: true };
};

// The platform's base URL, and the bare host for places that want to show
// something typeable rather than a link.
platformUrl = function() {
    const url = trim(run("sed -n \"s/^PARKEZE_NET_URL='\\(.*\\)'$/\\1/p\" /etc/parkeze/board.conf") ?? '');
    const base = length(url) ? url : 'https://app.pulzr.net';
    let host = base;
    host = replace(host, /^https?:\/\//, '');
    host = replace(host, /\/.*$/, '');
    return { url: base, host: host };
};

// The QR as an SVG string.
//
// Rendered on the device by qrencode rather than in the browser by a JS
// library: qrencode is already in the image for the SSH banner, and this saves
// shipping a second QR implementation to a flash-constrained board purely so
// the same bytes can be drawn twice.
qr = function() {
    const svg = run('/usr/sbin/parkeze-claim qr --svg');
    if (!svg) return { error: 'Could not render the claim code.' };
    return { svg: svg, url: run('/usr/sbin/parkeze-claim qr') };
};

// Ask parkeze.net whether somebody has claimed us yet.
//
// The device polls on its own schedule anyway; this is what the console calls
// while an installer is watching, so the page updates the moment they finish
// on their phone rather than up to a backoff interval later.
poll = function() {
    run('/usr/sbin/parkeze-claim poll >/dev/null 2>&1');
    return status();
};

// Complete an adoption for a gateway that has never had internet, from a
// signed bundle the operator carried back from parkeze.net.
applyBundle = function(req) {
    const bundle = req.bundle;
    if (!bundle || !length(bundle))
        return { error: 'Paste the adoption bundle from Parkeze.' };

    // The HTTP route is closed once adopted; the terminal UI calls this
    // directly. A bundle carries no claim, so it cannot replace a revoked one.
    if (isAdopted())
        return { error: 'This gateway is already adopted.' };

    // Length-bounded before it goes anywhere near the filesystem: this is
    // unauthenticated-adjacent input on an un-adopted gateway, and a bundle is
    // a few hundred bytes, not a few megabytes.
    if (length(bundle) > 8192)
        return { error: 'That is too long to be an adoption bundle.' };

    // Written to a file rather than passed as an argument — it is long enough
    // to run into argument limits and would otherwise be visible in the
    // process table while it is being applied.
    const path = '/tmp/.claim-bundle-in';
    if (!writeBundle(path, bundle))
        return { error: 'Could not stage the bundle.' };

    const output = run(sprintf('/usr/sbin/parkeze-adopt --from-bundle %s --verify-signature 2>&1', path));
    run(sprintf('rm -f %s', path));

    if (output == null)
        return { error: 'That bundle was rejected. Check it was issued for '
                      + 'this gateway and has not already been used.' };

    return { ok: true, status: status() };
};

writeBundle = function(path, contents) {
    const fd = open(path, 'w', 0o600);
    if (!fd) return false;
    fd.write(contents);
    fd.close();
    return true;
};

// Whether this gateway belongs to an organisation yet. Used by the router to
// close the provisioning endpoints once it does.
isAdopted = function() {
    const uci = cursor();
    return uci.get('parkeze', 'adoption', 'state') == 'adopted';
};

// Adopted, with its claim revoked and a new one waiting to be adopted: the
// claim screen is shown again. Read from the file rather than by running
// parkeze-claim, because the API gate asks on every provisioning request.
reclaiming = function() {
    if (!isAdopted()) return false;
    const st = _m_fs.stat('/etc/parkeze/claim/next/id');
    return st != null && st.size > 0;
};

// ── module exports ──────────────────────────────────────────────────────────
//
// A returned object, not `export` statements. uhttpd's ucode plugin compiles
// its handler in TEMPLATE mode and loads anything else through loadfile(),
// neither of which is module mode — `export` is a syntax error there. See the
// header of api/index.uc for the full contract.
return { adoptionCheckResult, applyBundle, checkAdoption, isAdopted, poll, qr, reclaiming, status };
