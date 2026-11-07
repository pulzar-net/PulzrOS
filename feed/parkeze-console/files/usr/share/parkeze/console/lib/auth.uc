// Authentication for the Parkeze gateway console.
//
// ── THE PROBLEM ─────────────────────────────────────────────────────────────
//
// A gateway lives on a pole or in a cabinet, is worth stealing, and must stay
// administrable when its backhaul is down — which is exactly when you most
// need to get into it and exactly when central identity is unavailable.
//
// Those pull in opposite directions:
//
//   * If offline local login always works with a stored credential, then
//     whoever physically holds a stolen gateway can extract that credential
//     from flash at their leisure. Flash is not a secret store. Physical
//     presence proves nothing here — the thief has more physical presence than
//     we do.
//
//   * If offline login never works, a site with a dead SIM and a dead uplink
//     is a truck roll with a laptop that cannot do anything when it arrives.
//
// ── THE SHAPE OF THE ANSWER ─────────────────────────────────────────────────
//
// Three states, each with a different answer, rather than one mechanism
// stretched over all of them:
//
//   UNADOPTED   Nobody owns this gateway yet. A local account is the only
//               thing that could possibly work, so it is the way in. The
//               password is unique per unit and generated on first boot — not
//               `parkeze/parkeze`, which is what the previous build shipped
//               and which is a fleet-wide skeleton key.
//
//   ADOPTED,    parkeze.net is reachable. SSO is the way in: the console
//   ONLINE      accepts the signed one-time handoff token the net-api
//               device_ui flow already mints, so an operator who is already
//               authenticated centrally lands logged in. The local password is
//               *disabled* on adoption — not merely discouraged.
//
//   ADOPTED,    The interesting case. Local login is still refused, because
//   OFFLINE     the credential a thief could extract must not be a way in.
//               Instead: an Ed25519 challenge-response against a key the
//               gateway only ever holds the *public* half of.
//
// ── OFFLINE RECOVERY ────────────────────────────────────────────────────────
//
//   1. The gateway prints a challenge — its device id, a fresh random nonce,
//      and the time — as a short code and a QR.
//   2. The operator carries it to parkeze.net on their phone (a phone has
//      cellular even when the gateway's uplink is dead). parkeze.net checks
//      they are a net-admin, writes an audit row, and signs the challenge with
//      the fleet recovery key.
//   3. The operator brings the signature back and types or scans it in.
//   4. The gateway verifies it against the embedded public key and grants a
//      short, clearly-labelled recovery session.
//
// What this buys: the gateway stores no secret that grants access, so stolen
// hardware yields nothing. Every recovery is authorised and audited centrally
// even though the gateway itself was never online. The nonce makes each
// signature good exactly once, for one device.
//
// What it costs: an operator needs a second device with connectivity. That is
// an acceptable trade for a fleet where the alternative is a extractable
// skeleton key, and it is the same trade a car's key fob makes.

let _m_fs = require('fs');
let open = _m_fs.open;; let readfile = _m_fs.readfile;; let writefile = _m_fs.writefile;; let unlink = _m_fs.unlink;; let popen = _m_fs.popen; let stat = _m_fs.stat;
let _m_uci = require('uci');
let cursor = _m_uci.cursor;
let digest = require('digest');

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
let now, randomHex, constantTimeEqual, readJson, writeJson, crypt, hashPassword, verifyPassword, shellQuote, lockoutState, isLockedOut, recordFailure, clearFailures, sessionPath, createSession, readSession, destroySession, config, backhaulUp, loginMethods, loginLocal, setPassword, recoveryChallenge, recoveryVerify, verifySignature, loginSso, audit, platformUrl, lanWindow, loginTicket, terminalStart, terminalCollect;


const STATE_DIR      = '/etc/parkeze/console';
const SESSION_DIR    = '/var/run/parkeze/sessions';
const RECOVERY_PUBKEY = '/etc/parkeze/recovery.pub';
const CHALLENGE_FILE = '/var/run/parkeze/recovery-challenge.json';
const SSO_SPENT_FILE = '/var/run/parkeze/sso-spent.json';
const LOCKOUT_FILE   = '/var/run/parkeze/lockout.json';
// Written by /usr/sbin/parkeze-local-access, which only a root shell can run.
const LAN_STATE      = '/var/run/parkeze/local-access/state.json';
const LAN_TICKET     = '/var/run/parkeze/local-access/ticket';

// Sessions are short because a gateway console is a place you go to do one
// thing. A tab left open in a van overnight should not still be authenticated.
const SESSION_TTL        = 3600;        // 1 hour
const RECOVERY_TTL       = 1800;        // 30 min — deliberately shorter
const CHALLENGE_TTL      = 600;         // a challenge is stale after 10 min
const MAX_FAILURES       = 5;
const LOCKOUT_SECONDS    = 900;

// ── primitives ──────────────────────────────────────────────────────────────

now = function() {
    return time();
};

// Random bytes as lowercase hex. /dev/urandom directly rather than ucode's
// math.rand(), which is a seeded PRNG and not suitable for anything here.
randomHex = function(bytes) {
    const fd = open('/dev/urandom', 'r');
    if (!fd) die('no entropy source');
    const buf = fd.read(bytes);
    fd.close();
    let out = '';
    for (let i = 0; i < length(buf); i++)
        out += sprintf('%02x', ord(buf, i));
    return out;
};

// Constant-time string comparison. A plain `==` on a session token or a
// password hash leaks its prefix through timing, and a gateway that answers
// unauthenticated requests is exactly where someone would measure it.
constantTimeEqual = function(a, b) {
    if (type(a) != 'string' || type(b) != 'string') return false;
    // Compare hashes of both rather than bailing on a length mismatch, so that
    // the length itself does not leak either.
    const ha = digest.sha256(a), hb = digest.sha256(b);
    let diff = 0;
    for (let i = 0; i < length(ha); i++)
        diff |= ord(ha, i) ^ ord(hb, i);
    return diff == 0;
};

readJson = function(path) {
    const raw = readfile(path);
    if (!raw) return null;
    try { return json(raw); } catch (e) { return null; }
};

writeJson = function(path, value) {
    // Written via a temporary file and renamed, so a reader never sees a
    // half-written session index. These files are read on every request.
    const tmp = path + '.tmp';
    writefile(tmp, sprintf('%J', value));
    return system(['/bin/mv', tmp, path]) == 0;
};

// ── password hashing ────────────────────────────────────────────────────────
//
// sha512crypt via busybox's mkpasswd. ucode has no KDF and implementing PBKDF2
// on top of ucode-mod-digest would be both slow and a thing to get wrong;
// libcrypt's sha512crypt is a real KDF with a tunable round count, is already
// on the device, and produces the standard $6$rounds=N$salt$hash string that
// anybody debugging this will recognise.
//
// 100k rounds costs roughly 100ms on a Pi 3, which is the right order for a
// login that a human initiates and an attacker must repeat.

const CRYPT_ROUNDS = 100000;

// popen() is unidirectional, so the password goes *in* over the pipe (never
// touching disk, never appearing in the process table) and the resulting hash
// comes *out* via a file on tmpfs, which we read and immediately unlink. The
// hash is not secret in the way the password is, and /tmp is RAM on OpenWrt,
// so nothing here survives a power cut or reaches flash.
crypt = function(password, spec) {
    // openssl passwd, NOT busybox mkpasswd.
    //
    // The busybox in OpenWrt 24.10 and 25.12 has neither the `mkpasswd` nor the
    // `cryptpw` applet compiled in. The old call therefore produced nothing at
    // all, on every gateway: /etc/parkeze/console/password was written zero
    // bytes at provisioning, verifyPassword refused every attempt because the
    // stored hash was empty, and setPassword could not replace it because
    // hashing failed there too. Local sign-in has never worked.
    //
    // It failed closed rather than open, which is the one piece of luck in it,
    // and it was invisible because nothing checked that the hash was non-empty.
    // The uci-defaults script now does.
    //
    // `openssl passwd -6` is an exact substitute, not an approximation: given a
    // salt of 'rounds=N$salt' it emits '$6$rounds=N$salt$hash', the same string
    // sha512crypt produces, so the round count still travels inside the hash
    // and existing stored hashes stay verifiable. openssl-util is already a
    // dependency of this package for the TLS certificate.
    const parts = split(spec, '$');       // '$6$rounds=N$salt' -> ['','6',...]
    if (length(parts) < 3 || parts[1] != '6') return null;
    const salt = join('$', slice(parts, 2));

    // -stdin so the password arrives over the pipe and never appears in the
    // process table. The hash comes back via a file on /tmp, which is RAM on
    // OpenWrt, and is unlinked immediately — it is not secret the way the
    // password is, but there is no reason to leave it lying around.
    const out = '/tmp/.pwhash';
    unlink(out);
    const proc = popen(sprintf('openssl passwd -6 -salt %s -stdin > %s 2>/dev/null',
                               shellQuote(salt), out), 'w');
    if (!proc) return null;
    proc.write(password + '\n');
    proc.close();
    const hash = trim(readfile(out) ?? '');
    unlink(out);
    return length(hash) ? hash : null;
};

hashPassword = function(password, salt) {
    if (!salt) salt = randomHex(8);
    // The full spec, so the round count is recorded in the stored hash and a
    // future increase does not silently invalidate existing passwords —
    // verifyPassword re-reads whatever rounds the stored hash was made with.
    return crypt(password, sprintf('$6$rounds=%d$%s', CRYPT_ROUNDS, salt));
};

verifyPassword = function(password, stored) {
    if (!stored || !length(stored)) return false;
    // Re-derive with the stored parameters and compare. A sha512crypt string
    // is '$6$rounds=N$salt$hash', so splitting on '$' gives
    // ['', '6', 'rounds=N', 'salt', 'hash'] — or four parts when the hash was
    // made at the default round count and carries no 'rounds=' field.
    const parts = split(stored, '$');
    let spec;
    if (length(parts) >= 5)
        spec = '$' + parts[1] + '$' + parts[2] + '$' + parts[3];
    else if (length(parts) == 4)
        spec = '$' + parts[1] + '$' + parts[2];
    else
        return false;

    const derived = crypt(password, spec);
    if (!derived) return false;
    return constantTimeEqual(derived, stored);
};

shellQuote = function(s) {
    return "'" + replace(s, "'", "'\\''") + "'";
};

// ── lockout ─────────────────────────────────────────────────────────────────
//
// Per-source-address, not per-account: there is only one account, so a
// per-account counter is a denial of service anybody on the LAN can trigger
// against the legitimate operator.

lockoutState = function() {
    return readJson(LOCKOUT_FILE) ?? {};
};

isLockedOut = function(addr) {
    const state = lockoutState();
    const entry = state[addr];
    if (!entry) return false;
    if (entry.until <= now()) return false;
    return entry.until - now();
};

recordFailure = function(addr) {
    const state = lockoutState();
    const entry = state[addr] ?? { failures: 0, until: 0 };
    entry.failures++;
    if (entry.failures >= MAX_FAILURES) {
        entry.until = now() + LOCKOUT_SECONDS;
        entry.failures = 0;
    }
    state[addr] = entry;
    writeJson(LOCKOUT_FILE, state);
};

clearFailures = function(addr) {
    const state = lockoutState();
    delete state[addr];
    writeJson(LOCKOUT_FILE, state);
};

// ── sessions ────────────────────────────────────────────────────────────────
//
// Sessions live in /var/run, so a reboot logs everybody out. That is correct
// for a device whose reboot is a deliberate operator action, and it means a
// stolen gateway that gets power-cycled carries no live session.

sessionPath = function(token) {
    // The token is never used as a filename directly — a token containing a
    // slash or '..' would otherwise be a path traversal into the filesystem.
    return SESSION_DIR + '/' + digest.sha256(token);
};

createSession = function(subject, kind, ttl, extra) {
    system(['/bin/mkdir', '-p', SESSION_DIR]);
    const token = randomHex(32);
    const session = {
        subject,
        kind,                       // 'local' | 'sso' | 'recovery' | 'lan'
        // Parkeze staff, proved by parkeze.net's signature: the one session a
        // terminal's `!` drops to a root shell for (tui/app.uc). Org admins
        // sign in by SSO and recovery as well, so the kind cannot say it.
        shell: false,
        created: now(),
        expires: now() + (ttl ? ttl : SESSION_TTL),
        // A CSRF token bound to the session. The session cookie is
        // SameSite=Strict, which handles most of this, but a gateway console
        // is reached through the parkeze.net proxy under a different origin
        // where SameSite reasoning gets subtle — so the header check is
        // belt-and-braces rather than redundant.
        csrf: randomHex(16),
    };
    for (let k in (extra ?? {})) session[k] = extra[k];
    writeJson(sessionPath(token), session);
    // Built field by field rather than with a spread: ucode's object spread
    // support varies by version and this runs on whatever ucode the pinned
    // OpenWrt release ships.
    return { token: token, subject: session.subject, kind: session.kind,
             shell: session.shell, created: session.created,
             expires: session.expires, csrf: session.csrf };
};

readSession = function(token) {
    if (!token || !match(token, /^[0-9a-f]{64}$/)) return null;
    const session = readJson(sessionPath(token));
    if (!session) return null;
    // A LAN session lives exactly as long as the window it came through:
    // closing the window, or the reboot that clears it, ends the session too,
    // and extending the window extends the session without signing in again.
    //
    // The window it came through, not any window. Matching on "a window is
    // open" let a session from a window closed yesterday come back to life
    // the moment somebody opened a new one.
    if (session.kind == 'lan') {
        const window = lanWindow();
        if (!window || window.id != session.window) {
            unlink(sessionPath(token));
            return null;
        }
        session.expires = window.expires;
    }
    if (session.expires <= now()) {
        unlink(sessionPath(token));
        return null;
    }
    return session;
};

destroySession = function(token) {
    if (token && match(token, /^[0-9a-f]{64}$/))
        unlink(sessionPath(token));
};

// ── adoption state ──────────────────────────────────────────────────────────

config = function() {
    const uci = cursor();
    return {
        adopted:      uci.get('parkeze', 'adoption', 'state') == 'adopted',
        localEnabled: uci.get('parkeze', 'console', 'local_login') != '0',
        passwordSet:  !!readfile(STATE_DIR + '/password'),
        deviceId:     uci.get('parkeze', 'identity', 'gateway_eui') ?? 'unknown',
        hostname:     uci.get('parkeze', 'identity', 'hostname') ?? 'parkeze',
    };
};

// Whether parkeze.net is reachable right now. Used only to explain *why* the
// login page is offering what it is offering — never to decide whether local
// login is permitted. An attacker who can cut the uplink must not be able to
// unlock local login by doing so, so the decision below keys on adoption
// state, which they cannot change, rather than on reachability, which they can.
backhaulUp = function() {
    return system('/usr/sbin/parkeze-backhaul-check >/dev/null 2>&1') == 0;
};

// The platform's base URL, from board.conf — the one place a host is named.
platformUrl = function() {
    const conf = readfile('/etc/parkeze/board.conf') ?? '';
    const m = match(conf, /PARKEZE_NET_URL='([^']*)'/);
    return (m && length(m[1])) ? m[1] : 'https://app.pulzr.net';
};

// What the login page should offer. `addr` is the address this request came in
// on: the platform only sends a token back to a console at a private IP, and a
// browser that came here by parkeze.local has only that name to offer.
loginMethods = function(addr) {
    const cfg = config();

    if (!cfg.adopted) {
        return {
            local: true,
            sso: false,
            recovery: false,
            state: 'unadopted',
            // No note. The screen is a sign-in form with an adopt link beside
            // it; a sentence restating that is the sort of thing a technician
            // reads once, learns to skip, and then misses something that
            // mattered. Notes are for states that are NOT obvious — see the
            // adopted branch, where local sign-in being on is genuinely
            // surprising and worth a line.
            note: null,
        };
    }

    return {
        // Off in the adopted state whether or not the uplink is up. See
        // backhaulUp() for why this does not consult it.
        local: cfg.localEnabled,
        sso: true,
        recovery: true,
        state: 'adopted',
        online: backhaulUp(),
        // Where "Sign in with Parkeze" sends the browser, and which gateway it
        // asks about. Neither is a secret: the EUI is printed on the unit, and
        // the platform address is in board.conf for anyone who can read it.
        platform: platformUrl(),
        deviceId: cfg.deviceId,
        address: addr,
        note: cfg.localEnabled
            ? 'Local sign-in is on. That is not the default.'
            : null,
    };
};

// ── local login ─────────────────────────────────────────────────────────────

loginLocal = function(username, password, addr) {
    const remaining = isLockedOut(addr);
    if (remaining)
        return { error: sprintf('Too many attempts. Try again in %d minutes.',
                                (remaining + 59) / 60), status: 429 };

    const cfg = config();
    if (cfg.adopted && !cfg.localEnabled)
        return { error: 'Local sign-in is disabled on this gateway. Sign in '
                      + 'through Pulzar, or use recovery access if it is '
                      + 'unreachable.', status: 403 };

    const stored = trim(readfile(STATE_DIR + '/password') ?? '');
    const expected = trim(readfile(STATE_DIR + '/username') ?? 'parkeze');

    // Both checks always run, and the result is combined at the end, so that a
    // wrong username and a wrong password take the same time. Bailing early on
    // an unknown username tells an attacker which half to keep working on.
    const userOk = constantTimeEqual(username ?? '', expected);
    const passOk = verifyPassword(password ?? '', stored);

    if (!userOk || !passOk) {
        recordFailure(addr);
        audit('login.failed', { username, addr, method: 'local' });
        return { error: 'Incorrect username or password.', status: 401 };
    }

    clearFailures(addr);
    const session = createSession(expected, 'local', SESSION_TTL);
    audit('login.ok', { username: expected, addr, method: 'local' });

    // A gateway still on its factory password is a gateway anybody with the
    // label can open. The console makes changing it the first thing you see.
    // Existence, not contents. The marker is a zero-byte touch file, so
    // readfile() returns '' — falsy — and the console never insisted on
    // replacing the factory credential, which is the one thing it is for.
    session.mustChangePassword = !!stat(STATE_DIR + '/password-is-initial');
    return { session };
};

setPassword = function(username, password) {
    if (length(password ?? '') < 12)
        return { error: 'Use at least 12 characters.', status: 400 };

    const hash = hashPassword(password);
    if (!hash) return { error: 'Could not hash the password.', status: 500 };

    system(['/bin/mkdir', '-p', STATE_DIR]);
    writefile(STATE_DIR + '/password', hash);
    system(['/bin/chmod', '0600', STATE_DIR + '/password']);
    if (username) writefile(STATE_DIR + '/username', username);
    unlink(STATE_DIR + '/password-is-initial');
    // Root's password is not this one any more: root has none
    // (parkeze-root-keys-only), so knowing the console's is not root.

    audit('password.changed', { username });
    return { ok: true };
};

// ── offline recovery ────────────────────────────────────────────────────────

// Start a recovery: mint a challenge for the operator to carry to parkeze.net.
recoveryChallenge = function() {
    const cfg = config();
    if (!cfg.adopted)
        return { error: 'Recovery access is only for adopted gateways. This '
                      + 'one still has local sign-in.', status: 409 };

    if (!readfile(RECOVERY_PUBKEY))
        return { error: 'No recovery key is installed on this gateway, so '
                      + 'offline recovery is not possible. It must be '
                      + 're-adopted while online.', status: 501 };

    // One outstanding challenge at a time. Minting a fresh one on every page
    // load would let somebody harvest challenges, and more importantly makes
    // the operator's transcription race the page.
    let challenge = readJson(CHALLENGE_FILE);
    if (!challenge || challenge.expires <= now()) {
        challenge = {
            device: cfg.deviceId,
            nonce: randomHex(12),
            issued: now(),
            expires: now() + CHALLENGE_TTL,
        };
        writeJson(CHALLENGE_FILE, challenge);
    }

    return {
        challenge: {
            device: challenge.device,
            nonce: challenge.nonce,
            issued: challenge.issued,
            expiresIn: challenge.expires - now(),
            // What the operator types into parkeze.net. One field, so there is
            // one thing to transcribe and one thing to get wrong.
            code: sprintf('%s.%s.%d', challenge.device, challenge.nonce,
                          challenge.issued),
        },
        hostname: cfg.hostname,
    };
};

// Complete a recovery: verify parkeze.net's signature over our challenge.
recoveryVerify = function(signature, addr) {
    const remaining = isLockedOut(addr);
    if (remaining)
        return { error: sprintf('Too many attempts. Try again in %d minutes.',
                                (remaining + 59) / 60), status: 429 };

    const challenge = readJson(CHALLENGE_FILE);
    if (!challenge || challenge.expires <= now()) {
        unlink(CHALLENGE_FILE);
        return { error: 'That challenge has expired. Start again.', status: 410 };
    }

    // Exactly the bytes the challenge code represents. Reconstructed here
    // rather than trusting anything the client sends back, so a client cannot
    // choose what gets verified.
    const signed = sprintf('%s.%s.%d', challenge.device, challenge.nonce,
                           challenge.issued);

    // parkeze.net signs `<challenge>.shell` for staff and the bare challenge
    // for an organization's admin. Either opens the console; only the first
    // lets the terminal drop to a shell.
    const plain = verifySignature(signed, signature);
    const shell = !plain && verifySignature(signed + '.shell', signature);
    if (!plain && !shell) {
        recordFailure(addr);
        audit('recovery.failed', { addr, device: challenge.device });
        return { error: 'That signature is not valid for this challenge.',
                 status: 401 };
    }

    // Spent. A signature is good exactly once — otherwise an operator's
    // legitimate recovery code, left in a chat window, is a standing key to
    // that gateway.
    unlink(CHALLENGE_FILE);
    clearFailures(addr);

    const session = createSession('recovery', 'recovery', RECOVERY_TTL, { shell });
    audit('recovery.ok', { addr, device: challenge.device,
                           nonce: challenge.nonce, shell });
    return { session };
};

// Ed25519 verification, shelled out to openssl.
//
// ucode has no asymmetric crypto and this is not the place to write some. The
// gateway holds only the public key, so the worst an attacker who tampers with
// this path can do is make recovery fail — they cannot forge a signature
// without the private half, which never leaves parkeze.net.
verifySignature = function(message, signatureB64) {
    if (!match(signatureB64 ?? '', /^[A-Za-z0-9+\/=]{80,120}$/)) return false;

    const msgFile = '/tmp/.recovery-msg';
    const sigFile = '/tmp/.recovery-sig';

    writefile(msgFile, message);
    // base64 -d rather than passing the signature to openssl on the command
    // line: it is binary, and it is attacker-supplied.
    // openssl, not `busybox base64`: the image's BusyBox has no base64 applet.
    // The old command wrote nothing, openssl was handed an empty signature
    // file, and verification failed for every signature — so recovery access
    // and SSO handoff had never worked on a ParkezeOS gateway.
    const decode = popen(sprintf('openssl base64 -d -A > %s', sigFile), 'w');
    if (!decode) return false;
    decode.write(signatureB64);
    decode.close();

    const rc = system(sprintf(
        'openssl pkeyutl -verify -pubin -inkey %s -rawin -in %s -sigfile %s '
        + '>/dev/null 2>&1',
        RECOVERY_PUBKEY, msgFile, sigFile));

    unlink(msgFile);
    unlink(sigFile);
    return rc == 0;
};

// ── SSO handoff ─────────────────────────────────────────────────────────────
//
// parkeze.net's device_ui flow already mints a one-time token for a device's
// own web interface. Rather than invent a second scheme, we verify that one:
// it is signed with the same fleet key as recovery, so a gateway needs no
// additional trust anchor.

// `expect`, from terminalCollect only: the terminal sign-in this token must
// have been minted for, as { aud, req }. Without it — the web console's
// handoff, and parkeze.net's own calls — a token that names any audience is
// refused. So a token collected for a terminal cannot be pasted into a
// browser, and a browser's cannot satisfy a terminal waiting on a code.
loginSso = function(token, addr, expect) {
    if (!readfile(RECOVERY_PUBKEY))
        return { error: 'This gateway has no Parkeze trust anchor.',
                 status: 501 };

    // token is "<payload-b64>.<signature-b64>", payload being JSON with the
    // subject, the device id and an expiry.
    const parts = split(token ?? '', '.');
    if (length(parts) != 2)
        return { error: 'Malformed handoff token.', status: 400 };

    if (!verifySignature(parts[0], parts[1])) {
        recordFailure(addr);
        return { error: 'That handoff token is not valid.', status: 401 };
    }

    let payload;
    try {
        const proc = popen(sprintf('printf %%s %s | openssl base64 -d -A',
                                   shellQuote(parts[0])), 'r');
        payload = json(proc.read('all'));
        proc.close();
    } catch (e) {
        return { error: 'Malformed handoff token.', status: 400 };
    }

    const cfg = config();
    // A token minted for a different gateway must not open this one. Without
    // this check, one operator's legitimate token for gateway A is a key to
    // every gateway in the fleet.
    if (payload.device != cfg.deviceId)
        return { error: 'That token was issued for a different gateway.',
                 status: 403 };

    if ((payload.exp ?? 0) <= now())
        return { error: 'That handoff token has expired.', status: 410 };

    if (expect ? (payload.aud != expect.aud || payload.req != expect.req)
               : payload.aud != null) {
        recordFailure(addr);
        return { error: 'That token was issued for a different sign-in.', status: 403 };
    }

    // Good once. A token arrives in a URL fragment, which is not sent to any
    // server but does stay in the browser's history — so without this, the
    // back button on a shared laptop reopened a staff session for the rest of
    // the token's five minutes. Spent tokens are remembered by the hash of
    // their signature until they would have expired anyway, in tmpfs, so a
    // reboot forgets them only once they are useless.
    const spent = readJson(SSO_SPENT_FILE) ?? {};
    const id = digest.sha256(parts[1]);
    const t = now();
    for (let k in keys(spent)) if (spent[k] <= t) delete spent[k];
    if (spent[id]) {
        recordFailure(addr);
        return { error: 'That handoff token has already been used.', status: 409 };
    }
    spent[id] = payload.exp;
    writeJson(SSO_SPENT_FILE, spent);

    clearFailures(addr);
    // `shell` is staff's, and only on a token minted for a terminal: the web
    // console has no shell, and recovery-service refuses the claim elsewhere.
    const shell = !!expect && payload.shell === true;
    const session = createSession(payload.sub ?? 'Parkeze', 'sso',
                                  SESSION_TTL, { shell });
    audit('login.ok', { username: payload.sub, addr,
                        method: expect ? 'sso-terminal' : 'sso', shell });
    return { session };
};

// ── signing in to the terminal with a Parkeze account ──────────────────────
//
// The terminal's "Sign in with Parkeze". There is no browser to land a handoff
// in, so the terminal shows a code, somebody approves it on parkeze.net —
// from a phone, usually — and the gateway collects the token itself:
// parkeze-console-signin does the asking. The token is checked here, by
// loginSso, and goes no further: the terminal gets a session or a reason.
//
// Online only, as the browser handoff is. Offline, recovery is the way in.

terminalStart = function() {
    const proc = popen('/usr/sbin/parkeze-console-signin start 2>/dev/null', 'r');
    let reply = null;
    try { reply = json(proc.read('all')); } catch (e) {}
    proc.close();
    if (!reply) return { error: 'Could not reach Parkeze.' };
    if (reply.error) return { error: reply.error };
    return { code: reply.code, url: reply.url, expiresIn: reply.expiresIn,
             interval: reply.interval ?? 3 };
};

// { pending: true } until somebody answers, then { session } or { error }.
terminalCollect = function(code, addr) {
    if (!match(code ?? '', /^[0-9A-Z]{4}-[0-9A-Z]{4}$/))
        return { error: 'Malformed code.' };
    const proc = popen(sprintf('/usr/sbin/parkeze-console-signin poll %s 2>/dev/null', code), 'r');
    let reply = null;
    try { reply = json(proc.read('all')); } catch (e) {}
    proc.close();
    if (!reply) return { pending: true };     // a dropped poll; ask again
    if (reply.error) return { error: reply.error };
    if (reply.state == 'pending') return { pending: true };
    if (reply.state == 'refused') return { error: 'Refused on Parkeze.' };
    if (reply.state == 'expired') return { error: 'That code has expired.' };
    if (reply.state != 'approved' || !reply.token) return { error: 'Parkeze did not answer.' };
    return loginSso(reply.token, addr, { aud: 'terminal', req: code });
};

// ── LAN access ──────────────────────────────────────────────────────────────
//
// The one-time link parkeze-local-access prints. That script's header says why
// it exists and why only a root shell can open a window; this only redeems the
// link. Valid while the window is open, good once.

lanWindow = function() {
    const window = readJson(LAN_STATE);
    return (window && window.expires > now()) ? window : null;
};

loginTicket = function(ticket, addr) {
    const remaining = isLockedOut(addr);
    if (remaining)
        return { error: sprintf('Too many attempts. Try again in %d minutes.',
                                (remaining + 59) / 60), status: 429 };

    const window = lanWindow();
    if (!window)
        return { error: 'LAN access is closed. Open it again from the '
                      + "gateway's shell with parkeze-local-access open.",
                 status: 410 };

    const stored = trim(readfile(LAN_TICKET) ?? '');
    const valid = type(ticket) == 'string' && match(ticket, /^[0-9a-f]{64}$/)
                  && length(stored)
                  && constantTimeEqual(digest.sha256(ticket), stored);
    if (!valid) {
        recordFailure(addr);
        audit('login.failed', { addr, method: 'lan' });
        return { error: 'That link has been used or replaced. Run '
                      + 'parkeze-local-access open for a new one.',
                 status: 401 };
    }

    unlink(LAN_TICKET);
    clearFailures(addr);
    const session = createSession('root', 'lan', window.expires - now(),
                                  { window: window.id });
    audit('login.ok', { addr, method: 'lan', subnet: window.subnet });
    return { session };
};

// ── audit ───────────────────────────────────────────────────────────────────
//
// Written locally and uploaded when the backhaul returns. A recovery that
// happened while the gateway was offline is precisely the event that must
// still reach parkeze.net eventually.

audit = function(action, detail) {
    const entry = { at: now(), action: action };
    for (let k in (detail ? detail : {})) entry[k] = detail[k];
    const line = sprintf('%J\n', entry);
    const fd = open('/etc/parkeze/console/audit.log', 'a');
    if (fd) { fd.write(line); fd.close(); }
    // Also to syslog, so it is visible in the console's log view immediately.
    system(['/usr/bin/logger', '-t', 'parkeze-console', '-p', 'authpriv.notice',
            sprintf('%s %J', action, detail)]);
};

// ── module exports ──────────────────────────────────────────────────────────
//
// A returned object, not `export` statements. uhttpd's ucode plugin compiles
// its handler in TEMPLATE mode and loads anything else through loadfile(),
// neither of which is module mode — `export` is a syntax error there. See the
// header of api/index.uc for the full contract.
return { audit, constantTimeEqual, createSession, destroySession, hashPassword, loginLocal, loginMethods, loginSso, loginTicket, readSession, recoveryChallenge, recoveryVerify, setPassword, terminalCollect, terminalStart, verifyPassword };
