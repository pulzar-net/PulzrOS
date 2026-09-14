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

import { open, readfile, writefile, unlink, popen } from 'fs';
import { cursor } from 'uci';
import * as digest from 'digest';

const STATE_DIR      = '/etc/parkeze/console';
const SESSION_DIR    = '/var/run/parkeze/sessions';
const RECOVERY_PUBKEY = '/etc/parkeze/recovery.pub';
const CHALLENGE_FILE = '/var/run/parkeze/recovery-challenge.json';
const LOCKOUT_FILE   = '/var/run/parkeze/lockout.json';

// Sessions are short because a gateway console is a place you go to do one
// thing. A tab left open in a van overnight should not still be authenticated.
const SESSION_TTL        = 3600;        // 1 hour
const RECOVERY_TTL       = 1800;        // 30 min — deliberately shorter
const CHALLENGE_TTL      = 600;         // a challenge is stale after 10 min
const MAX_FAILURES       = 5;
const LOCKOUT_SECONDS    = 900;

// ── primitives ──────────────────────────────────────────────────────────────

function now() {
    return time();
}

// Random bytes as lowercase hex. /dev/urandom directly rather than ucode's
// math.rand(), which is a seeded PRNG and not suitable for anything here.
function randomHex(bytes) {
    const fd = open('/dev/urandom', 'r');
    if (!fd) die('no entropy source');
    const buf = fd.read(bytes);
    fd.close();
    let out = '';
    for (let i = 0; i < length(buf); i++)
        out += sprintf('%02x', ord(buf, i));
    return out;
}

// Constant-time string comparison. A plain `==` on a session token or a
// password hash leaks its prefix through timing, and a gateway that answers
// unauthenticated requests is exactly where someone would measure it.
function constantTimeEqual(a, b) {
    if (type(a) != 'string' || type(b) != 'string') return false;
    // Compare hashes of both rather than bailing on a length mismatch, so that
    // the length itself does not leak either.
    const ha = digest.sha256(a), hb = digest.sha256(b);
    let diff = 0;
    for (let i = 0; i < length(ha); i++)
        diff |= ord(ha, i) ^ ord(hb, i);
    return diff == 0;
}

function readJson(path) {
    const raw = readfile(path);
    if (!raw) return null;
    try { return json(raw); } catch (e) { return null; }
}

function writeJson(path, value) {
    // Written via a temporary file and renamed, so a reader never sees a
    // half-written session index. These files are read on every request.
    const tmp = path + '.tmp';
    writefile(tmp, sprintf('%J', value));
    return system(['/bin/mv', tmp, path]) == 0;
}

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
function crypt(password, spec) {
    const out = '/tmp/.pwhash';
    unlink(out);
    const proc = popen(sprintf('busybox mkpasswd -m sha512crypt -S %s > %s 2>/dev/null',
                               shellQuote(spec), out), 'w');
    if (!proc) return null;
    proc.write(password + '\n');
    proc.close();
    const hash = trim(readfile(out) ?? '');
    unlink(out);
    return length(hash) ? hash : null;
}

function hashPassword(password, salt) {
    if (!salt) salt = randomHex(8);
    // The full spec, so the round count is recorded in the stored hash and a
    // future increase does not silently invalidate existing passwords —
    // verifyPassword re-reads whatever rounds the stored hash was made with.
    return crypt(password, sprintf('$6$rounds=%d$%s', CRYPT_ROUNDS, salt));
}

function verifyPassword(password, stored) {
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
}

function shellQuote(s) {
    return "'" + replace(s, "'", "'\\''") + "'";
}

// ── lockout ─────────────────────────────────────────────────────────────────
//
// Per-source-address, not per-account: there is only one account, so a
// per-account counter is a denial of service anybody on the LAN can trigger
// against the legitimate operator.

function lockoutState() {
    return readJson(LOCKOUT_FILE) ?? {};
}

function isLockedOut(addr) {
    const state = lockoutState();
    const entry = state[addr];
    if (!entry) return false;
    if (entry.until <= now()) return false;
    return entry.until - now();
}

function recordFailure(addr) {
    const state = lockoutState();
    const entry = state[addr] ?? { failures: 0, until: 0 };
    entry.failures++;
    if (entry.failures >= MAX_FAILURES) {
        entry.until = now() + LOCKOUT_SECONDS;
        entry.failures = 0;
    }
    state[addr] = entry;
    writeJson(LOCKOUT_FILE, state);
}

function clearFailures(addr) {
    const state = lockoutState();
    delete state[addr];
    writeJson(LOCKOUT_FILE, state);
}

// ── sessions ────────────────────────────────────────────────────────────────
//
// Sessions live in /var/run, so a reboot logs everybody out. That is correct
// for a device whose reboot is a deliberate operator action, and it means a
// stolen gateway that gets power-cycled carries no live session.

function sessionPath(token) {
    // The token is never used as a filename directly — a token containing a
    // slash or '..' would otherwise be a path traversal into the filesystem.
    return SESSION_DIR + '/' + digest.sha256(token);
}

function createSession(subject, kind, ttl) {
    system(['/bin/mkdir', '-p', SESSION_DIR]);
    const token = randomHex(32);
    const session = {
        subject,
        kind,                       // 'local' | 'sso' | 'recovery'
        created: now(),
        expires: now() + (ttl ? ttl : SESSION_TTL),
        // A CSRF token bound to the session. The session cookie is
        // SameSite=Strict, which handles most of this, but a gateway console
        // is reached through the parkeze.net proxy under a different origin
        // where SameSite reasoning gets subtle — so the header check is
        // belt-and-braces rather than redundant.
        csrf: randomHex(16),
    };
    writeJson(sessionPath(token), session);
    // Built field by field rather than with a spread: ucode's object spread
    // support varies by version and this runs on whatever ucode the pinned
    // OpenWrt release ships.
    return { token: token, subject: session.subject, kind: session.kind,
             created: session.created, expires: session.expires,
             csrf: session.csrf };
}

function readSession(token) {
    if (!token || !match(token, /^[0-9a-f]{64}$/)) return null;
    const session = readJson(sessionPath(token));
    if (!session) return null;
    if (session.expires <= now()) {
        unlink(sessionPath(token));
        return null;
    }
    return session;
}

function destroySession(token) {
    if (token && match(token, /^[0-9a-f]{64}$/))
        unlink(sessionPath(token));
}

// ── adoption state ──────────────────────────────────────────────────────────

function config() {
    const uci = cursor();
    return {
        adopted:      uci.get('parkeze', 'adoption', 'state') == 'adopted',
        localEnabled: uci.get('parkeze', 'console', 'local_login') != '0',
        passwordSet:  !!readfile(STATE_DIR + '/password'),
        deviceId:     uci.get('parkeze', 'identity', 'gateway_eui') ?? 'unknown',
        hostname:     uci.get('parkeze', 'identity', 'hostname') ?? 'parkeze',
    };
}

// Whether parkeze.net is reachable right now. Used only to explain *why* the
// login page is offering what it is offering — never to decide whether local
// login is permitted. An attacker who can cut the uplink must not be able to
// unlock local login by doing so, so the decision below keys on adoption
// state, which they cannot change, rather than on reachability, which they can.
function backhaulUp() {
    return system('/usr/sbin/parkeze-backhaul-check >/dev/null 2>&1') == 0;
}

// What the login page should offer.
export function loginMethods() {
    const cfg = config();

    if (!cfg.adopted) {
        return {
            local: true,
            sso: false,
            recovery: false,
            state: 'unadopted',
            note: 'This gateway has not been adopted. Sign in locally to '
                + 'configure it, or adopt it from parkeze.net.',
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
        note: cfg.localEnabled
            ? 'Local sign-in is enabled on this adopted gateway. That is not '
            + 'the default — disable it from parkeze.net unless it is '
            + 'deliberate.'
            : 'This gateway is managed by parkeze.net. If it is offline, use '
            + 'recovery access.',
    };
}

// ── local login ─────────────────────────────────────────────────────────────

export function loginLocal(username, password, addr) {
    const remaining = isLockedOut(addr);
    if (remaining)
        return { error: sprintf('Too many attempts. Try again in %d minutes.',
                                (remaining + 59) / 60), status: 429 };

    const cfg = config();
    if (cfg.adopted && !cfg.localEnabled)
        return { error: 'Local sign-in is disabled on this gateway. Sign in '
                      + 'through parkeze.net, or use recovery access if it is '
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
    session.mustChangePassword = !!readfile(STATE_DIR + '/password-is-initial');
    return { session };
}

export function setPassword(username, password) {
    if (length(password ?? '') < 12)
        return { error: 'Use at least 12 characters.', status: 400 };

    const hash = hashPassword(password);
    if (!hash) return { error: 'Could not hash the password.', status: 500 };

    system(['/bin/mkdir', '-p', STATE_DIR]);
    writefile(STATE_DIR + '/password', hash);
    system(['/bin/chmod', '0600', STATE_DIR + '/password']);
    if (username) writefile(STATE_DIR + '/username', username);
    unlink(STATE_DIR + '/password-is-initial');
    audit('password.changed', { username });
    return { ok: true };
}

// ── offline recovery ────────────────────────────────────────────────────────

// Start a recovery: mint a challenge for the operator to carry to parkeze.net.
export function recoveryChallenge() {
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
}

// Complete a recovery: verify parkeze.net's signature over our challenge.
export function recoveryVerify(signature, addr) {
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

    if (!verifySignature(signed, signature)) {
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

    const session = createSession('recovery', 'recovery', RECOVERY_TTL);
    audit('recovery.ok', { addr, device: challenge.device,
                           nonce: challenge.nonce });
    return { session };
}

// Ed25519 verification, shelled out to openssl.
//
// ucode has no asymmetric crypto and this is not the place to write some. The
// gateway holds only the public key, so the worst an attacker who tampers with
// this path can do is make recovery fail — they cannot forge a signature
// without the private half, which never leaves parkeze.net.
function verifySignature(message, signatureB64) {
    if (!match(signatureB64 ?? '', /^[A-Za-z0-9+\/=]{80,120}$/)) return false;

    const msgFile = '/tmp/.recovery-msg';
    const sigFile = '/tmp/.recovery-sig';

    writefile(msgFile, message);
    // base64 -d rather than passing the signature to openssl on the command
    // line: it is binary, and it is attacker-supplied.
    const decode = popen(sprintf('busybox base64 -d > %s', sigFile), 'w');
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
}

// ── SSO handoff ─────────────────────────────────────────────────────────────
//
// parkeze.net's device_ui flow already mints a one-time token for a device's
// own web interface. Rather than invent a second scheme, we verify that one:
// it is signed with the same fleet key as recovery, so a gateway needs no
// additional trust anchor.

export function loginSso(token, addr) {
    if (!readfile(RECOVERY_PUBKEY))
        return { error: 'This gateway has no parkeze.net trust anchor.',
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
        const proc = popen(sprintf('echo %s | busybox base64 -d',
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

    clearFailures(addr);
    const session = createSession(payload.sub ?? 'parkeze.net', 'sso',
                                  SESSION_TTL);
    audit('login.ok', { username: payload.sub, addr, method: 'sso' });
    return { session };
}

// ── audit ───────────────────────────────────────────────────────────────────
//
// Written locally and uploaded when the backhaul returns. A recovery that
// happened while the gateway was offline is precisely the event that must
// still reach parkeze.net eventually.

function audit(action, detail) {
    const entry = { at: now(), action: action };
    for (let k in (detail ? detail : {})) entry[k] = detail[k];
    const line = sprintf('%J\n', entry);
    const fd = open('/etc/parkeze/console/audit.log', 'a');
    if (fd) { fd.write(line); fd.close(); }
    // Also to syslog, so it is visible in the console's log view immediately.
    system(['/usr/bin/logger', '-t', 'parkeze-console', '-p', 'authpriv.notice',
            sprintf('%s %J', action, detail)]);
}

export { createSession, readSession, destroySession, constantTimeEqual, audit,
         hashPassword, verifyPassword };
