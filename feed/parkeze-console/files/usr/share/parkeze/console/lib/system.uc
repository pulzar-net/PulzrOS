// System overview: what this gateway is, and how it is doing.

let _m_fs = require('fs');
let readfile = _m_fs.readfile;; let writefile = _m_fs.writefile;
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
let boardConf, summary, thermal, logs, reboot, uart, setUart;

let run = _m_util.run;; let runJson = _m_util.runJson;; let ubus = _m_util.ubus;

boardConf = function() {
    // /etc/parkeze/board.conf is shell, not JSON. Parsed here rather than
    // sourced, because sourcing attacker-controllable shell would be a
    // remote-code-execution hole — and while this file is written by our own
    // build, a parser that cannot execute anything is the right default for a
    // file the console reads on every page load.
    const raw = readfile('/etc/parkeze/board.conf');
    const out = {};
    if (!raw) return out;
    for (let line in split(raw, '\n')) {
        const m = match(trim(line), /^([A-Za-z_][A-Za-z0-9_]*)='?([^']*)'?$/);
        if (m) out[m[1]] = m[2];
    }
    return out;
};

summary = function() {
    const uci = cursor();
    const board = boardConf();
    const info = ubus('system', 'info');
    const boardInfo = ubus('system', 'board');

    return {
        identity: {
            hostname:   uci.get('parkeze', 'identity', 'hostname'),
            gatewayEui: uci.get('parkeze', 'identity', 'gateway_eui'),
            serial:     uci.get('parkeze', 'identity', 'serial'),
            // Surfaced because a randomly-derived serial means this gateway
            // will not recognise itself after a reflash, and support needs to
            // see that without reading a log.
            serialSource: uci.get('parkeze', 'identity', 'serial_source'),
            board:      board.BOARD_ID,
            boardName:  board.BOARD_NAME,
        },
        firmware: {
            version:  board.PARKEZE_VERSION,
            build:    board.PARKEZE_BUILD,
            commit:   board.PARKEZE_COMMIT,
            // A STRING, not the object ubus hands back.
            //
            // `boardInfo.release` is {distribution, version, revision, target,
            // description}. This returned it whole while types.ts declared it
            // `string | null`, so TypeScript trusted the declaration and the
            // console crashed with "Objects are not valid as a React child"
            // the moment anyone reached the Overview page — which, on a
            // gateway that had never been adopted, nobody ever had.
            openwrt:  boardInfo && boardInfo.release
                      ? (boardInfo.release.description
                         ?? (boardInfo.release.distribution ?? '') + ' '
                            + (boardInfo.release.version ?? ''))
                      : null,
            kernel:   boardInfo ? boardInfo.kernel : null,
        },
        adoption: {
            state: uci.get('parkeze', 'adoption', 'state'),
            org:   uci.get('parkeze', 'adoption', 'org'),
            since: uci.get('parkeze', 'adoption', 'since'),
        },
        health: {
            uptime:    info ? info.uptime : null,
            loadavg:   info ? info.load : null,
            memory:    info ? info.memory : null,
            // Board temperature where the SoC exposes it. A gateway in a
            // sealed enclosure in Arizona is a real failure mode and the first
            // thing to check when a concentrator starts dropping packets.
            temperature: thermal(),
        },
    };
};

thermal = function() {
    const raw = readfile('/sys/class/thermal/thermal_zone0/temp');
    if (!raw) return null;
    const milli = int(trim(raw));
    return milli > 1000 ? milli / 1000 : milli;
};

logs = function(queryString) {
    // logread, most recent first. The console paginates; this caps the read so
    // a gateway with a chatty packet forwarder cannot return a 40MB response
    // to a browser over a metered link.
    let lines = 200;
    const m = match(queryString ? queryString : '', /lines=([0-9]+)/);
    if (m) lines = int(m[1]) < 2000 ? int(m[1]) : 2000;

    const out = run(sprintf('logread -l %d', lines));
    return { lines: out ? split(out, '\n') : [] };
};

reboot = function() {
    // Detached, so the HTTP response is actually delivered before the box goes
    // down. A synchronous reboot leaves the browser showing a network error
    // and the operator unsure whether the command landed.
    run('(sleep 2; /sbin/reboot) >/dev/null 2>&1 &');
    return { ok: true, message: 'Rebooting.' };
};

// Who owns the Pi's UART: the kernel console, or a HAT's GNSS.
//
// Settable here because nothing can detect which HAT is fitted, and not every
// board of the same model has the same one — a unit with a Waveshare SX1302
// HAT needs the port for its GNSS, and a unit without one is better off
// keeping the console. The board supplies the default; this is the override.
uart = function() {
    const uci = cursor();
    const applied = runJson('/usr/sbin/parkeze-boot-config --dry-run') ?? {};
    return {
        role: uci.get('parkeze', 'hardware', 'uart_role') ?? 'console',
        // False on a board with no Pi boot partition, where this is moot.
        applies: applied.applies !== false,
        // Set once the firmware settings on disk match the role, which is only
        // true after the reboot that reads them.
        pending: !!readfile('/etc/parkeze/boot-config-reboot-pending'),
    };
};

setUart = function(role) {
    if (role != 'console' && role != 'gps')
        return { error: 'Role must be console or gps.' };

    const uci = cursor();
    uci.set('parkeze', 'hardware', 'uart_role', role);
    uci.commit('parkeze');

    // Applied to the boot files now, but the Pi firmware only reads them at
    // boot — so this reports whether a reboot is needed rather than doing one.
    const result = runJson('/usr/sbin/parkeze-boot-config') ?? {};
    if (result.changed) writefile('/etc/parkeze/boot-config-reboot-pending', '');
    return { ok: true, role, rebootRequired: !!result.changed };
};

// ── module exports ──────────────────────────────────────────────────────────
//
// A returned object, not `export` statements. uhttpd's ucode plugin compiles
// its handler in TEMPLATE mode and loads anything else through loadfile(),
// neither of which is module mode — `export` is a syntax error there. See the
// header of api/index.uc for the full contract.
return { logs, reboot, setUart, summary, uart };
