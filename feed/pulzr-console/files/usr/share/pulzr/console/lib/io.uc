// The front panel, as the console sees it.
//
// Mostly a window onto `pulzr-led --list`: which logical indicator is mapped
// to which physical LED on this board, and which are not mapped at all. That
// last part is the useful bit — an unmapped indicator is not a fault, it is a
// board with fewer lights than the maximum, and the daemon folds its state
// into another one. But a *wrongly* mapped one is silent and invisible, and
// comparing the map against what the kernel actually exposes is how you find
// it.

let _m_fs = require('fs');
let readfile = _m_fs.readfile;; let lsdir = _m_fs.lsdir;
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
let boardLeds, boardValue, boardPanel, ledState, panel, status, test;

let run = _m_util.run;

const LOGICAL = ['power', 'status', 'lora', 'lora2', 'cloud', 'cellular'];
const LEDS = '/sys/class/leds';

boardLeds = function() {
    // /etc/pulzr/board.conf is shell. Parsed rather than sourced: a parser
    // that cannot execute anything is the right default for a file the console
    // reads on every page load.
    const raw = readfile('/etc/pulzr/board.conf');
    const map = {};
    if (!raw) return map;
    for (let line in split(raw, '\n')) {
        const m = match(trim(line), /^PULZR_LED_([A-Z0-9_]+)='?([^']*)'?$/);
        if (m) map[lc(m[1])] = m[2];
    }
    return map;
};

boardValue = function(key) {
    const raw = readfile('/etc/pulzr/board.conf');
    if (!raw) return null;
    const m = match(raw, sprintf("%s='?([^'\n]*)'?", key));
    return m ? m[1] : null;
};

// PULZR_LEDS, the board's own list of its lights (boards/common/board.conf):
// one `<sysfs name> <colour> <role> <label>` per line, in panel order. build.sh
// writes it with its newlines, so it spans lines between its quotes. Null on a
// board that has none.
boardPanel = function() {
    const raw = readfile('/etc/pulzr/board.conf');
    if (!raw) return null;
    const lights = [];
    let inside = false;
    for (let line in split(raw, '\n')) {
        if (!inside) {
            if (substr(line, 0, 12) != "PULZR_LEDS='") continue;
            inside = true;
            line = substr(line, 12);
        }
        const end = index(line, "'");
        const f = match(trim(end >= 0 ? substr(line, 0, end) : line), /^(\S+)\s+(\S+)\s+(\S+)\s+(.+)$/);
        if (f) push(lights, { name: f[1], colour: f[2], role: f[3], label: f[4] });
        if (end >= 0) break;
    }
    return length(lights) ? lights : null;
};

// What a light is doing now: its trigger when one drives it, otherwise on or
// off. An RGB light is whichever of its channels is not off.
ledState = function(name) {
    if (substr(name, 0, 4) == 'rgb:') {
        for (let c in ['red', 'green', 'blue']) {
            const s = ledState(c + ':' + substr(name, 4));
            if (s && s != 'off') return s == 'on' ? c : c + ' ' + s;
        }
        return 'off';
    }
    // The trigger file lists every trigger, the current one in brackets.
    const triggers = readfile(sprintf('%s/%s/trigger', LEDS, name)) ?? '';
    const from = index(triggers, '['), to = index(triggers, ']');
    const trigger = from >= 0 && to > from ? substr(triggers, from + 1, to - from - 1) : 'none';
    if (trigger != 'none') return trigger;
    const brightness = readfile(sprintf('%s/%s/brightness', LEDS, name));
    if (brightness == null) return null;
    return int(trim(brightness)) > 0 ? 'on' : 'off';
};

// The lights to show: the board's list where it has one, and every LED the
// kernel exposes where it does not, each with the role pulzr-io gives it.
panel = function(map, present) {
    const has = (name) => substr(name, 0, 4) == 'rgb:'
        ? length(filter(['red', 'green', 'blue'], (c) => index(present, c + ':' + substr(name, 4)) >= 0)) == 3
        : index(present, name) >= 0;
    const declared = boardPanel();
    if (declared) {
        for (let l in declared) {
            l.present = has(l.name);
            l.state = l.present ? ledState(l.name) : null;
        }
        return { source: 'board', lights: declared };
    }
    const roles = {};
    for (let logical in LOGICAL)
        if (map[logical]) roles[map[logical]] = logical == 'lora2' ? 'lora' : logical;
    const lights = [];
    for (let name in sort([...present])) {
        const colour = match(name, /(^|:)(green|red|orange|amber|yellow|blue|white)(:|$)/);
        push(lights, {
            name: name,
            colour: colour ? colour[2] : null,
            role: roles[name] ?? null,
            label: null,
            present: true,
            state: ledState(name),
        });
    }
    return { source: 'kernel', lights: lights };
};

status = function() {
    const map = boardLeds();
    const present = lsdir(LEDS) || [];

    const leds = [];
    for (let logical in LOGICAL) {
        const physical = map[logical] || null;
        leds[length(leds)] = {
            logical: logical,
            physical: physical,
            // Mapped *and* actually present. A board file naming an LED the
            // kernel does not expose is the exact failure this surfaces.
            present: !!(physical && (index(present, physical) >= 0 ||
                // An RGB light (the RAK7268's breathing light) is three
                // directories, not one; pulzr-led knows how to check them.
                (substr(physical, 0, 4) == 'rgb:' &&
                 system(sprintf('/usr/sbin/pulzr-led --has %s >/dev/null 2>&1', logical)) == 0))),
        };
    }

    // Everything the kernel has that nothing is mapped to, so a wrong name in
    // a board file is fixable by looking rather than by guessing.
    const claimed = {};
    for (let logical in LOGICAL) {
        const physical = map[logical];
        if (!physical) continue;
        if (substr(physical, 0, 4) == 'rgb:')
            for (let c in ['red', 'green', 'blue'])
                claimed[c + ':' + substr(physical, 4)] = true;
        else
            claimed[physical] = true;
    }
    const spare = [];
    for (let name in present) if (!claimed[name]) spare[length(spare)] = name;

    return {
        leds: leds,
        available: spare,
        panel: panel(map, present),
        button: {
            reset: boardValue('PULZR_BUTTON_RESET') || null,
            holdSeconds: int(boardValue('PULZR_BUTTON_RESET_HOLD') || '10'),
        },
    };
};

test = function() {
    // Detached: the lamp test walks every LED with a pause between them and
    // takes several seconds. Holding the HTTP response open for it would time
    // out the request and tell the operator it failed while it was working.
    run('/usr/sbin/pulzr-led --test >/dev/null 2>&1 &');
    return { ok: true, message: 'Walking every mapped LED.' };
};

// ── module exports ──────────────────────────────────────────────────────────
//
// A returned object, not `export` statements. uhttpd's ucode plugin compiles
// its handler in TEMPLATE mode and loads anything else through loadfile(),
// neither of which is module mode — `export` is a syntax error there. See the
// header of api/index.uc for the full contract.
return { status, test };
