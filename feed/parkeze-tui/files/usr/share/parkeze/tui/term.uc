// The terminal: raw input, decoded keys, and output that sends only what
// changed.
//
// ── READING A KEY ON THE ucode THIS IMAGE SHIPS ────────────────────────────
//
// OpenWrt 24.10.0 pins ucode 2024-07-22, whose file.read(n) is a bare fread()
// with no clearerr() after it — that arrived upstream in 2026. Under musl the
// EOF flag is sticky: once a read times out, every later read on that handle
// returns nothing, immediately, forever. stdin is therefore never read
// directly. Input is a handle opened on the same tty, read until a read comes
// back empty, and then closed and reopened. A handle is only ever dropped at
// EOF, which is the one moment its stdio buffer is known to be empty, so no
// keystroke is lost in the swap.
//
// The tty runs in one of two modes, set with stty because 24.10's fs has no
// ioctl() either:
//
//   wait()    VMIN 1: block until a key. Used whenever nothing on screen is
//             live — the sign-in screen, an idle console — so a TUI sitting
//             on a Pi's HDMI or a USB serial port nobody has opened costs no
//             wakeups at all.
//   poll()    VMIN 0, VTIME 2: return a key or nothing after 200ms. Used while
//             a page is refreshing on a timer.
//
// ── WRITING ON A 57600 BAUD CONSOLE ────────────────────────────────────────
//
// A RAK's console is a CH340 on the SoC's UART at 57600: about 5.7KB a second.
// One full 80x24 frame with colour is 3-5KB, so repainting everything on every
// refresh would make the TUI visibly crawl. Frames are composed as whole lines
// and only lines that differ from what the terminal already shows are sent.

let _m_fs = require('fs');

// ucode does not hoist function declarations; see console/lib/util.uc.
let open, close, setMode, size, probe, readByte, readKey, decode, write, flush;
let present, invalidate, cols, clip, pad, fit, setTitle, alternate;

let state = {
    path: null,        // the tty, opened again for every input handle
    input: null,       // the current input handle, until it reaches EOF
    mode: null,        // 'wait' | 'poll'
    saved: null,       // stty -g, restored on close
    rows: 24, cols: 80,
    utf8: true,
    color: true,       // the sixteen ANSI colours; off for a terminal with none
    pending: [],       // bytes read while waiting for something else
    shown: [],         // the lines the terminal is showing now
    out: '',           // pending output
    local: false,      // a Linux VT rather than a serial line or a pty
};

const ESC = '\x1b';

open = function(opts) {
    // The same tty as stdin, opened afresh. /dev/fd/0 where there is no
    // /proc, which is only ever a developer's machine.
    state.path = opts.tty ?? (_m_fs.stat('/proc/self/fd/0') ? '/proc/self/fd/0' : '/dev/fd/0');
    state.local = !!match(opts.tty ?? '', /^\/dev\/tty[0-9]+$/);
    state.utf8 = opts.utf8 ?? true;
    state.forced = !!opts.forced;
    state.color = opts.color ?? true;
    state.saved = trim(_m_fs.popen('stty -g 2>/dev/null', 'r')?.read('all') ?? '');
    system('stty raw -echo 2>/dev/null');
    setMode('poll');
    alternate(true);
    // On a Pi's own screen: blank it after ten minutes without a key, and
    // power the output down. The kernel does both; a key brings it back.
    if (state.local) state.out += ESC + '[9;10]' + ESC + '[14;10]';
    size();
    return state;
};

close = function() {
    state.out += ESC + '[0m' + ESC + '[?25h';
    alternate(false);
    flush();
    if (state.input) { state.input.close(); state.input = null; }
    system(length(state.saved) ? sprintf("stty '%s' 2>/dev/null", state.saved) : 'stty sane 2>/dev/null');
};

// The alternate screen, so leaving the TUI from a shell puts back what was
// there. A Linux VT ignores it, which is fine: there is nothing to restore.
alternate = function(on) {
    state.out += on ? ESC + '[?1049h' + ESC + '[?25l' + ESC + '[2J'
                    : ESC + '[2J' + ESC + '[H' + ESC + '[?1049l';
    state.shown = [];
};

setMode = function(mode) {
    if (state.mode == mode) return;
    system(mode == 'wait' ? 'stty min 1 time 0 2>/dev/null'
                          : 'stty min 0 time 2 2>/dev/null');
    // The input handle stays open. It may hold bytes stdio has already read —
    // the rest of an arrow key whose ESC is being decoded — and a handle is
    // only ever dropped at EOF, which a live one has not reached.
    state.mode = mode;
};

// The window size. A pty and a Linux VT know theirs and stty reports it. A
// serial line does not — stty says 0 0 there — so the terminal at the far end
// is asked instead, by parking the cursor in the far corner and requesting
// its position. A terminal that does not answer is taken to be 80x24.
size = function() {
    const p = _m_fs.popen('stty size 2>/dev/null', 'r');
    const reply = p ? trim(p.read('all') ?? '') : '';
    if (p) p.close();
    const m = match(reply, /^([0-9]+) ([0-9]+)$/);
    if (m && int(m[1]) > 0 && int(m[2]) > 0) {
        state.rows = int(m[1]); state.cols = int(m[2]);
    }
    else {
        const where = probe(ESC + '[999;999H');
        if (where) { state.rows = where[0]; state.cols = where[1]; }
    }
    // Whether the far end speaks UTF-8: draw one box character from column 1
    // and see whether the cursor moved one column or three. An answer settles
    // it; no answer leaves the environment's guess standing.
    if (!state.forced) {
        const after = probe('\r' + '─');
        if (after) state.utf8 = after[1] == 2;
    }
    state.out += '\r' + ESC + '[2K';
    state.shown = [];
    return [ state.rows, state.cols ];
};

// Write `prefix`, ask for the cursor position, and return [row, col], or null
// if the terminal does not answer within half a second. Whatever else arrives
// meanwhile — somebody already typing — is kept for readKey().
probe = function(prefix) {
    state.out += prefix + ESC + '[6n';
    flush();
    const before = state.mode;
    setMode('poll');
    let reply = '', found = null;
    for (let i = 0; i < 3 && !found; i++) {
        let b;
        while ((b = readByte()) != null) {
            reply += b;
            const m = match(reply, /^(.*)\x1b\[([0-9]+);([0-9]+)R(.*)$/s);
            if (m) { found = [ int(m[2]), int(m[3]) ]; reply = m[1] + m[4]; break; }
        }
    }
    for (let c in split(reply, '')) if (length(c)) push(state.pending, c);
    setMode(before);
    return found;
};

// One byte, or null when the read came back empty.
readByte = function() {
    if (length(state.pending)) return shift(state.pending);
    if (!state.input) state.input = _m_fs.open(state.path, 'r');
    if (!state.input) return null;
    const b = state.input.read(1);
    if (b == null || b == '') {
        state.input.close();
        state.input = null;
        return null;
    }
    return b;
};

// The next key as a name — 'up', 'enter', 'esc', 'ctrl-c', ... — or a
// printable character as itself. null when nothing arrived (poll mode only).
readKey = function() {
    const b = readByte();
    if (b == null) return null;
    return decode(b);
};

const SEQUENCES = {
    '[A': 'up', '[B': 'down', '[C': 'right', '[D': 'left',
    'OA': 'up', 'OB': 'down', 'OC': 'right', 'OD': 'left',
    '[H': 'home', '[F': 'end', 'OH': 'home', 'OF': 'end',
    '[1~': 'home', '[4~': 'end', '[7~': 'home', '[8~': 'end',
    '[2~': 'insert', '[3~': 'delete', '[5~': 'pgup', '[6~': 'pgdn',
    '[Z': 'shift-tab',
};

const CONTROL = {
    '\r': 'enter', '\n': 'enter', '\t': 'tab', '\x7f': 'backspace', '\x08': 'backspace',
    '\x03': 'ctrl-c', '\x04': 'ctrl-d', '\x0c': 'ctrl-l', '\x15': 'ctrl-u',
    '\x01': 'home', '\x05': 'end', '\x17': 'ctrl-w',
};

decode = function(b) {
    if (b == ESC) {
        // A lone Esc is an Esc; anything else is a sequence. The terminal
        // sends a sequence in one burst, so the next byte is already here if
        // there is one — but in wait mode a read would block on a lone Esc,
        // so the tail is read in poll mode.
        const before = state.mode;
        setMode('poll');
        let seq = '';
        let n = readByte();
        if (n == null) { setMode(before); return 'esc'; }
        // Esc and then an arrow, typed quickly: the second ESC starts the
        // arrow, not an Alt chord.
        if (n == ESC) { unshift(state.pending, n); setMode(before); return 'esc'; }
        seq = n;
        if (n == '[' || n == 'O') {
            while (length(seq) < 8) {
                n = readByte();
                if (n == null) break;
                seq += n;
                if (match(n, /[A-Za-z~]/)) break;
            }
        }
        setMode(before);
        return SEQUENCES[seq] ?? (length(seq) == 1 ? 'alt-' + seq : 'unknown');
    }
    if (CONTROL[b]) return CONTROL[b];
    const c = ord(b);
    if (c < 32) return 'ctrl-' + chr(c + 96);
    // A UTF-8 lead byte: the rest of the character follows it.
    let more = c >= 0xf0 ? 3 : (c >= 0xe0 ? 2 : (c >= 0xc0 ? 1 : 0));
    let ch = b;
    while (more-- > 0) {
        const n = readByte();
        if (n == null) break;
        ch += n;
    }
    return ch;
};

write = function(s) { state.out += s; };

flush = function() {
    if (!length(state.out)) return;
    _m_fs.stdout.write(state.out);
    _m_fs.stdout.flush();
    state.out = '';
};

// Show a frame: one string per row, already styled. Only rows that differ
// from the last frame are sent.
present = function(lines) {
    for (let y = 0; y < state.rows; y++) {
        // Never wider than the screen: a terminal wraps a long line onto the
        // next row and every row below it is then one out. The last row stops
        // a column short, because filling its last cell scrolls some
        // terminals.
        const line = fit(lines[y] ?? '', y == state.rows - 1 ? state.cols - 1 : state.cols);
        if (state.shown[y] === line) continue;
        state.out += sprintf('%s[%d;1H%s%s[0m%s[K', ESC, y + 1, line, ESC, ESC);
        state.shown[y] = line;
    }
    flush();
};

// Forget what the terminal is showing, so the next frame is sent in full —
// after a size change, or when something else may have written to it, as the
// kernel does to a VT that is also a console.
invalidate = function() {
    state.out += ESC + '[0m' + ESC + '[2J';
    state.shown = [];
};

// Display columns in a string: escape sequences take none, and a UTF-8
// character takes one however many bytes it is. Nothing drawn here is
// double-width.
cols = function(s) {
    // Most of what is measured is plain ASCII — a thousand log lines on every
    // frame — and walking it a byte at a time is the slow part of drawing on
    // a MIPS gateway. One regex says whether the walk is needed at all.
    if (!match(s, /[^ -~]/)) return length(s);
    let n = 0, i = 0;
    const len = length(s);
    while (i < len) {
        const c = ord(s, i);
        if (c == 27) {
            i++;
            if (ord(s, i) == 91) {
                i++;
                while (i < len && !(ord(s, i) >= 64 && ord(s, i) <= 126)) i++;
            }
            i++;
            continue;
        }
        if (c < 0x80 || c >= 0xc0) n++;
        i++;
    }
    return n;
};

// Cut a styled string to `width` columns: escape codes pass through and take
// no room. Cheap when it already fits, which is nearly always.
fit = function(s, width) {
    if (cols(s) <= width) return s;
    let out = '', n = 0, i = 0;
    const len = length(s);
    while (i < len && n < width) {
        const c = ord(s, i);
        if (c == 27) {
            let j = i + 1;
            if (ord(s, j) == 91) { j++; while (j < len && !(ord(s, j) >= 64 && ord(s, j) <= 126)) j++; }
            out += substr(s, i, j + 1 - i);
            i = j + 1;
            continue;
        }
        let j = i + 1;
        while (j < len && ord(s, j) >= 0x80 && ord(s, j) < 0xc0) j++;
        out += substr(s, i, j - i);
        i = j;
        n++;
    }
    return out + ESC + '[0m';
};

// Cut a plain (unstyled) string to `width` columns, without splitting a
// character. An ellipsis marks the cut when there is room for one.
clip = function(s, width) {
    s = s ?? '';
    if (width <= 0) return '';
    if (cols(s) <= width) return s;
    const keep = width - 1;
    let i = 0, n = 0;
    while (i < length(s) && n < keep) {
        i++;
        while (i < length(s) && ord(s, i) >= 0x80 && ord(s, i) < 0xc0) i++;
        n++;
    }
    return substr(s, 0, i) + (state.utf8 ? '…' : '~');
};

// Pad a styled string with spaces to exactly `width` columns, clipping a plain
// one that is too long.
pad = function(s, width) {
    s = s ?? '';
    const n = cols(s);
    if (n > width) return clip(s, width);
    return n == width ? s : s + sprintf('%' + (width - n) + 's', '');
};

setTitle = function(text) {
    if (!state.local) state.out += ESC + ']0;' + text + '\x07';
};

return { clip, close, cols, fit, flush, invalidate, open, pad, present, readKey,
         setMode, setTitle, size, state, write };
