// The front panel, as the console sees it.
//
// Mostly a window onto `parkeze-led --list`: which logical indicator is mapped
// to which physical LED on this board, and which are not mapped at all. That
// last part is the useful bit — an unmapped indicator is not a fault, it is a
// board with fewer lights than the maximum, and the daemon folds its state
// into another one. But a *wrongly* mapped one is silent and invisible, and
// comparing the map against what the kernel actually exposes is how you find
// it.

let _m_fs = require('fs');
let readfile = _m_fs.readfile;; let lsdir = _m_fs.lsdir;
let _m_util = loadfile('/usr/share/parkeze/console/lib/util.uc', { raw_mode: true })();
let run = _m_util.run;

const LOGICAL = ['power', 'status', 'lora', 'lora2', 'cloud', 'cellular'];
const LEDS = '/sys/class/leds';

function boardLeds() {
    // /etc/parkeze/board.conf is shell. Parsed rather than sourced: a parser
    // that cannot execute anything is the right default for a file the console
    // reads on every page load.
    const raw = readfile('/etc/parkeze/board.conf');
    const map = {};
    if (!raw) return map;
    for (let line in split(raw, '\n')) {
        const m = match(trim(line), /^PARKEZE_LED_([A-Z0-9_]+)='?([^']*)'?$/);
        if (m) map[lc(m[1])] = m[2];
    }
    return map;
}

function boardValue(key) {
    const raw = readfile('/etc/parkeze/board.conf');
    if (!raw) return null;
    const m = match(raw, sprintf("%s='?([^'\n]*)'?", key));
    return m ? m[1] : null;
}

function status() {
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
            present: !!(physical && index(present, physical) >= 0),
        };
    }

    // Everything the kernel has that nothing is mapped to, so a wrong name in
    // a board file is fixable by looking rather than by guessing.
    const claimed = {};
    for (let logical in LOGICAL) if (map[logical]) claimed[map[logical]] = true;
    const spare = [];
    for (let name in present) if (!claimed[name]) spare[length(spare)] = name;

    return {
        leds: leds,
        available: spare,
        button: {
            reset: boardValue('PARKEZE_BUTTON_RESET') || null,
            holdSeconds: int(boardValue('PARKEZE_BUTTON_RESET_HOLD') || '10'),
        },
    };
}

function test() {
    // Detached: the lamp test walks every LED with a pause between them and
    // takes several seconds. Holding the HTTP response open for it would time
    // out the request and tell the operator it failed while it was working.
    run('/usr/sbin/parkeze-led --test >/dev/null 2>&1 &');
    return { ok: true, message: 'Walking every mapped LED.' };
}

// ── module exports ──────────────────────────────────────────────────────────
//
// A returned object, not `export` statements. uhttpd's ucode plugin compiles
// its handler in TEMPLATE mode and loads anything else through loadfile(),
// neither of which is module mode — `export` is a syntax error there. See the
// header of api/index.uc for the full contract.
return { status, test };
