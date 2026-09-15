// System overview: what this gateway is, and how it is doing.

let _m_fs = require('fs');
let readfile = _m_fs.readfile;
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
let boardConf, summary, thermal, logs, reboot;

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
            openwrt:  boardInfo ? boardInfo.release : null,
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

// ── module exports ──────────────────────────────────────────────────────────
//
// A returned object, not `export` statements. uhttpd's ucode plugin compiles
// its handler in TEMPLATE mode and loads anything else through loadfile(),
// neither of which is module mode — `export` is a syntax error there. See the
// header of api/index.uc for the full contract.
return { logs, reboot, summary };
