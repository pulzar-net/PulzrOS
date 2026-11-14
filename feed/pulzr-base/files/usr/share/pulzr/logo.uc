// The Pulzar mark, drawn in a terminal.
//
// Eight rows of half-block cells, read from logo.txt — a pixel grid that
// scripts/render-logo.py derives from the console's own icon.svg. The motd
// and the TUI both draw it through here, so there is one picture of the mark
// on the gateway and not two that drift.
//
// The grid is data and the drawing happens at print time, for the reason the
// wordmark is rendered by pulzr-figlet rather than pasted: the right output
// depends on the terminal. A serial console at 57600 on a RAK, the Linux VT on
// a Pi's HDMI, and an SSH session from a laptop want three different things,
// and a pre-rendered block can only be right for one of them.
//
// ── COLOUR ─────────────────────────────────────────────────────────────────
//
//   24    truecolor, when COLORTERM says so.
//   256   the xterm cube. Every terminal emulator anyone will plug into a
//         gateway understands it, so it is the default.
//   16    TERM=linux, the Pi's own framebuffer console. The kernel accepts
//         256-colour codes there and folds each one to the nearest of its
//         sixteen by thresholding the channels — which turns the whole of this
//         green-to-blue mark into one cyan blob. So on that console the mark
//         picks its own sixteen: green for the pin, blue for the road.
//   0     not a terminal, or one that has said it cannot do colour. No logo:
//         a mark made of spaces is not a mark.
//
// ── GLYPHS ─────────────────────────────────────────────────────────────────
//
// ▀ and ▄ give each character cell two pixels, which is the only way sixteen
// pixels of height fit in the eight rows the banner allows. Both are in the
// VGA font the Linux console boots with, so they draw there too. A terminal
// that is not UTF-8 gets whole cells instead — half the height, but still
// the mark rather than mojibake.

let _m_fs = require('fs');

// ucode does not hoist function declarations; see console/lib/util.uc.
let load, detect, cube, sixteen, sgr, render, beside, width;

const GRID = '/usr/share/pulzr/logo.txt';

// [[r, g, b] | null, ...] per pixel row, or null when the grid is missing.
load = function(path) {
    const raw = _m_fs.readfile(path ?? GRID);
    if (!raw) return null;
    let size = null;
    const rows = [];
    for (let line in split(raw, '\n')) {
        line = trim(line);
        if (!length(line) || substr(line, 0, 1) == '#') continue;
        const tokens = split(line, /[ \t]+/);
        if (!size) { size = [ int(tokens[0]), int(tokens[1]) ]; continue; }
        push(rows, map(tokens, (t) => t == '-' ? null
            : [ hex(substr(t, 0, 2)), hex(substr(t, 2, 2)), hex(substr(t, 4, 2)) ]));
    }
    return length(rows) ? rows : null;
};

// What this terminal can take, from the environment. PULZR_COLOR and
// PULZR_ASCII override it, for a terminal that misreports itself.
detect = function(tty) {
    const term = getenv('TERM') ?? '';
    const colorterm = getenv('COLORTERM') ?? '';
    const forced = getenv('PULZR_COLOR');
    const lang = (getenv('LC_ALL') ?? '') + (getenv('LC_CTYPE') ?? '') + (getenv('LANG') ?? '');

    let depth;
    if (forced != null && match(forced, /^(0|16|256|24)$/)) depth = int(forced);
    else if (!tty || term == 'dumb' || term == '') depth = 0;
    else if (match(colorterm, /truecolor|24bit/)) depth = 24;
    else if (term == 'linux') depth = 16;
    else depth = 256;

    // OpenWrt sets no locale at all, so an absent LANG says nothing about the
    // terminal. Only a terminal type that predates UTF-8 is taken as a no.
    let utf8 = !match(term, /^(vt52|vt100|vt102|ansi|dumb)$/);
    if (match(lang, /\.(utf-?8|UTF-?8)/)) utf8 = true;
    if (getenv('PULZR_ASCII') == '1') utf8 = false;

    return { depth, utf8 };
};

// An 8-bit channel to its step on the xterm 6x6x6 cube.
cube = function(v) {
    return v < 48 ? 0 : (v < 115 ? 1 : int((v - 35) / 40));
};

// The sixteen-colour choice: by part of the mark, not by distance. Distance
// sends every pixel of this mark to cyan; see the header.
sixteen = function(c) {
    if (c[1] >= c[2]) return 92;                  // the pin: bright green
    return (c[0] + c[1] + c[2] > 330) ? 96 : 94;  // the road, and its edge
};

// The SGR parameters for one colour, foreground or background.
sgr = function(c, depth, background) {
    if (depth == 24)
        return sprintf('%d;2;%d;%d;%d', background ? 48 : 38, c[0], c[1], c[2]);
    if (depth == 256)
        return sprintf('%d;5;%d', background ? 48 : 38,
                       16 + 36 * cube(c[0]) + 6 * cube(c[1]) + cube(c[2]));
    const code = sixteen(c);
    // Bright backgrounds (100-107) are not certain on every console; the
    // ordinary eight are, and as the bottom half of a cell the difference is
    // a shade.
    return sprintf('%d', background ? code - 50 : code);
};

// The mark as lines of text, each ending with a reset. Every line is exactly
// width() columns wide, so a caller can lay text beside it.
render = function(opts) {
    opts = opts ?? {};
    const depth = opts.depth ?? 256;
    const utf8 = opts.utf8 ?? true;
    const grid = load(opts.path);
    if (!grid || depth == 0) return [];

    // Equal colours compare as equal strings; that is all this is for.
    const same = (a, b) => (a == null && b == null) ||
        (a != null && b != null && sgr(a, depth) == sgr(b, depth));

    const lines = [];
    for (let y = 0; y < length(grid); y += 2) {
        const top = grid[y], bottom = grid[y + 1] ?? [];
        let out = '', current = null;
        for (let x = 0; x < length(top); x++) {
            const t = top[x], b = bottom[x];
            let code, glyph;
            if (!utf8) {
                // Whole cells: the top pixel if there is one.
                const c = t ?? b;
                code = c ? sgr(c, depth, true) : '0';
                glyph = ' ';
            }
            else if (t == null && b == null) { code = '0'; glyph = ' '; }
            else if (b == null) { code = '0;' + sgr(t, depth); glyph = '▀'; }
            else if (t == null) { code = '0;' + sgr(b, depth); glyph = '▄'; }
            else if (same(t, b)) { code = '0;' + sgr(t, depth); glyph = '█'; }
            else { code = '0;' + sgr(t, depth) + ';' + sgr(b, depth, true); glyph = '▀'; }

            // Only when it changes. At 57600 baud on a RAK's console the escape
            // codes are most of the bytes, and most neighbours share a colour.
            if (code != current) { out += '\x1b[' + code + 'm'; current = code; }
            out += glyph;
        }
        push(lines, out + '\x1b[0m');
    }
    return lines;
};

width = function(opts) {
    const grid = load(opts ? opts.path : null);
    return grid ? length(grid[0]) : 0;
};

// The mark with a block of text to its right, centred against it. The text is
// printed as it comes — escape codes and all — so the caller styles it.
// `cols` is the mark's width in columns, from width(): length() counts bytes,
// and every half-block is three of them.
beside = function(mark, text, cols, gap) {
    const pad = sprintf('%' + (gap ?? 3) + 's', '');
    const blank = sprintf('%' + (cols || 1) + 's', '');
    const height = length(mark) > length(text) ? length(mark) : length(text);
    const markTop = int((height - length(mark)) / 2);
    const textTop = int((height - length(text)) / 2);
    const out = [];
    for (let i = 0; i < height; i++) {
        const m = (i >= markTop ? mark[i - markTop] : null) ?? blank;
        const t = i >= textTop ? text[i - textTop] : null;
        push(out, t != null ? m + pad + t : m);
    }
    return out;
};

return { beside, detect, load, render, width };
