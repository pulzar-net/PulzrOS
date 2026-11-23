// System overview: what this gateway is, and how it is doing.

let _m_fs = require('fs');
let readfile = _m_fs.readfile;; let writefile = _m_fs.writefile;; let lsdir = _m_fs.lsdir;
let _m_uci = require('uci');
let cursor = _m_uci.cursor;
let _m_util = loadfile('/usr/share/pulzr/console/lib/util.uc', { raw_mode: true })();

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
let boardConf, features, summary, thermal, stats, history, processes, logs, reboot, uart, setUart;

let run = _m_util.run;; let runJson = _m_util.runJson;; let ubus = _m_util.ubus;

// That a setting changed here waits on a reboot. On tmpfs, so the reboot
// clears it. Not /etc/pulzr/boot-config-reboot-pending: that one is first
// boot's, and pulzr-boot-config-reboot acts on it at every boot, so writing
// it from here rebooted the gateway a second time after somebody's own reboot.
const REBOOT_REQUIRED = '/var/run/pulzr/reboot-required';

boardConf = function() {
    // /etc/pulzr/board.conf is shell, not JSON. Parsed here rather than
    // sourced, because sourcing attacker-controllable shell would be a
    // remote-code-execution hole — and while this file is written by our own
    // build, a parser that cannot execute anything is the right default for a
    // file the console reads on every page load.
    const raw = readfile('/etc/pulzr/board.conf');
    const out = {};
    if (!raw) return out;
    for (let line in split(raw, '\n')) {
        const m = match(trim(line), /^([A-Za-z_][A-Za-z0-9_]*)='?([^']*)'?$/);
        if (m) out[m[1]] = m[2];
    }
    return out;
};

// The board's features, from the image it was built as (PULZR_FEATURES, see
// boards/common/board.conf), and each installed add-on's word (lorawan). Not
// settable here: a feature is a package on the gateway, and a page for a
// package that is not there is a page of errors.
//
// An add-on counts as installed while its addon-health script is there: that
// file is the package's own, so apk takes it away with the package, and a
// file test is cheap enough for every request this is asked on. Which add-on
// brings which word is addons.caps, from this firmware (pulzr-addon).
features = function() {
    const out = filter(split(boardConf().PULZR_FEATURES ?? '', ' '), (w) => length(w) > 0);
    for (let line in split(readfile('/usr/share/pulzr/addons.caps') ?? '', '\n')) {
        const f = split(line, '\t');
        if (length(f) < 2 || substr(line, 0, 1) == '#' || f[1] == '-') continue;
        if (!match(f[0], /^[a-z0-9-]{1,40}$/) || !match(f[1], /^[a-z0-9-]{1,40}$/)) continue;
        if (_m_fs.access('/usr/libexec/pulzr/addon-health/' + f[0]) && !(f[1] in out))
            push(out, f[1]);
    }
    // gnss is the board's receiver, and pulzr-lorawan drives it: concentratord
    // holds the port for GPS time and PPS (pulzr-gps). A Pi without the add-on
    // has the word and nothing behind its page.
    if (!('lorawan' in out))
        return filter(out, (w) => w != 'gnss');
    return out;
};

summary = function() {
    const uci = cursor();
    const board = boardConf();
    const info = ubus('system', 'info');
    const boardInfo = ubus('system', 'board');

    return {
        identity: {
            hostname:   uci.get('pulzr', 'identity', 'hostname'),
            gatewayEui: uci.get('pulzr', 'identity', 'gateway_eui'),
            serial:     uci.get('pulzr', 'identity', 'serial'),
            // Surfaced because a randomly-derived serial means this gateway
            // will not recognise itself after a reflash, and support needs to
            // see that without reading a log.
            serialSource: uci.get('pulzr', 'identity', 'serial_source'),
            board:      board.BOARD_ID,
            boardName:  board.BOARD_NAME,
        },
        firmware: {
            version:  board.PULZR_VERSION,
            build:    board.PULZR_BUILD,
            commit:   board.PULZR_COMMIT,
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
            state: uci.get('pulzr', 'adoption', 'state'),
            org:   uci.get('pulzr', 'adoption', 'org'),
            since: uci.get('pulzr', 'adoption', 'since'),
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
    const applied = runJson('/usr/sbin/pulzr-boot-config --dry-run') ?? {};
    return {
        role: uci.get('pulzr', 'hardware', 'uart_role') ?? 'console',
        // False on a board with no Pi boot partition, where this is moot.
        applies: applied.applies !== false,
        // Set once the firmware settings on disk match the role, which is only
        // true after the reboot that reads them.
        pending: !!readfile(REBOOT_REQUIRED),
    };
};

setUart = function(role) {
    if (role != 'console' && role != 'gps')
        return { error: 'Role must be console or gps.' };

    const uci = cursor();
    uci.set('pulzr', 'hardware', 'uart_role', role);
    uci.commit('pulzr');

    // Applied to the boot files now, but the Pi firmware only reads them at
    // boot — so this reports whether a reboot is needed rather than doing one.
    const result = runJson('/usr/sbin/pulzr-boot-config') ?? {};
    if (result.changed) { _m_fs.mkdir('/var/run/pulzr'); writefile(REBOOT_REQUIRED, ''); }
    return { ok: true, role, rebootRequired: !!result.changed };
};

// ── module exports ──────────────────────────────────────────────────────────
//
// A returned object, not `export` statements. uhttpd's ucode plugin compiles
// its handler in TEMPLATE mode and loads anything else through loadfile(),
// neither of which is module mode — `export` is a syntax error there. See the
// header of api/index.uc for the full contract.
// ── resources ───────────────────────────────────────────────────────────────
//
// Everything the kernel will say about the machine, read straight from /proc
// and /sys. Raw where a rate needs two readings — CPU time is returned as
// counters and the console works out usage from successive polls, rather than
// this sleeping inside a request to take two samples itself.
//
// Sensors are listed only where the board has them. A RAK7289CV2 exposes no
// thermal zone, hwmon device or power supply at all, and an empty section says
// that more honestly than a temperature of zero.

const MOUNTS = {
    '/rom': 'Firmware',
    '/overlay': 'Configuration',
    '/tmp': 'Temporary',
    '/mnt/storage': 'SD card',
};

stats = function() {
    const lines = (path) => split(readfile(path) ?? '', '\n');
    const number = (path) => {
        const raw = readfile(path);
        return raw == null ? null : int(trim(raw));
    };

    // CPU: the aggregate line of /proc/stat. Idle includes iowait.
    const cpuTimes = map(slice(split(trim(lines('/proc/stat')[0] ?? ''), /\s+/), 1), (x) => int(x));
    let total = 0;
    for (let t in cpuTimes) total += t;
    const idle = (cpuTimes[3] ?? 0) + (cpuTimes[4] ?? 0);

    const cpuinfo = {};
    let cores = 0;
    for (let line in lines('/proc/cpuinfo')) {
        const m = match(line, /^([^\t:]+?)\s*:\s*(.*)$/);
        if (!m) continue;
        if (m[1] == 'processor') cores++;
        if (cpuinfo[m[1]] == null) cpuinfo[m[1]] = m[2];
    }

    const load = split(trim(readfile('/proc/loadavg') ?? ''), ' ');
    const procs = split(load[3] ?? '0/0', '/');

    const meminfo = {};
    for (let line in lines('/proc/meminfo')) {
        const m = match(line, /^(\w+):\s+(\d+)/);
        if (m) meminfo[m[1]] = int(m[2]) * 1024;
    }

    // df rather than statvfs: ucode's fs module has no statvfs on this
    // OpenWrt, and df -kP is one line per mount in a fixed layout.
    const storage = [];
    for (let line in split(run('df -kP 2>/dev/null') ?? '', '\n')) {
        const f = split(trim(line), /\s+/);
        if (length(f) < 6 || !MOUNTS[f[5]]) continue;
        storage[length(storage)] = {
            mount: f[5],
            label: MOUNTS[f[5]],
            device: f[0],
            total: int(f[1]) * 1024,
            used: int(f[2]) * 1024,
            available: int(f[3]) * 1024,
        };
    }

    const temperatures = [];
    for (let zone in (lsdir('/sys/class/thermal') ?? [])) {
        if (!match(zone, /^thermal_zone/)) continue;
        const milli = number(sprintf('/sys/class/thermal/%s/temp', zone));
        if (milli == null) continue;
        temperatures[length(temperatures)] = {
            name: trim(readfile(sprintf('/sys/class/thermal/%s/type', zone)) ?? zone),
            celsius: milli / 1000.0,
        };
    }
    for (let dev in (lsdir('/sys/class/hwmon') ?? [])) {
        const base = sprintf('/sys/class/hwmon/%s', dev);
        const name = trim(readfile(base + '/name') ?? dev);
        for (let file in (lsdir(base) ?? [])) {
            if (!match(file, /^temp\d+_input$/)) continue;
            const milli = number(base + '/' + file);
            if (milli == null) continue;
            temperatures[length(temperatures)] = { name: name, celsius: milli / 1000.0 };
        }
    }

    const power = [];
    for (let supply in (lsdir('/sys/class/power_supply') ?? [])) {
        const base = sprintf('/sys/class/power_supply/%s/', supply);
        const microvolts = number(base + 'voltage_now');
        power[length(power)] = {
            name: supply,
            type: trim(readfile(base + 'type') ?? ''),
            online: number(base + 'online'),
            capacity: number(base + 'capacity'),
            volts: microvolts == null ? null : microvolts / 1000000.0,
        };
    }

    const interfaces = [];
    for (let name in (lsdir('/sys/class/net') ?? [])) {
        if (name == 'lo') continue;
        const base = sprintf('/sys/class/net/%s/', name);
        interfaces[length(interfaces)] = {
            name: name,
            state: trim(readfile(base + 'operstate') ?? 'unknown'),
            rx: number(base + 'statistics/rx_bytes'),
            tx: number(base + 'statistics/tx_bytes'),
        };
    }

    // The heaviest processes by resident memory, which on a 128MB gateway is
    // the resource that runs out first.
    const processes = [];
    for (let pid in (lsdir('/proc') ?? [])) {
        if (!match(pid, /^\d+$/)) continue;
        const status = readfile(sprintf('/proc/%s/status', pid));
        if (!status) continue;
        const name = match(status, /Name:\s+(\S+)/);
        const rss = match(status, /VmRSS:\s+(\d+)/);
        if (!name || !rss) continue;
        processes[length(processes)] = { pid: int(pid), name: name[1], rss: int(rss[1]) * 1024 };
    }
    sort(processes, (a, b) => b.rss - a.rss);

    return {
        uptime: int(split(readfile('/proc/uptime') ?? '0', ' ')[0]),
        cpu: {
            model: cpuinfo['system type'] ?? null,
            core: cpuinfo['cpu model'] ?? null,
            cores: cores || 1,
            bogomips: cpuinfo['BogoMIPS'] ? +cpuinfo['BogoMIPS'] : null,
            total: total,
            idle: idle,
            load: [+load[0], +load[1], +load[2]],
            running: int(procs[0]),
            processes: int(procs[1]),
        },
        memory: {
            total: meminfo.MemTotal ?? 0,
            available: meminfo.MemAvailable ?? meminfo.MemFree ?? 0,
            free: meminfo.MemFree ?? 0,
            cached: meminfo.Cached ?? 0,
            buffers: meminfo.Buffers ?? 0,
            shared: meminfo.Shmem ?? 0,
            swapTotal: meminfo.SwapTotal ?? 0,
            swapFree: meminfo.SwapFree ?? 0,
        },
        storage: storage,
        temperatures: temperatures,
        power: power,
        interfaces: interfaces,
        processes: slice(processes, 0, 10),
    };
};

// The last hour, six hours or day of samples from pulzr-stats. Only those
// three spans: each is a fixed 360 points, and an arbitrary one is a way to ask
// a busy gateway to bucket its whole ring on every poll.
const HISTORY_SPANS = { '3600': true, '21600': true, '86400': true };

// Every process, for the console's process table. CPU is returned as ticks
// alongside the machine's total, and the console turns two polls into a
// percentage, the same way top does.
processes = function() {
    const fields = split(trim(split(readfile('/proc/stat') ?? '', '\n')[0] ?? ''), /\s+/);
    let total = 0;
    for (let i = 1; i < length(fields); i++) total += int(fields[i]);

    const list = [];
    for (let pid in (lsdir('/proc') ?? [])) {
        if (!match(pid, /^\d+$/)) continue;
        const stat = readfile(sprintf('/proc/%s/stat', pid));
        const status = readfile(sprintf('/proc/%s/status', pid));
        if (!stat || !status) continue;
        // The name is in parentheses and may itself contain spaces or
        // parentheses, so the fields are read from after the last ')'.
        const rest = split(trim(substr(stat, rindex(stat, ')') + 2)), ' ');
        const name = match(status, /Name:\s+(\S+)/);
        const rss = match(status, /VmRSS:\s+(\d+)/);
        // Arguments are NUL-separated. Split on the character itself: a regex
        // over the raw string stops at the first NUL and kept only argv[0].
        const command = trim(join(' ', split(readfile(sprintf('/proc/%s/cmdline', pid)) ?? '', chr(0))));
        list[length(list)] = {
            pid: int(pid),
            name: name ? name[1] : '',
            command: substr(command, 0, 240),
            state: rest[0],
            ticks: int(rest[11]) + int(rest[12]),
            threads: int(rest[17]),
            // Kernel threads have no resident set.
            rss: rss ? int(rss[1]) * 1024 : 0,
        };
    }
    return { total: total, processes: list };
};

history = function(queryString) {
    const m = match(queryString ?? '', /span=([0-9]+)/);
    const span = (m && HISTORY_SPANS[m[1]]) ? m[1] : '3600';
    return runJson(sprintf('/usr/sbin/pulzr-stats history %s', span))
        ?? { interval: 20, points: [] };
};

return { features, history, logs, processes, reboot, setUart, stats, summary, uart };
