// One-touch provisioning, as the console sees it.
//
// The heavy lifting is in `parkeze-claim`; this exposes it to the UI. Keeping
// the logic in the shell script rather than here is deliberate — the same flow
// has to work over SSH on a gateway whose console is not reachable, and a
// second implementation in ucode would be a second thing to keep correct.

import { open } from 'fs';
import { cursor } from 'uci';
import { run, runJson } from './util.uc';

export function status() {
    const state = runJson('/usr/sbin/parkeze-claim status');
    if (!state) return { error: 'Claim subsystem is not responding.' };

    const uci = cursor();
    return {
        claimId: state.claimId,
        // 'unadopted' | 'adopting' | 'adopted'
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
    };
}

// The QR as an SVG string.
//
// Rendered on the device by qrencode rather than in the browser by a JS
// library: qrencode is already in the image for the SSH banner, and this saves
// shipping a second QR implementation to a flash-constrained board purely so
// the same bytes can be drawn twice.
export function qr() {
    const svg = run('/usr/sbin/parkeze-claim qr --svg');
    if (!svg) return { error: 'Could not render the claim code.' };
    return { svg: svg, url: run('/usr/sbin/parkeze-claim qr') };
}

// Ask parkeze.net whether somebody has claimed us yet.
//
// The device polls on its own schedule anyway; this is what the console calls
// while an installer is watching, so the page updates the moment they finish
// on their phone rather than up to a backoff interval later.
export function poll() {
    run('/usr/sbin/parkeze-claim poll >/dev/null 2>&1');
    return status();
}

// Complete an adoption for a gateway that has never had internet, from a
// signed bundle the operator carried back from parkeze.net.
export function applyBundle(req) {
    const bundle = req.bundle;
    if (!bundle || !length(bundle))
        return { error: 'Paste the adoption bundle from parkeze.net.' };

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
}

function writeBundle(path, contents) {
    const fd = open(path, 'w', 0o600);
    if (!fd) return false;
    fd.write(contents);
    fd.close();
    return true;
}

// Whether this gateway belongs to an organisation yet. Used by the router to
// close the provisioning endpoints once it does.
export function isAdopted() {
    const uci = cursor();
    return uci.get('parkeze', 'adoption', 'state') == 'adopted';
}
