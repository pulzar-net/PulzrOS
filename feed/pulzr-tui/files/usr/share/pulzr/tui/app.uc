// The terminal UI: the gateway console, for a serial line, a USB serial port,
// an SSH session or a Pi's own screen.
//
// ── PARITY WITH THE WEB CONSOLE ─────────────────────────────────────────────
//
// Same pages, same order, same words, same rules — console/src is the
// reference, and a page here is the React page of the same name restated in
// blocks (see ui.uc). Underneath, both call the same ucode: reads go to the
// console's lib/ modules directly, and every change goes through
// lib/actions.uc, the table the web API calls too, so validation and audit
// records cannot differ between the two.
//
// What does not carry over is what needs a browser: the "Sign in with
// Pulzr" handoff lands on a browser origin, and a firmware upload is a file
// picker. Recovery sign-in covers the first, and an image path on the
// gateway — the SD card, or /tmp over SSH — covers the second.
//
// ── WHO IT TRUSTS ──────────────────────────────────────────────────────────
//
//   pulzr-tui              from a root shell. Root can already do
//                            everything, so there is nothing to sign in to.
//   pulzr-tui --console    as the program on a port: a Pi's HDMI console,
//                            the USB gadget's serial port. The same sign-in
//                            the web console has — the port is physical
//                            access, and docs/src/content/docs/auth.md is plain that physical
//                            access proves nothing on a gateway in a car park.
//   pulzr-tui --remote     as an SSH session's only command, opened from
//                            Pulzr Cloud for an organization's admin. They
//                            were signed in there and the session is the
//                            proof, so there is no sign-in here — and no `!`:
//                            a root shell on PulzrOS is a copy of it, which
//                            is what this mode exists to not hand out.
//                            Pulzr Cloud names it as the certificate's
//                            force-command, so sshd runs nothing else.

let _m_fs = require('fs');

// ucode does not hoist function declarations; see console/lib/util.uc.
let start, loop, draw, drawHeader, drawNav, drawBody, drawFooter, handleKey, handleEdit;
let handleDialog, activate, moveFocus, openPath, current, navEntries, loadPage, tick;
let signOut, signedIn, flash, makeCtx, pageFor, bodyBlocks, layoutBody, runAction, quit, banner, shell, qr, mayShell, shown;
let diagnostics;

const LIB = getenv('PULZR_TUI_LIB') ?? '/usr/share/pulzr/tui';
const load = (name) => loadfile(LIB + '/' + name + '.uc', { raw_mode: true })();

let term = load('term');
let ui = load('ui');
let fmt = load('fmt');
let api = load('api');
let logo = loadfile(LIB + '/../logo.uc', { raw_mode: true })();
let diag = load('diag');

// The sidebar, in console/src/nav.ts's order, under its headings and with its
// labels. A group whose entries the gateway has none of shows no heading.
// `feature`: shown only while the gateway has it, the web console's nav.ts
// words (system.features(): the board's, and each installed add-on's), so
// LoRaWAN appears once pulzr-lorawan is installed, as Cellular does with
// pulzr-cellular.
const NAV_GROUPS = [
    { entries: [
        { path: '/', label: 'Overview' },
        { path: '/logs', label: 'Logs' },
    ] },
    { label: 'Connectivity', entries: [
        { path: '/backhaul', label: 'Backhaul', children: [
            { path: '/backhaul/ethernet', label: 'Ethernet' },
            { path: '/backhaul/cellular', label: 'Cellular', feature: 'cellular' },
            { path: '/backhaul/wifi', label: 'WiFi', feature: 'wifi' },
        ] },
        { path: '/access', label: 'Access' },
    ] },
    { label: 'Radios', entries: [
        { path: '/lorawan', label: 'LoRaWAN', feature: 'lorawan', children: [
            { path: '/lorawan/forwarders', label: 'Forwarders' },
            { path: '/lorawan/settings', label: 'Settings' },
        ] },
        { path: '/bluetooth', label: 'Bluetooth', feature: 'bluetooth' },
        { path: '/gnss', label: 'GNSS', feature: 'gnss' },
    ] },
    { label: 'Gateway', entries: [
        { path: '/io', label: 'Panel' },
        { path: '/system', label: 'System', children: [
            { path: '/system/resources', label: 'Resources' },
            { path: '/system/maintenance', label: 'Maintenance' },
        ] },
    ] },
];

// Every entry, for what does not care about the headings.
const NAV = [];
for (let g in NAV_GROUPS) push(NAV, ...g.entries);

const PAGES = {
    '/': 'overview',
    '/backhaul/ethernet': 'ethernet', '/backhaul/cellular': 'cellular', '/backhaul/wifi': 'wifi',
    '/lorawan/forwarders': 'forwarders', '/lorawan/settings': 'lorawan-settings',
    '/gnss': 'gnss', '/bluetooth': 'bluetooth', '/access': 'access', '/io': 'panel',
    '/logs': 'logs', '/system/resources': 'resources', '/system/maintenance': 'maintenance',
    '/adopt': 'claim',
    // Before a session: the claim screen, sign-in and the forced password.
    '/signin': 'signin', '/password': 'password',
};

const NAV_WIDTH = 16;

// A physical console signs itself out after this long without a key. The web
// console's session lasts an hour from sign-in; a terminal left signed in on
// a gateway's own screen is a terminal anybody walking past can use.
const IDLE_SIGNOUT = 900;

// Live pages stop refreshing after this long without a key, on every kind of
// terminal: a TUI left open in an SSH window should not run mmcli every
// fifteen seconds until somebody notices.
const IDLE_PAUSE = 900;

const app = {
    console: false,       // --console: sign-in required
    remote: false,        // --remote: no sign-in, no shell
    ssh: false,           // --console over SSH, as `pulzr`
    dev: false,           // a development build: see mayShell
    tty: null,
    addr: 'tty',          // what lockout counts sign-in failures against
    session: null, token: null,
    path: '/', pages: {}, page: null,
    focus: 'nav', navCursor: 0,
    focusKey: {}, focusIndex: {}, scroll: {},
    edit: null, dialog: null,
    message: null,
    timers: [],
    view: null,           // the last layout: items and lines
    dirty: true, quit: false,
    lastKey: time(), lastCheck: 0, paused: false,
    resized: false,
    browsing: false,      // looked past the claim screen without adopting
    termOpts: null,       // how the terminal was opened, to open it again
    features: null,       // system.features(), read with every page; null: all
};

// Whether a nav entry is there on this gateway. Until the features have been
// read once, everything is, as before the read could fail.
shown = function(e) {
    return !e.feature || app.features == null || (e.feature in app.features);
};

flash = function(text, tone) {
    app.message = text ? { text, tone: tone ?? 'info', until: time() + 6 } : null;
    app.dirty = true;
};

signedIn = function() { return app.session != null; };

// Whether `!` drops to a shell for this session.
//
// A root shell on PulzrOS is a copy of PulzrOS, so it is Pulzr's: started
// from a root shell already, or signed in as Pulzr staff — Pulzr Cloud's
// signature says so (auth.uc's `shell`). An organization's admin signs in with
// the local password, by Pulzr or by recovery too, and gets the console and
// nothing under it. A remote session never: its sshd runs nothing else. A
// development build lets any signed-in session through, for the bench.
mayShell = function() {
    const s = app.session;
    // Never as the unprivileged SSH account: there is no root to drop to, and
    // staff reach a shell with `ssh root@` and a certificate instead.
    if (!s || app.remote || api.unprivileged) return false;
    return app.dev || s.kind == 'shell' || s.shell === true;
};

// ── pages ───────────────────────────────────────────────────────────────────

pageFor = function(path) {
    if (app.pages[path]) return app.pages[path];
    const name = PAGES[path];
    if (!name) return null;
    const make = load('pages/' + name);
    const page = make(makeCtx());
    page.path = path;
    page.loaded = 0;
    app.pages[path] = page;
    return page;
};

loadPage = function(page, quiet) {
    if (!page || !page.load) return;
    if (!quiet) { flash('Loading', 'neutral'); draw(); }
    try {
        page.load();
        page.error = null;
    }
    catch (e) {
        page.error = e.message ?? sprintf('%s', e);
        warn(sprintf('pulzr-tui: %s\n%s\n', page.error, e.stacktrace ?? ''));
    }
    page.loaded = time();
    // Adoption can happen under any page — from a phone, from Pulzr Cloud —
    // and the banner has to follow it.
    try { app.unadopted = !api.claim.isAdopted(); app.reclaiming = api.claim.reclaiming(); } catch (e) {}
    // An add-on installed or removed meanwhile (from Pulzr Net) moves a page
    // in or out, so with every page rather than once.
    try { const f = api.system.features(); if (type(f) == 'array') app.features = f; } catch (e) {}
    if (!quiet) flash(null);
    app.dirty = true;
};

openPath = function(path) {
    // A group opens on its first shown child, as the web console's routes do;
    // a page the gateway does not have opens the overview instead.
    for (let e in NAV) {
        if (index(path, e.path) == 0 && e.path != '/' && !shown(e)) path = '/';
        if (e.path == path && e.children) {
            const kids = filter(e.children, shown);
            path = length(kids) ? kids[0].path : '/';
        }
        for (let c in e.children ?? []) if (c.path == path && !shown(c)) path = '/';
    }
    const page = pageFor(path);
    if (!page) return;
    app.path = path;
    app.page = page;
    app.edit = null;
    app.dialog = null;
    if (page.enter) page.enter();
    loadPage(page);
    app.dirty = true;
};

current = function() { return app.page; };

// Every page's view of the world: what it may read, and how it changes things.
makeCtx = function() {
    return {
        api, ui, fmt, term, logo,
        act: (name, req) => runAction(name, req),
        go: (path) => { openPath(path); app.focus = 'page'; },
        refresh: () => loadPage(app.page, true),
        // Refresh every page, as the web console's Refresh button does.
        refreshAll: () => { for (let p in app.pages) app.pages[p].loaded = 0; loadPage(app.page); },
        later: (seconds, fn) => push(app.timers, { at: time() + seconds, fn }),
        flash: (text, tone) => flash(text, tone),
        confirm: (text, label, fn, danger) => {
            app.dialog = { kind: 'confirm', text, label, fn, danger, cursor: 0 };
            app.dirty = true;
        },
        pick: (title, options, value, fn) => {
            let cursor = 0;
            for (let i = 0; i < length(options); i++) if (options[i].value == value) cursor = i;
            app.dialog = { kind: 'pick', title, options, fn, cursor };
            app.dirty = true;
        },
        session: () => app.session,
        isConsole: () => app.console,
        addr: () => app.addr,
        signIn: (session) => {
            app.session = session;
            app.token = session.token;
            api.useToken(app.token);
            app.lastCheck = time();
            app.pages = {};
            openPath(session.mustChangePassword ? '/password' : '/');
            app.focus = session.mustChangePassword ? 'page' : 'nav';
            app.navCursor = 0;
        },
        passwordChanged: () => {
            app.session.mustChangePassword = false;
            app.pages = {};
            openPath('/');
            app.focus = 'nav';
        },
        signOut: (why) => signOut(why),
        browse: () => { app.browsing = true; openPath('/signin'); },
        browsing: () => app.browsing,
        // Where a finished claim lands: the console if signed in, sign-in if not.
        home: () => { openPath(signedIn() ? '/' : '/signin'); },
        // Another page's module, to show inside this one.
        page: (name) => load('pages/' + name)(makeCtx()),
        banner: (width) => banner(width),
        qr: (text) => qr(text),
        // Where focus starts, as autofocus does in the web console: the field
        // somebody is about to type into.
        focus: (key) => { app.focusKey[app.path] = key; app.focus = 'page'; },
        width: () => app.view ? app.view.width : 60,
    };
};

runAction = function(name, req) {
    flash('Working', 'neutral');
    draw();
    let r;
    try { r = api.act(name, req ?? {}, app.session); }
    catch (e) {
        warn(sprintf('pulzr-tui: %s: %s\n%s\n', name, e.message ?? e, e.stacktrace ?? ''));
        r = { error: 'Internal error.' };
    }
    flash(null);
    app.dirty = true;
    return r ?? {};
};

signOut = function(why) {
    if (app.token) { try { api.auth.destroySession(app.token); } catch (e) {} }
    app.session = null;
    app.token = null;
    api.useToken(null);
    app.pages = {};
    app.browsing = false;
    app.focus = 'page';
    openPath('/signin');
    if (why) flash(why, 'warning');
};

// The mark beside the wordmark, as the login banner draws it (pulzr-motd),
// for the sign-in screen and a screen tall enough to spare it the rows.
const bannerCache = {};
banner = function(width) {
    if (bannerCache[width]) return bannerCache[width];
    const env = logo.detect(true);
    env.path = LIB + '/../logo.txt';
    env.utf8 = env.utf8 && term.state.utf8;
    // The Linux console folds 256 colours to its own sixteen badly; see
    // logo.uc. Its sixteen are chosen for it.
    if (term.state.local) env.depth = 16;
    if (!term.state.color) env.depth = 0;
    const mark = logo.render(env);
    const cols = length(mark) ? logo.width(env) : 0;
    let text = [];
    if (width >= cols + 3 + 39) {
        const p = _m_fs.popen('/usr/sbin/pulzr-figlet -f /usr/share/pulzr/fonts/slant.flf -- Pulzr 2>/dev/null', 'r');
        if (p) { text = filter(split(p.read('all') ?? '', '\n'), (l) => length(trim(l))); p.close(); }
    }
    text = length(text) ? map(text, (l) => ui.style(l, 'bold')) : [ ui.style('Pulzr', 'accent') ];
    bannerCache[width] = length(mark) ? logo.beside(mark, text, cols) : text;
    return bannerCache[width];
};

// A QR code as lines of text, as qrencode draws it for the SSH banner (see
// pulzr-claim): half blocks with explicit black and white, so it scans on
// any background. Whole cells on a terminal that is not UTF-8; those are twice
// as wide. null when it cannot be drawn.
qr = function(text) {
    const quoted = "'" + replace(text, /'/g, "'\\''") + "'";
    const p = _m_fs.popen(sprintf('qrencode -t %s -m 1 -- %s 2>/dev/null',
                                  term.state.utf8 ? 'ANSIUTF8' : 'ANSI', quoted), 'r');
    if (!p) return null;
    const raw = p.read('all') ?? '';
    p.close();
    const lines = filter(split(raw, '\n'), (l) => length(l));
    return length(lines) ? lines : null;
};

// ── the loop ────────────────────────────────────────────────────────────────

tick = function() {
    const now = time();

    // A flash fades.
    if (app.message && app.message.until <= now) { app.message = null; app.dirty = true; }

    // Timers a page set: "refresh in four seconds", as the web console does
    // after a join.
    const due = filter(app.timers, (t) => t.at <= now);
    if (length(due)) {
        app.timers = filter(app.timers, (t) => t.at > now);
        for (let t in due) { try { t.fn(); } catch (e) {} }
        app.dirty = true;
    }

    if (app.console && signedIn()) {
        // The session can end without us: it expires, or the web console's
        // sign-out deleted it. Asked every half minute rather than every tick.
        if (app.session.expires && app.session.expires <= now)
            return signOut('Your session has ended. Sign in again.');
        if (now - app.lastCheck >= 30) {
            app.lastCheck = now;
            if (!api.auth.readSession(app.token))
                return signOut('Your session has ended. Sign in again.');
        }
        if (now - app.lastKey >= IDLE_SIGNOUT)
            return signOut('Signed out after fifteen minutes without a key.');
        // A countdown on screen moves once a second.
        if (app.session.kind == 'recovery' || app.session.kind == 'lan') app.dirty = true;
    }

    const page = app.page;
    app.paused = now - app.lastKey >= IDLE_PAUSE;
    if (page && !app.paused && !app.edit && !app.dialog) {
        const every = type(page.interval) == 'function' ? page.interval() : page.interval;
        if (every && now - page.loaded >= every) loadPage(page, true);
    }
};

// Whether anything on screen is waiting on the clock. When nothing is, the
// loop blocks on the keyboard and costs nothing until somebody types.
const live = () => {
    if (length(app.timers) || app.message) return true;
    if (app.console && signedIn()) return true;
    const page = app.page;
    if (!page || app.paused) return false;
    const every = type(page.interval) == 'function' ? page.interval() : page.interval;
    return !!every;
};

loop = function() {
    let repainted = time(), hangups = 0;
    while (!app.quit) {
        tick();
        // A VT is also a kernel console, and printk writes straight over
        // whatever is on it. Send the whole frame again now and then, while
        // anything is live, rather than leave a kernel message across a page.
        if (term.state.local && live() && time() - repainted >= 60) {
            repainted = time();
            term.invalidate();
            app.dirty = true;
        }
        if (app.resized) { app.resized = false; term.size(); app.dirty = true; }
        if (app.dirty) draw();
        term.setMode(live() ? 'poll' : 'wait');
        const before = clock(true);
        const key = term.readKey();
        if (key == null) {
            // A hung-up line — a laptop unplugged from the USB serial port —
            // answers every read at once with nothing, which would spin this
            // loop flat out. A read that came back empty sooner than the tty
            // could have timed it out is that, not a quiet keyboard; enough of
            // them in a row and the line is gone. procd starts the console
            // again for whoever plugs in next.
            const after = clock(true);
            const ms = (after[0] - before[0]) * 1000 + (after[1] - before[1]) / 1000000;
            hangups = ms < 20 ? hangups + 1 : 0;
            if (hangups >= 50) break;
            continue;
        }
        hangups = 0;
        app.lastKey = time();
        if (app.paused) { app.paused = false; loadPage(app.page, true); }
        handleKey(key);
        app.dirty = true;
    }
};

// A shell on this terminal, and back to the console when it exits.
//
// The TUI steps aside rather than running beside it: the terminal goes back to
// cooked mode and the main screen, a login shell runs in the foreground, and
// when it exits the TUI takes the terminal back and draws everything again.
// So the shell is the ordinary one — the banner, job control, Ctrl-C — and
// nothing about it is the TUI's to get wrong.
//
// On a port this needs the console's sign-in first, which is the same bar the
// console sets for everything else it can do, and only a staff session
// passes mayShell. It is journalled like every other action.
shell = function() {
    // Checked here as well as at the key, so a second way to this function
    // is not a second way to a shell.
    if (!mayShell()) return;
    if (app.console) runAction('openShell', { tty: app.tty });

    term.close();
    // The system's own, never $SHELL: what a session's environment names is
    // not the TUI's to run as root.
    const sh = _m_fs.access('/bin/ash') ? '/bin/ash' : '/bin/sh';
    // Written and flushed before the shell starts, or it lands after the
    // shell's own banner.
    _m_fs.stdout.write('\nexit returns to the Pulzr console.\n\n');
    _m_fs.stdout.flush();

    // Ctrl-C and Ctrl-Z belong to the shell while it runs. Caught here with a
    // handler that does nothing — not ignored, because an ignored signal
    // stays ignored across exec and the shell would inherit it, where a caught
    // one goes back to its default in the child.
    const quiet = () => null;
    for (let sig in [ 'SIGINT', 'SIGQUIT', 'SIGTSTP' ]) signal(sig, quiet);

    // On a port, an idle shell logs itself out after the console's own idle
    // time, where the shell supports it.
    const argv = app.console ? [ '/usr/bin/env', sprintf('TMOUT=%d', IDLE_SIGNOUT), sh, '-l' ] : [ sh, '-l' ];
    try { system(argv); } catch (e) {}

    for (let sig in [ 'SIGINT', 'SIGQUIT', 'SIGTSTP' ]) signal(sig, 'default');
    term.open(app.termOpts);
    app.lastKey = time();
    app.dirty = true;
    // The world may have moved while the shell was open.
    if (app.page) loadPage(app.page, true);
};

// `!` for everybody else signed in: logs and link state at a prompt that runs
// fixed programs and nothing typed (diag.uc). An organization's admin at a
// port needs the logs; the shell under them is Pulzr's.
diagnostics = function() {
    term.close();
    const quiet = () => null;
    for (let sig in [ 'SIGINT', 'SIGQUIT', 'SIGTSTP' ]) signal(sig, quiet);
    try { diag(api); } catch (e) {}
    for (let sig in [ 'SIGINT', 'SIGQUIT', 'SIGTSTP' ]) signal(sig, 'default');
    term.open(app.termOpts);
    app.lastKey = time();
    app.dirty = true;
    if (app.page) loadPage(app.page, true);
};

quit = function() {
    if (app.console) {
        if (signedIn()) app.dialog = { kind: 'confirm', text: 'Sign out?', label: 'Sign out',
                                       fn: () => signOut(), cursor: 0 };
        return;
    }
    app.quit = true;
};

// ── keys ────────────────────────────────────────────────────────────────────

handleKey = function(key) {
    if (key == 'ctrl-l') { term.size(); term.invalidate(); return; }
    // A port's console never exits: it is the port's program. Over SSH it is
    // a session somebody opened, so Ctrl-C ends it from anywhere — a field
    // being typed in included — signing out on the way.
    if (key == 'ctrl-c' && app.ssh) { app.quit = true; return; }
    if (app.dialog) return handleDialog(key);
    if (app.edit) return handleEdit(key);
    if (key == 'ctrl-c' && !app.console) { app.quit = true; return; }

    const full = !signedIn() || app.path == '/password';
    if (full) app.focus = 'page';

    // `!` for a shell, as less, vi and mutt have it. Not before sign-in, not
    // before a forced password change; a real shell only for a session
    // mayShell allows, the diagnostic prompt for every other.
    if (key == '!' && !full) return mayShell() ? shell() : diagnostics();

    if (app.focus == 'nav') {
        const entries = navEntries();
        if (key == 'up' || key == 'k') app.navCursor = app.navCursor > 0 ? app.navCursor - 1 : length(entries) - 1;
        else if (key == 'down' || key == 'j') app.navCursor = (app.navCursor + 1) % length(entries);
        else if (key == 'enter' || key == 'right' || key == 'tab' || key == ' ' || key == 'l') {
            const e = entries[app.navCursor];
            if (e.path != app.path) openPath(e.path);
            app.focus = 'page';
            // Children appear under a group once it is open; keep the cursor
            // on the entry that was opened.
            const after = navEntries();
            for (let i = 0; i < length(after); i++) if (after[i].path == app.path) app.navCursor = i;
        }
        else if (key == 'r') { if (app.page) { app.page.loaded = 0; loadPage(app.page); } }
        else if (key == 'q' || key == 'ctrl-c') quit();
        return;
    }

    const items = app.view ? app.view.items : [];
    const at = (() => { for (let i = 0; i < length(items); i++) if (items[i].key == app.focusKey[app.path]) return i; return -1; })();
    const item = at >= 0 ? items[at] : null;

    switch (key) {
    case 'up': case 'shift-tab': case 'k':
        return moveFocus(-1);
    case 'down': case 'tab': case 'j':
        return moveFocus(1);
    case 'right': case 'l':
        if (item && item.row && at + 1 < length(items) && items[at + 1].row == item.row)
            app.focusKey[app.path] = items[at + 1].key;
        return;
    case 'left': case 'h':
        if (item && item.row && at > 0 && items[at - 1].row == item.row) {
            app.focusKey[app.path] = items[at - 1].key;
            return;
        }
        if (!full) app.focus = 'nav';
        return;
    case 'esc':
        if (app.page && app.page.back && app.page.back()) return;
        if (!full) app.focus = 'nav';
        return;
    // Paging lets go of the focus, so the page can scroll past it; `false`
    // rather than null says that was deliberate. The next arrow picks up
    // from what is on screen.
    case 'pgup':
        app.scroll[app.path] = (app.scroll[app.path] ?? 0) - (app.view.height - 2);
        app.focusKey[app.path] = false;
        return;
    case 'pgdn':
        app.scroll[app.path] = (app.scroll[app.path] ?? 0) + (app.view.height - 2);
        app.focusKey[app.path] = false;
        return;
    case 'home':
        app.scroll[app.path] = 0;
        return;
    case 'enter': case ' ':
        if (item) activate(item);
        return;
    case 'r':
        if (app.page) { app.page.loaded = 0; loadPage(app.page); }
        return;
    case 'q':
        if (full && app.console) return;
        return quit();
    }

    // A page may take keys of its own: the log's search, a table's sort.
    if (app.page && app.page.key) app.page.key(key);
};

// Focus moves through the items; on a page with none, the arrows scroll.
// Below the last item they scroll on through the rest of the page (the
// processes under All processes, a long table), letting go of the focus as
// paging does, so Enter never acts on a control that has scrolled away. They
// used to stop at the last item, and what lay under it was out of reach
// without Page Down.
moveFocus = function(dir) {
    const items = app.view ? app.view.items : [];
    const top = app.scroll[app.path] ?? 0;
    const bottom = top + (app.view ? app.view.height : 0);
    const more = app.view && bottom < length(app.view.lines);
    const scrollBy = function(d) {
        app.scroll[app.path] = top + d;
        app.focusKey[app.path] = false;
    };
    if (!length(items)) return scrollBy(dir);
    let at = -1;
    for (let i = 0; i < length(items); i++) if (items[i].key == app.focusKey[app.path]) at = i;
    if (at < 0) {
        // Nothing focused (paged, or scrolled past the last item): pick up
        // from what is on screen rather than jumping back to the top, and
        // scroll while there is nothing to land on in that direction.
        if (dir > 0) {
            if (more && !length(filter(items, (it) => it.line >= bottom))) return scrollBy(1);
            for (let it in items) if (it.line >= top) { app.focusKey[app.path] = it.key; return; }
            return;
        }
        let low = null;
        for (let it in items) if (it.line >= top && it.line < bottom) low = it;
        if (low) { app.focusKey[app.path] = low.key; return; }
        if (!length(filter(items, (it) => it.line < top))) { app.focusKey[app.path] = items[0].key; return; }
        return scrollBy(-1);
    }
    let next = at + dir;
    if (next < 0) {
        // Above the first item there is only the page's top.
        app.scroll[app.path] = 0;
        next = 0;
    }
    if (next >= length(items)) {
        if (more) scrollBy(1);
        return;
    }
    app.focusKey[app.path] = items[next].key;
};

activate = function(item) {
    if (item.disabled) return;
    switch (item.t) {
    case 'field':
        // Characters, not bytes: a UTF-8 SSID is several bytes a letter.
        app.edit = { item: item.key, cursor: 0 };
        app.edit.chars = (() => {
            const out = [], s = item.value ?? '';
            let i = 0;
            while (i < length(s)) {
                let j = i + 1;
                while (j < length(s) && ord(s, j) >= 0x80 && ord(s, j) < 0xc0) j++;
                push(out, substr(s, i, j - i));
                i = j;
            }
            return out;
        })();
        app.edit.cursor = length(app.edit.chars);
        app.edit.field = item;
        return;
    case 'check':
        return item.set(!item.checked);
    case 'choice':
        return makeCtx().pick(item.label, item.options, item.value, item.set);
    default:
        if (item.confirm)
            return makeCtx().confirm(item.confirm, item.confirmLabel ?? item.label, item.run, item.danger);
        if (item.run) item.run();
    }
};

handleEdit = function(key) {
    const e = app.edit;
    const commit = () => { e.field.set(join('', e.chars)); app.edit = null; };
    switch (key) {
    case 'enter':
        commit();
        if (e.field.submit) e.field.submit();
        else moveFocus(1);
        return;
    case 'tab': case 'down': commit(); return moveFocus(1);
    case 'shift-tab': case 'up': commit(); return moveFocus(-1);
    case 'esc': case 'ctrl-c': app.edit = null; return;
    case 'left': if (e.cursor > 0) e.cursor--; return;
    case 'right': if (e.cursor < length(e.chars)) e.cursor++; return;
    case 'home': e.cursor = 0; return;
    case 'end': e.cursor = length(e.chars); return;
    case 'ctrl-u': e.chars = []; e.cursor = 0; return;
    case 'backspace':
        if (e.cursor > 0) { splice(e.chars, e.cursor - 1, 1); e.cursor--; }
        return;
    case 'delete':
        if (e.cursor < length(e.chars)) splice(e.chars, e.cursor, 1);
        return;
    }
    // Anything printable is typed. Named keys are longer than one column.
    if (term.cols(key) == 1 && ord(key, 0) >= 32) {
        if (e.field.max && length(e.chars) >= e.field.max) return;
        splice(e.chars, e.cursor, 0, key);
        e.cursor++;
    }
};

handleDialog = function(key) {
    const d = app.dialog;
    if (d.kind == 'confirm') {
        if (key == 'left' || key == 'right' || key == 'tab' || key == 'h' || key == 'l') d.cursor = 1 - d.cursor;
        else if (key == 'esc' || key == 'n') app.dialog = null;
        else if (key == 'enter' || key == ' ' || key == 'y') {
            app.dialog = null;
            if (d.cursor == 0 || key == 'y') d.fn();
        }
        return;
    }
    // A picker.
    const n = length(d.options);
    const step = (dir) => {
        for (let i = 1; i <= n; i++) {
            const c = (d.cursor + dir * i + n * 2) % n;
            if (!d.options[c].disabled) { d.cursor = c; return; }
        }
    };
    if (key == 'up' || key == 'k') step(-1);
    else if (key == 'down' || key == 'j' || key == 'tab') step(1);
    else if (key == 'esc') app.dialog = null;
    else if (key == 'enter' || key == ' ') {
        const o = d.options[d.cursor];
        if (o.disabled) return;
        app.dialog = null;
        d.fn(o.value);
    }
};

// ── drawing ─────────────────────────────────────────────────────────────────

// The sidebar as it stands: a group's children show while it is open. Only
// what the cursor can land on; the first entry under a heading carries it,
// for drawNav, so a heading with nothing shown under it never appears.
navEntries = function() {
    const out = [];
    for (let g in NAV_GROUPS) {
        let heading = g.label;
        for (let e in g.entries) {
            if (!shown(e)) continue;
            const kids = e.children ? filter(e.children, shown) : null;
            if (kids && !length(kids)) continue;
            push(out, { path: e.path, label: e.label, depth: 0, heading: heading });
            heading = null;
            if (kids && index(app.path, e.path) == 0 && e.path != '/')
                for (let c in kids) push(out, { path: c.path, label: c.label, depth: 1 });
        }
    }
    return out;
};

drawHeader = function(width) {
    let left = ' ' + ui.style('Pulzr', 'accent');
    let host = '';
    try { host = trim(_m_fs.readfile('/proc/sys/kernel/hostname') ?? ''); } catch (e) {}
    if (length(host)) left += '  ' + ui.style(host, 'dim');

    let right = '';
    const s = app.session;
    if (s) {
        const left_ = s.expires ? s.expires - time() : null;
        if (s.kind == 'recovery') right = ui.style('Recovery session ' + fmt.countdown(left_) + ' left', 'warning');
        else if (s.kind == 'lan') right = ui.style('LAN access ' + fmt.countdown(left_), 'warning');
        else if (s.kind == 'shell') right = ui.style(s.subject, 'dim');
        else if (s.kind == 'remote') right = ui.style('via ' + s.subject, 'dim');
        // The web console's sidebar footer, word for word.
        else right = ui.style(s.subject + ' ' + ui.glyph('dot') + ' '
                              + (s.kind == 'sso' ? 'via Pulzr' : 'local sign-in'), 'dim');
    }
    if (app.paused) right = ui.style('Paused', 'dim') + (length(right) ? '  ' + right : '');
    const gap = width - term.cols(left) - term.cols(right) - 1;
    return left + sprintf('%' + (gap > 1 ? gap : 1) + 's', '') + right;
};

drawNav = function(height) {
    const entries = navEntries();
    // A blank row above each heading, as app.pulzr.net spaces its groups,
    // while the list still fits; a short terminal keeps the headings only,
    // and one too short for those drops them rather than an entry.
    let headings = 0;
    for (let e in entries) if (e.heading) headings++;
    const spaced = length(entries) + 2 * headings <= height;
    const headed = length(entries) + headings <= height;
    const out = [];
    for (let i = 0; i < length(entries); i++) {
        const e = entries[i];
        if (e.heading && headed) {
            if (spaced) push(out, term.pad('', NAV_WIDTH));
            push(out, ui.style(term.pad(' ' + uc(e.heading), NAV_WIDTH), 'dim'));
        }
        const active = e.path == app.path || (e.depth == 0 && e.path != '/' && index(app.path, e.path) == 0
                       && !length(filter(entries, (c) => c.depth == 1 && c.path == app.path)));
        const here = e.path == app.path;
        let text = term.pad((e.depth ? '   ' : ' ') + e.label, NAV_WIDTH);
        if (app.focus == 'nav' && i == app.navCursor) text = ui.style(text, 'reverse', here ? 'bold' : null);
        else if (here || active) text = ui.style(text, 'bold', 'accent');
        else if (e.depth == 0 && index(app.path, e.path) == 0 && e.path != '/') text = ui.style(text, 'bold');
        push(out, text);
    }
    while (length(out) < height) push(out, term.pad('', NAV_WIDTH));
    return out;
};

// What the content pane shows: the banners every page carries, then the page,
// or a dialog in its place.
bodyBlocks = function(width) {
    const page = app.page;
    if (!page) return [];
    const blocks = [];

    if (signedIn() && app.path != '/password') {
        const s = app.session;
        if (s.kind == 'recovery')
            push(blocks, { t: 'notice', tone: 'warning',
                text: 'Recovery session ' + ui.glyph('dash') + ' granted by Pulzr for offline access. Normal sign-in resumes once this gateway is back online.' });
        if (app.unadopted && app.path != '/adopt') {
            push(blocks, { t: 'notice', tone: 'warning',
                text: 'Not adopted. This gateway is not managed by any organization. Its configuration is local only, and adoption will replace it.' });
            push(blocks, { t: 'buttons', items: [ { label: 'Adopt it', key: 'banner:adopt', run: () => makeCtx().go('/adopt') } ] });
        }
        if (app.reclaiming && app.path != '/adopt') {
            push(blocks, { t: 'notice', tone: 'warning',
                text: 'Claim revoked. Pulzr refuses this gateway\'s reports until its new claim is adopted.' });
            push(blocks, { t: 'buttons', items: [ { label: 'Show the claim', key: 'banner:adopt', run: () => makeCtx().go('/adopt') } ] });
        }
        if (length(blocks)) push(blocks, { t: 'blank' });
    }

    if (page.error) {
        push(blocks, { t: 'notice', tone: 'error', text: page.error });
        push(blocks, { t: 'buttons', items: [ { label: 'Try again', key: 'page:retry', run: () => loadPage(page) } ] });
        return blocks;
    }
    if (!page.loaded && page.load) return blocks;
    for (let b in page.view(width)) push(blocks, b);
    return blocks;
};

// A dialog, drawn as a box in the content pane.
const dialogLines = (width) => {
    const d = app.dialog;
    const w = width > 60 ? 60 : width;
    const out = [ '' ];
    const frame = (s) => ' ' + term.pad(s, w - 2);
    if (d.kind == 'confirm') {
        for (let l in ui.wrap(d.text, w - 4)) push(out, frame(' ' + ui.style(l, 'bold')));
        push(out, '');
        const yes = ui.style('[ ' + d.label + ' ]', d.danger ? 'danger' : 'bold', d.cursor == 0 ? 'reverse' : null);
        const no = ui.style('[ Cancel ]', d.cursor == 1 ? 'reverse' : null);
        push(out, frame(' ' + yes + '  ' + no));
    } else {
        push(out, frame(' ' + ui.style(d.title, 'bold')));
        push(out, '');
        for (let i = 0; i < length(d.options); i++) {
            const o = d.options[i];
            let text = term.pad(' ' + o.label, w - 4);
            if (o.disabled) text = ui.style(text, 'dim');
            push(out, frame(' ' + (i == d.cursor ? ui.style(text, 'reverse') : text)));
        }
    }
    return out;
};

layoutBody = function(width, height) {
    if (app.dialog) return { lines: dialogLines(width), items: [], width, height };
    const blocks = bodyBlocks(width);
    const r = ui.render(blocks, width, app.focusKey[app.path], app.edit);
    r.width = width;
    r.height = height;

    // Keep focus on something that exists. A refresh can remove the focused
    // control (a button that only shows in one state); land on its neighbour.
    const key = app.focusKey[app.path];
    if (key === false || !length(r.items)) return r;
    for (let i = 0; i < length(r.items); i++)
        if (r.items[i].key == key) { app.focusIndex[app.path] = i; return r; }

    // Nothing focused yet, or the focused control is gone — a refresh can
    // replace one that only shows in one state, as "Check certificate"
    // becomes "Trust and join". Land on whatever is now where it was, not
    // back at the top of the page.
    let at = app.focusIndex[app.path] ?? 0;
    if (at >= length(r.items)) at = length(r.items) - 1;
    app.focusKey[app.path] = r.items[at].key;
    app.focusIndex[app.path] = at;
    if (app.edit) app.edit = null;
    const again = ui.render(blocks, width, app.focusKey[app.path], app.edit);
    again.width = width; again.height = height;
    return again;
};

drawBody = function(width, height) {
    const r = layoutBody(width, height);
    app.view = r;
    let scroll = app.scroll[app.path] ?? 0;
    const key = app.focusKey[app.path];
    if (key && app.focus == 'page' && !app.dialog) {
        for (let it in r.items) if (it.key == key) {
            // A section heading or a notice just above the focused control
            // belongs with it, so leave two lines of context when scrolling up.
            if (it.line < scroll) scroll = it.line - 2;
            if (it.line >= scroll + height) scroll = it.line - height + 1;
        }
    }
    const max = length(r.lines) - height;
    if (scroll > max) scroll = max;
    if (scroll < 0) scroll = 0;
    app.scroll[app.path] = scroll;
    const out = [];
    for (let i = 0; i < height; i++) {
        const l = r.lines[scroll + i];
        push(out, l != null ? l : '');
    }
    return out;
};

drawFooter = function(width) {
    if (app.message)
        return ' ' + ui.style(term.clip(app.message.text, width - 2), app.message.tone == 'neutral' ? 'dim' : app.message.tone);
    let keys;
    if (app.dialog) keys = app.dialog.kind == 'confirm' ? 'Enter Confirm  Esc Cancel' : 'Enter Choose  Esc Cancel';
    else if (app.edit) keys = 'Enter Save  Esc Cancel';
    else {
        const shellKey = !signedIn() ? '' : mayShell() ? '! Shell  ' : '! Diagnostics  ';
        const quitKey = (app.console ? 'q Sign out' : 'q Quit') + (app.ssh ? '  Ctrl-C Disconnect' : '');
        if (app.focus == 'nav') keys = 'Enter Open  r Refresh  ' + shellKey + quitKey;
        else keys = signedIn() && app.path != '/password'
            ? 'Enter Select  Esc Menu  r Refresh  ' + shellKey + quitKey
            : 'Enter Select' + (app.ssh ? '  Ctrl-C Disconnect' : '');
    }
    return ' ' + ui.style(term.clip(keys, width - 2), 'dim');
};

draw = function() {
    const W = term.state.cols, H = term.state.rows;
    const lines = [];
    push(lines, drawHeader(W));
    push(lines, ui.style(ui.rule(W), 'dim'));
    const bodyHeight = H - 3;

    const full = !signedIn() || app.path == '/password';
    // Narrow: the menu and the page take turns rather than sharing a row.
    const narrow = W < NAV_WIDTH + 44;
    if (full || (narrow && app.focus == 'page')) {
        const width = full ? (W - 4 > 72 ? 72 : W - 4) : W - 2;
        const indent = full ? sprintf('%' + int((W - width) / 2) + 's', '') : ' ';
        for (let l in drawBody(width, bodyHeight)) push(lines, indent + l);
    } else if (narrow) {
        for (let l in drawNav(bodyHeight)) push(lines, l);
    } else {
        const nav = drawNav(bodyHeight);
        const body = drawBody(W - NAV_WIDTH - 3, bodyHeight);
        const sep = ui.style(ui.glyph('vline'), 'dim');
        for (let i = 0; i < bodyHeight; i++) push(lines, nav[i] + sep + ' ' + body[i]);
    }

    push(lines, drawFooter(W));
    term.present(lines);
    app.dirty = false;
};

// ── start ───────────────────────────────────────────────────────────────────

start = function(opts) {
    app.console = !!opts.console;
    app.remote = !app.console && !!opts.remote;
    // From the image, not from anything a session can change: board.conf is
    // written by build.sh, and writing it on a gateway takes root already.
    app.dev = match(_m_fs.readfile('/etc/pulzr/board.conf') ?? '', /(^|\n)PULZR_DEV='1'/) != null;
    app.tty = opts.tty;
    app.addr = 'tty:' + replace(opts.tty ?? 'shell', /^\/dev\//, '');
    // Over SSH as `pulzr`, sign-in failures count against the address they
    // came from. Counted against one name for every SSH session, somebody on
    // the site network could lock every technician out with a few guesses.
    const ssh = split(getenv('SSH_CONNECTION') ?? '', ' ');
    app.ssh = app.console && !opts.tty && length(ssh[0]) > 0;
    if (app.ssh) app.addr = 'ssh:' + ssh[0];

    const env = logo.detect(true);
    app.termOpts = { tty: opts.tty, utf8: env.utf8, color: env.depth > 0,
                     forced: getenv('PULZR_ASCII') == '1' };
    term.open(app.termOpts);
    ui.init(term);
    term.setTitle('Pulzr');

    signal('SIGWINCH', () => { app.resized = true; });

    // Audit records name the session's subject. Pulzr Cloud knows which of
    // its people opened a remote session and records it there; here it is
    // the network that did.
    if (app.remote) {
        app.session = { subject: 'Pulzar Cloud', kind: 'remote' };
        app.focus = 'nav';
    }
    else if (!app.console) {
        app.session = { subject: 'root', kind: 'shell' };
        app.focus = 'nav';
    }
    // Not adopted: the web console shows its claim screen before anything
    // else, and a banner with a way back to it once signed in.
    try { app.unadopted = !api.claim.isAdopted(); app.reclaiming = api.claim.reclaiming(); }
    catch (e) { app.unadopted = false; app.reclaiming = false; }

    openPath(signedIn() ? '/' : '/signin');
    if (!signedIn()) app.focus = 'page';

    try { loop(); }
    catch (e) {
        term.close();
        warn(sprintf('pulzr-tui: %s\n%s\n', e.message ?? e, e.stacktrace ?? ''));
        return 1;
    }
    if (app.token) { try { api.auth.destroySession(app.token); } catch (e) {} }
    term.close();
    return 0;
};

return { start };
