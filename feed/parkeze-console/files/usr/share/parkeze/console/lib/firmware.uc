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
// WHO BUILT IT
//
// An image may carry a signature, sent in the X-Parkeze-Manifest header and
// produced by tools/sign-firmware.sh. One that is present and does not verify
// is refused outright. One that is absent is accepted, and recorded as
// unsigned.
//
// That asymmetry is deliberate and temporary. A bad signature means somebody
// tampered with an image; no signature means the image predates signing, which
// is true of every image the fleet currently runs — and requiring one now
// would mean this release could not be installed by the fleet that has to
// install it to gain the check. Being unable to ship any image is the one
// failure a rollback cannot undo. So: verify and record now, require once
// signed images are confirmed flowing.
//
// Settings are kept, which includes the gateway's identity: see
// /lib/upgrade/keep.d/parkeze for the state that has to survive.

let _m_fs = require('fs');
let _m_uci = require('uci');
let _m_util = loadfile('/usr/share/parkeze/console/lib/util.uc', { raw_mode: true })();

let upload, meminfoAvailable, cardRoom, staging, inspect;

const META = '/tmp/parkeze-firmware.json';
const MANIFEST = '/tmp/parkeze-firmware.manifest';

// Headroom the rest of the gateway keeps while an image sits in RAM. /tmp is
// tmpfs, so an image is memory; running the box out of it mid-upload takes the
// packet forwarder and the console down with it.
const HEADROOM = 24 * 1024 * 1024;

// ── where the image is staged ───────────────────────────────────────────────
//
// On the SD card when there is one, and in /tmp when there is not.
//
// This is not a tidiness preference. A RAK7268CV2 has 128MB of RAM, perhaps
// 40MB of it available on a running gateway, and its own image is 14.5MB —
// so with 24MB of headroom the box cannot accept its own firmware. Measured,
// not predicted: the upload came back 413 "Image is 14 MB; this gateway has
// room for 14 MB", which is a gateway that can never be updated remotely.
//
// Every RAK ships with a card, which is the whole reason parkeze-storage
// exists. Staging there costs nothing and leaves RAM alone.
const CARD_SUBDIR = '/parkeze/firmware';

cardRoom = function() {
    const cursor = _m_uci.cursor();
    if (cursor.get('parkeze', 'storage', 'present') != '1') return null;
    if (cursor.get('parkeze', 'storage', 'writable') != '1') return null;
    const mount = cursor.get('parkeze', 'storage', 'mount');
    if (!mount || !length(mount)) return null;

    const dir = mount + CARD_SUBDIR;
    if (system(sprintf('mkdir -p %s', dir)) != 0) return null;

    // Free bytes on the card, from df. Its own filesystem, so MemAvailable
    // says nothing about it.
    const proc = _m_fs.popen(sprintf("df -k %s 2>/dev/null | awk 'NR==2 {print $4}'", dir), 'r');
    const free = proc ? int(trim(proc.read('all') ?? '0')) * 1024 : 0;
    if (proc) proc.close();
    return free > 0 ? { dir, free } : null;
};

// Returns { path, room, onCard }. room is what may be spent here.
staging = function() {
    const card = cardRoom();
    if (card)
        return { path: card.dir + '/parkeze-firmware.img', room: card.free, onCard: true };
    return { path: '/tmp/parkeze-firmware.img',
             room: meminfoAvailable() - HEADROOM, onCard: false };
};

meminfoAvailable = function() {
    const text = _m_fs.readfile('/proc/meminfo') ?? '';
    const m = match(text, /MemAvailable:\s+([0-9]+) kB/);
    return m ? int(m[1]) * 1024 : 0;
};

// The metadata of an uploaded image, and whether it is for this board.
inspect = function(IMAGE) {
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

upload = function(env, issuer) {
    const len = int(env.CONTENT_LENGTH ?? 0);
    if (len <= 0)
        return { status: 400, error: 'No image in the request.' };

    const stage = staging();
    const IMAGE = stage.path;
    if (len > stage.room)
        return { status: 413, error: sprintf(
            'Image is %d MB; this gateway has room for %d MB%s.',
            len / 1048576, stage.room / 1048576,
            stage.onCard ? ' on its card' : ' in memory, and has no card to stage on') };

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

    const image = inspect(IMAGE);
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

    // ── is it ours ──────────────────────────────────────────────────────────
    //
    // The signature travels in a header because the body is the image itself
    // and there is nowhere else in the request for it. See
    // tools/sign-firmware.sh for what produces it.
    //
    // Present-but-invalid is refused; absent is allowed and recorded. Those
    // are different facts: a signature that does not verify means somebody
    // tampered with an image or handed over the wrong one, and no upgrade
    // should proceed through that. No signature at all is what every image
    // built before signing existed looks like, and refusing those outright
    // would mean this release could not be installed by the very fleet that
    // has to install it to gain the check. That is the one failure a rollback
    // cannot save you from, so it is deliberately staged: verify and record
    // now, require it once signed images are confirmed flowing.
    const manifest = env.headers ? env.headers['x-parkeze-manifest'] : null;
    let signed = false;
    if (manifest) {
        const mf = _m_fs.open(MANIFEST, 'w');
        if (mf) { mf.write(manifest); mf.close(); }
        const check = _m_fs.popen(sprintf('parkeze-firmware verify %s %s 2>&1', IMAGE, MANIFEST), 'r');
        const why = check ? trim(check.read('all') ?? '') : '';
        const ok = check ? check.close() == 0 : false;
        _m_fs.unlink(MANIFEST);
        if (!ok) {
            _m_fs.unlink(IMAGE);
            return { status: 400, error: length(why) ? why
                     : 'That image is not signed by Parkeze.' };
        }
        signed = true;
    }

    // Record what is about to happen while the system that knows it is still
    // running. After sysupgrade there is no longer anything here that can say
    // what version this was or who asked — see parkeze-firmware. Synchronous
    // and before the detach on purpose: a journal written after the upgrade
    // has started is a race with the reboot.
    //
    // The issuer is reduced to a safe character set first. It is a session
    // subject, it is going into a shell command string, and a subject
    // containing a quote would otherwise be running as one.
    const who = replace(issuer ?? 'console', /[^A-Za-z0-9._@-]/g, '') || 'console';
    _m_util.run(sprintf('parkeze-firmware pending %s %s', IMAGE, who));

    // Detached, after a pause, so this response reaches the browser before
    // sysupgrade stops uhttpd. Settings kept.
    _m_util.run(sprintf('(sleep 3; sysupgrade %s) >/dev/null 2>&1 &', IMAGE));
    return { status: 202, ok: true, bytes: received, signed,
             stagedOnCard: stage.onCard,
             target: image.target, openwrt: image.openwrt };
};

// ── module exports ──────────────────────────────────────────────────────────
return { inspect, upload };
