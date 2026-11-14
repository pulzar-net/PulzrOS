// Why the WiFi uplink is not up, read back out of wpa_supplicant's log.
//
// netifd only knows the station is down. The reason — a RADIUS server saying
// the password has expired, a passphrase the access point rejected, a network
// that is not on the air — is only ever in syslog, where wpad's -s flag puts
// every CTRL-EVENT. A technician at the gateway has no logread, so this reads
// it for them and names the failure; the console says what it means.
//
// Only the latest attempt counts. Each "Trying to associate" starts one, a
// CTRL-EVENT-CONNECTED ends it well, and a new config clears everything,
// because a failure from the network somebody just replaced is not news.
// pulzr-wifi-probe fails its handshakes on purpose (probe:// stops before
// phase 2), so everything between its start and end lines is ignored.

let _m_util = loadfile('/usr/share/pulzr/console/lib/util.uc', { raw_mode: true })();
let run = _m_util.run;

let last, classify;

// RADIUS's MS-CHAPv2 error numbers (RFC 2759), the ones a technician meets.
const MSCHAP = {
    '646': 'restricted_hours',
    '647': 'account_disabled',
    '648': 'password_expired',
    '649': 'no_permission',
    '691': 'bad_credentials',
};

const EAP_METHODS = { '13': 'TLS', '21': 'TTLS', '25': 'PEAP', '6': 'GTC', '26': 'MSCHAPv2' };

// A later, vaguer line in the same attempt must not replace a precise one:
// "Password expired" is followed by EAP-FAILURE and a timeout, and those say
// less.
const RANK = {
    password_expired: 9, account_disabled: 9, restricted_hours: 9, no_permission: 9,
    bad_credentials: 8, mschap_failed: 7, cert_mismatch: 8, method_mismatch: 8,
    wrong_passphrase: 8, assoc_rejected: 5, eap_rejected: 4, auth_timeout: 2,
    not_found: 1,
};

// One log line to { code, detail }, or null when it says nothing about failure.
classify = function(line) {
    let m = match(line, /EAP-MSCHAPV2: failure message: '([^']*)'.*error ([0-9]+)/);
    if (m) return { code: MSCHAP[m[2]] || 'mschap_failed', detail: m[1] };
    m = match(line, /CTRL-EVENT-EAP-TLS-CERT-ERROR .*subject='([^']*)'/);
    if (m) return { code: 'cert_mismatch', detail: m[1] };
    m = match(line, /CTRL-EVENT-EAP-PROPOSED-METHOD vendor=0 method=([0-9]+) -> NAK/);
    if (m) return { code: 'method_mismatch', detail: EAP_METHODS[m[1]] || ('EAP method ' + m[1]) };
    if (index(line, 'reason=WRONG_KEY') >= 0) return { code: 'wrong_passphrase' };
    m = match(line, /CTRL-EVENT-ASSOC-REJECT .*status_code=([0-9]+)/);
    if (m) return { code: 'assoc_rejected', detail: 'status ' + m[1] };
    if (index(line, 'CTRL-EVENT-EAP-FAILURE') >= 0) return { code: 'eap_rejected' };
    if (index(line, 'Authentication with') >= 0 && index(line, 'timed out') >= 0)
        return { code: 'auth_timeout' };
    if (index(line, 'CTRL-EVENT-NETWORK-NOT-FOUND') >= 0) return { code: 'not_found' };
    return null;
};

// The latest attempt's failure, or null when it connected or has not failed.
// `at` is the syslog timestamp of the line, which the console uses to show
// each failure once. `log` is for tests; the gateway reads its own.
last = function(log) {
    const out = log ?? run("logread | grep -E 'wpa_supplicant|pulzr-wifi-probe' | tail -n 400");
    if (!out) return null;

    let failure = null, probing = false;
    for (let line in split(out, '\n')) {
        if (index(line, 'pulzr-wifi-probe: start') >= 0) { probing = true; failure = null; continue; }
        if (index(line, 'pulzr-wifi-probe: end') >= 0) { probing = false; failure = null; continue; }
        if (probing) continue;
        if (index(line, 'Set new config for phy') >= 0
            || index(line, 'CTRL-EVENT-CONNECTED') >= 0) { failure = null; continue; }
        if (index(line, 'Trying to associate') >= 0) {
            // A retry keeps the last failure on screen rather than flickering
            // it away for the second it takes to fail again.
            if (failure) failure.retrying = true;
            continue;
        }
        const found = classify(line);
        if (!found) continue;
        if (failure && failure.retrying) {
            // The same failure again keeps its first timestamp, so the
            // console does not announce it anew every retry.
            if (found.code == failure.code) { failure.retrying = false; continue; }
            failure = null;
        }
        if (failure && RANK[failure.code] > RANK[found.code]) continue;
        failure = { code: found.code, detail: found.detail, at: substr(line, 0, 24) };
    }
    if (failure) delete failure.retrying;
    return failure;
};

return { last };
