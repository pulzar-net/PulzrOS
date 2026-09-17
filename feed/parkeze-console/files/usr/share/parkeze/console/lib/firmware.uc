// Firmware upgrade from an uploaded image.
//
// So a gateway can be updated where it stands, by somebody with a laptop and
// the console open, rather than by pulling a card or shipping a unit back.
//
// WHAT HAS TO BE TRUE BEFORE ANY OF THIS RUNS
//
// The caller is signed in, and the CSRF token matched — api/index.uc checks
// both before this sees a single byte of the body. That ordering is the point:
// the generic body reader runs before authentication and caps at 64KB, which
// is right for JSON and wrong for a 40MB image, so an upload gets its own path
// that an anonymous caller cannot reach at all.
//
// WHAT IT CHECKS
//
// The image's own metadata, read with fwtool. Every OpenWrt sysupgrade image
// carries a block at its end listing the boards it supports; this board's name
// has to be in it. That rejects a file that is not an image at all, an image
// for a different board, and a truncated upload — the block is the last thing
// in the file, so an upload that stopped short has none.
//
// NOT `sysupgrade -T` on its own. On OpenWrt 24.10 for the Pi it exits 0 for
// random bytes: its partition check crashes ("sh: out of range") and the
// failure is lost. Measured on a Pi 3 with 4MB of /dev/urandom. Trusting it
// would have written garbage over the boot card. It still runs, last, for
// whatever it does catch.
//
// It does NOT check who built the image. Any valid OpenWrt image for this board
// passes. That is acceptable only because of who can reach this endpoint: an
// adopted gateway has local sign-in off, so a session means either a Parkeze
// signature or somebody who read the per-unit password off the card — which is
// somebody who could also pull the card. Signing images and verifying them here
// is the next step, and until it exists this should not be described as safe
// against a malicious image.
//
// Settings are kept, which includes the gateway's identity: see
// /lib/upgrade/keep.d/parkeze for the state that has to survive.

let _m_fs = require('fs');
let _m_util = loadfile('/usr/share/parkeze/console/lib/util.uc', { raw_mode: true })();

let upload, meminfoAvailable, inspect;

const IMAGE = '/tmp/parkeze-firmware.img';
const META = '/tmp/parkeze-firmware.json';

// Headroom the rest of the gateway keeps while an image sits in RAM. /tmp is
// tmpfs, so an image is memory; running the box out of it mid-upload takes the
// packet forwarder and the console down with it.
const HEADROOM = 24 * 1024 * 1024;

meminfoAvailable = function() {
    const text = _m_fs.readfile('/proc/meminfo') ?? '';
    const m = match(text, /MemAvailable:\s+([0-9]+) kB/);
    return m ? int(m[1]) * 1024 : 0;
};

// The metadata of an uploaded image, and whether it is for this board.
inspect = function() {
    _m_fs.unlink(META);
    if (system(sprintf('fwtool -q -i %s %s', META, IMAGE)) != 0)
        return { error: 'Not a firmware image.' };

    let meta = null;
    try { meta = json(_m_fs.readfile(META) ?? ''); }
    catch (e) { meta = null; }
    _m_fs.unlink(META);
    if (type(meta) != 'object')
        return { error: 'Not a firmware image.' };

    const board = trim(_m_fs.readfile('/tmp/sysinfo/board_name') ?? '');
    const supported = type(meta?.supported_devices) == 'array' ? meta.supported_devices : [];
    if (!length(board) || index(supported, board) < 0)
        return { error: sprintf('Built for %s, not this gateway (%s).',
                                meta?.version?.board ?? 'another board', board) };

    return { board, target: meta?.version?.target, openwrt: meta?.version?.version };
};

upload = function(env) {
    const len = int(env.CONTENT_LENGTH ?? 0);
    if (len <= 0)
        return { status: 400, error: 'No image in the request.' };

    const available = meminfoAvailable();
    if (len + HEADROOM > available)
        return { status: 413, error: sprintf(
            'Image is %d MB; this gateway has room for %d MB.',
            len / 1048576, (available - HEADROOM) / 1048576) };

    _m_fs.unlink(IMAGE);
    const out = _m_fs.open(IMAGE, 'w');
    if (!out)
        return { status: 500, error: 'Could not write the image.' };

    // In chunks, straight to disk. Never the whole body in a string.
    let received = 0;
    while (received < len) {
        const want = (len - received) < 65536 ? (len - received) : 65536;
        const chunk = uhttpd.recv(want);
        if (chunk == null || !length(chunk)) break;
        out.write(chunk);
        received += length(chunk);
    }
    out.close();

    if (received != len) {
        _m_fs.unlink(IMAGE);
        return { status: 400, error: sprintf(
            'Upload stopped at %d of %d bytes.', received, len) };
    }

    const image = inspect();
    if (image.error) {
        _m_fs.unlink(IMAGE);
        return { status: 400, error: image.error };
    }

    // Belt and braces after the metadata check. Its exit status cannot be
    // trusted to reject a bad image (see the header), but when it does say no
    // it means it.
    const proc = _m_fs.popen(sprintf('sysupgrade -T %s 2>&1', IMAGE), 'r');
    const verdict = proc ? trim(proc.read('all') ?? '') : '';
    const rc = proc ? proc.close() : 1;
    if (rc != 0) {
        _m_fs.unlink(IMAGE);
        return { status: 400, error: length(verdict)
            ? sprintf('Not a valid image for this gateway: %s', verdict)
            : 'Not a valid image for this gateway.' };
    }

    // Detached, after a pause, so this response reaches the browser before
    // sysupgrade stops uhttpd. Settings kept.
    _m_util.run(sprintf('(sleep 3; sysupgrade %s) >/dev/null 2>&1 &', IMAGE));
    return { status: 202, ok: true, bytes: received,
             target: image.target, openwrt: image.openwrt };
};

// ── module exports ──────────────────────────────────────────────────────────
return { inspect, upload };
