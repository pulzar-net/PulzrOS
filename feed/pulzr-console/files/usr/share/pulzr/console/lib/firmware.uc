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
// An image must carry a signature, sent in the X-Pulzr-Manifest header and
// produced by the release workflow (.github/workflows/build.yml) as the
// .pulzr.json beside each image. One that is absent or does not verify is
// refused; only a development image takes an unsigned one (see apply).
//
// Settings are kept, which includes the gateway's identity: see
// /lib/upgrade/keep.d/pulzr for the state that has to survive.

let _m_fs = require('fs');
let _m_uci = require('uci');
let _m_util = loadfile('/usr/share/pulzr/console/lib/util.uc', { raw_mode: true })();

let upload, installFile, apply, olderThan, runningVersion, meminfoAvailable, cardRoom, flashRoom, staging, inspect, shellQuote, inRam;

const META = '/tmp/pulzr-firmware.json';
const MANIFEST = '/tmp/pulzr-firmware.manifest';

// Headroom the rest of the gateway keeps while an image sits in RAM. /tmp is
// tmpfs, so an image is memory; running the box out of it mid-upload takes the
// packet forwarder and the console down with it.
//
// 16MB, down from 24MB, because 24MB meant a RAK7268CV2 could not install its
// own firmware and a gateway that cannot be updated remotely is a site visit.
//
// Measured on a customer's RAK rather than guessed. Freshly booted, with the radio and
// forwarder running: 120.4MB total, 37.7MB available, 22.1MB genuinely free
// and 54.6MB cached. Staging a 14.5MB image leaves 23.2MB available — more
// than the entire working set of a running gateway. 24MB left it 0.8MB short
// of being allowed to try.
//
// This is the floor for the RAM path only. A gateway with a card does not
// spend memory on this at all; see staging() below.
const HEADROOM = 16 * 1024 * 1024;

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
// Every RAK ships with a card, which is the whole reason pulzr-storage
// exists. Staging there costs nothing and leaves RAM alone.
const CARD_SUBDIR = '/pulzr/firmware';

cardRoom = function() {
    const cursor = _m_uci.cursor();
    if (cursor.get('pulzr', 'storage', 'present') != '1') return null;
    if (cursor.get('pulzr', 'storage', 'writable') != '1') return null;
    const mount = cursor.get('pulzr', 'storage', 'mount');
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

// ── on the flash, when neither fits ─────────────────────────────────────────
//
// A gateway with no card and little RAM still has its own flash. A GL-SFT1200
// has 115MB of RAM, about 23MB of it available on a running gateway, against
// an 18.5MB image, so the RAM path refused it ("has room for 5 MB") while its
// overlay had 79MB free. Measured on campo's Cigar Curer, November 2026.
//
// The overlay is what sysupgrade wipes, so an image can wait there but cannot
// be flashed from there. It is checked there, where it costs no memory, and
// only once it passed does `pulzr-firmware handoff` stop the services the
// upgrade would stop anyway and move it into /tmp, which is when the memory is
// there to hold it. FLASH_MARGIN is what the overlay keeps for the gateway's
// own settings and logs while the image sits on it.
const FLASH_DIR = '/overlay/pulzr-firmware';
const FLASH_MARGIN = 8 * 1024 * 1024;

flashRoom = function() {
    if (system('grep -q " /overlay " /proc/mounts') != 0) return null;
    if (system(sprintf('mkdir -p %s', FLASH_DIR)) != 0) return null;
    const proc = _m_fs.popen("df -k /overlay 2>/dev/null | awk 'NR==2 {print $4}'", 'r');
    const free = proc ? int(trim(proc.read('all') ?? '0')) * 1024 : 0;
    if (proc) proc.close();
    return free > FLASH_MARGIN ? { dir: FLASH_DIR, free: free - FLASH_MARGIN } : null;
};

// Where an image of `len` bytes waits: the card, else RAM when it fits there,
// else the flash. Returns { path, room, onCard, onFlash, ram }: room is what
// may be spent at path, and ram what the RAM path would have had, for the
// refusal.
staging = function(len) {
    const card = cardRoom();
    if (card)
        return { path: card.dir + '/pulzr-firmware.img', room: card.free, onCard: true };
    const ram = meminfoAvailable() - HEADROOM;
    if (len <= ram)
        return { path: '/tmp/pulzr-firmware.img', room: ram, onCard: false, ram };
    const flash = flashRoom();
    if (flash)
        return { path: flash.dir + '/pulzr-firmware.img', room: flash.free, onCard: false,
                 onFlash: true, ram };
    return { path: '/tmp/pulzr-firmware.img', room: ram, onCard: false, ram };
};

// Whether sysupgrade can read `path` where it is: in /tmp, or on the card.
// Anything else is on the system sysupgrade is about to overwrite.
inRam = function(path) {
    if (match(path, /^\/tmp\//)) return true;
    const mount = _m_uci.cursor().get('pulzr', 'storage', 'mount');
    return !!(mount && length(mount) && index(path, mount + '/') == 0);
};

meminfoAvailable = function() {
    const text = _m_fs.readfile('/proc/meminfo') ?? '';
    const m = match(text, /MemAvailable:\s+([0-9]+) kB/);
    return m ? int(m[1]) * 1024 : 0;
};

// A path as one shell word. The terminal UI's image path was typed by hand.
shellQuote = function(s) {
    return "'" + replace(s, /'/g, "'\\''") + "'";
};

// The metadata of an uploaded image, and whether it is for this board.
inspect = function(IMAGE) {
    _m_fs.unlink(META);
    if (system(sprintf('fwtool -q -i %s %s', META, shellQuote(IMAGE))) != 0)
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

upload = function(env, issuer, staff) {
    const len = int(env.CONTENT_LENGTH ?? 0);
    if (len <= 0)
        return { status: 400, error: 'No image in the request.' };

    const stage = staging(len);
    const IMAGE = stage.path;
    if (len > stage.room)
        return { status: 413, error: stage.onCard
            ? sprintf('Image is %d MB; this gateway has room for %d MB on its card.',
                      len / 1048576, stage.room / 1048576)
            : sprintf('Image is %d MB; this gateway has room for %d MB in memory and %s, and has no card.',
                      len / 1048576, (stage.ram > 0 ? stage.ram : 0) / 1048576,
                      stage.onFlash ? sprintf('%d MB on its flash', stage.room / 1048576)
                                    : 'none on its flash') };

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

    const manifest = env.headers ? (env.headers['x-pulzr-manifest'] ?? env.headers['x-parkeze-manifest']) : null;
    const result = apply(IMAGE, manifest, issuer, true, staff);
    if (result.error) return result;
    result.bytes = received;
    result.stagedOnCard = stage.onCard;
    result.stagedOnFlash = !!stage.onFlash;
    return result;
};

// An image already on the gateway — copied to the SD card, or to /tmp over
// SSH — for the terminal UI, which has no HTTP body to stream one in. The
// same checks and the same journal as an upload; the only difference is that
// a file somebody pointed at is theirs, and is left in place if it is refused.
installFile = function(path, manifestPath, issuer, staff) {
    const info = _m_fs.stat(path ?? '');
    if (!info || info.type != 'file')
        return { status: 400, error: sprintf('%s is not a file.', path ?? '') };
    let manifest = null;
    if (manifestPath && length(manifestPath)) {
        manifest = trim(_m_fs.readfile(manifestPath) ?? '');
        if (!length(manifest))
            return { status: 400, error: sprintf('Could not read %s.', manifestPath) };
    }
    const result = apply(path, manifest, issuer, false, staff);
    if (!result.error) result.bytes = info.size;
    return result;
};

// The running release, as board.conf records it.
runningVersion = function() {
    const m = match(_m_fs.readfile('/etc/pulzr/board.conf') ?? '', /PULZR_VERSION='([^']*)'/);
    return m ? m[1] : null;
};

// Whether release a is older than release b: 0.4.0-rc5 < 0.4.0 < v0.4.1.
// null when either is not a version, which callers treat as older.
olderThan = function(a, b) {
    const parse = (v) => {
        const m = match(v ?? '', /^v?([0-9]+)\.([0-9]+)\.([0-9]+)(-([A-Za-z]+)?([0-9]*))?/);
        if (!m) return null;
        return { n: [int(m[1]), int(m[2]), int(m[3])], pre: m[4] != null,
                 tag: m[5] ?? '', num: length(m[6] ?? '') ? int(m[6]) : 0 };
    };
    const x = parse(a), y = parse(b);
    if (!x || !y) return null;
    for (let i = 0; i < 3; i++)
        if (x.n[i] != y.n[i]) return x.n[i] < y.n[i];
    if (x.pre != y.pre) return x.pre;          // a pre-release comes before its release
    if (x.tag != y.tag) return x.tag < y.tag;
    return x.num < y.num;
};

// Check a staged image and, if it passes, hand it to sysupgrade. `owned` says
// whether the file is ours to delete when it is refused; `staff`, whether the
// session asking is Pulzar staff's (a session's `shell`, which only Pulzar
// Cloud's signature sets).
apply = function(IMAGE, manifest, issuer, owned, staff) {
    const refuse = (error) => {
        if (owned) _m_fs.unlink(IMAGE);
        return { status: 400, error };
    };

    const image = inspect(IMAGE);
    if (image.error) return refuse(image.error);

    // Belt and braces after the metadata check. Its exit status cannot be
    // trusted to reject a bad image (see the header), but when it does say no
    // it means it.
    const proc = _m_fs.popen(sprintf('sysupgrade -T %s 2>&1', shellQuote(IMAGE)), 'r');
    const verdict = proc ? trim(proc.read('all') ?? '') : '';
    const rc = proc ? proc.close() : 1;
    if (rc != 0)
        return refuse(length(verdict)
            ? sprintf('Not a valid image for this gateway: %s', verdict)
            : 'Not a valid image for this gateway.');

    // ── is it ours ──────────────────────────────────────────────────────────
    //
    // An upload's signature travels in a header because the body is the image
    // itself and there is nowhere else in the request for it; the terminal UI
    // reads it from a file beside the image. The release workflow produces
    // it.
    //
    // Required. Root on a gateway is Pulzar's alone (docs/src/content/docs/auth.md), and an
    // image somebody built themselves is root on it, so an unsigned image
    // installed from the console would hand root to anybody who can sign in
    // to it. Every release since 0.3.x carries a .pulzr.json beside each
    // image and Pulzar Cloud sends it with every upgrade. A development image
    // (its version ends in -dev, and CI never builds one) takes any image: it
    // is open on the bench by design.
    if (!manifest && !match(_m_fs.readfile('/etc/pulzr/board.conf') ?? '',
                            /PULZR_VERSION='[^']*-dev'/))
        return refuse('That image has no signature. Upload the .pulzr.json released beside it.');
    let signed = false;
    if (manifest) {
        const mf = _m_fs.open(MANIFEST, 'w');
        if (mf) { mf.write(manifest); mf.close(); }
        const check = _m_fs.popen(sprintf('pulzr-firmware verify %s %s 2>&1', shellQuote(IMAGE), MANIFEST), 'r');
        const why = check ? trim(check.read('all') ?? '') : '';
        const ok = check ? check.close() == 0 : false;
        _m_fs.unlink(MANIFEST);
        if (!ok)
            return refuse(length(why) ? why : 'That image is not signed by Pulzar.');
        signed = true;

        // Forward only, except for staff. Every release Pulzar ever signed
        // stays signed, and the ones before 0.4 take unsigned images: going
        // back to one, then flashing an image of one's own, would be root by
        // two steps. The signed manifest says which release this is.
        let version = null;
        try {
            const p = _m_fs.popen(sprintf("printf %%s %s | openssl base64 -d -A",
                                          shellQuote(json(manifest).manifest ?? '')), 'r');
            version = json(p.read('all')).version;
            p.close();
        } catch (e) {}
        const older = olderThan(version, runningVersion());
        if (older !== false && !staff && !match(runningVersion() ?? '', /-dev$/))
            return refuse(older == null
                ? 'That image does not say which release it is.'
                : sprintf('%s is older than this gateway\'s %s. Going back is for Pulzar staff.',
                          version, runningVersion()));
    }

    // Record what is about to happen while the system that knows it is still
    // running. After sysupgrade there is no longer anything here that can say
    // what version this was or who asked — see pulzr-firmware. Synchronous
    // and before the detach on purpose: a journal written after the upgrade
    // has started is a race with the reboot.
    //
    // The issuer is reduced to a safe character set first. It is a session
    // subject, it is going into a shell command string, and a subject
    // containing a quote would otherwise be running as one. The path is
    // quoted for the same reason: from the terminal UI it was typed.
    const who = replace(issuer ?? 'console', /[^A-Za-z0-9._@-]/g, '') || 'console';
    const quoted = shellQuote(IMAGE);
    _m_util.run(sprintf('pulzr-firmware pending %s %s', quoted, who));

    // Detached, after a pause, so this response reaches the browser before
    // sysupgrade stops uhttpd. Settings kept. An image that waited on the
    // flash goes through handoff, which moves it (copies it, if it is not
    // ours) into /tmp first; see flashRoom.
    if (inRam(IMAGE))
        _m_util.run(sprintf('(sleep 3; sysupgrade %s) >/dev/null 2>&1 &', quoted));
    else
        _m_util.run(sprintf('(sleep 3; pulzr-firmware handoff %s %s) >/dev/null 2>&1 &',
                            quoted, owned ? 'move' : 'copy'));
    return { status: 202, ok: true, signed,
             target: image.target, openwrt: image.openwrt };
};

// ── module exports ──────────────────────────────────────────────────────────
return { inspect, installFile, upload };
