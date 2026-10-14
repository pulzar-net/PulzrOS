// What a page is made of, and how it is drawn.
//
// A page does not draw. It returns a list of blocks — a section, a fact, a
// field, a row of buttons — and this lays them out to the width there is,
// works out which of them can take focus, and turns them into styled lines.
// That is what lets one page description serve an 80-column serial console,
// a 40-column one, and a 1080p framebuffer, and it is why the pages read like
// the React ones they mirror.
//
// ── COLOUR ─────────────────────────────────────────────────────────────────
//
// The sixteen ANSI colours and nothing finer. Every console this runs on has
// them, the Linux VT included, and they are the cheapest escape codes to send
// down a 57600 baud line. Meaning is never carried by colour alone: a badge
// is a word, and a focused control is reversed.

let term = null;

// ucode does not hoist function declarations; see console/lib/util.uc.
let init, style, glyph, wrap, badge, factValue, render, renderBlock, button, spark, bar, rule, status;

const TONE = {
    success: '32', warning: '33', error: '31', info: '36', neutral: '2',
    dim: '2', bold: '1', primary: '1', danger: '31', accent: '1;32',
};

init = function(t) { term = t; };

// `text` in the named styles, reset after. Unknown names are ignored, and with
// colour off only bold, dim and reverse survive.
style = function(text, ...names) {
    const codes = [];
    for (let n in names) {
        if (!n) continue;
        if (n == 'reverse') push(codes, '7');
        else if (n == 'underline') push(codes, '4');
        else if (TONE[n]) {
            if (!term.state.color && !match(n, /^(bold|primary|dim|neutral)$/)) continue;
            push(codes, TONE[n]);
        }
    }
    if (!length(codes)) return text;
    return '\x1b[' + join(';', codes) + 'm' + text + '\x1b[0m';
};

// Box and mark characters, with ASCII stand-ins for a terminal that is not
// UTF-8. The UTF-8 set sticks to characters the Linux console's built-in VGA
// font has, so they draw on a Pi's HDMI as well.
const GLYPHS = {
    vline: ['│', '|'], hline: ['─', '-'], dash: ['—', '-'], dot: ['·', '-'],
    down: ['↓', 'v'], up: ['↑', '^'], right: ['→', '->'], degree: ['°', ' '],
    full: ['█', '#'], shade: ['░', '.'], bar: ['▌', '|'], times: ['×', 'x'],
    ellipsis: ['…', '...'],
};

glyph = function(name) {
    // ● is not in the VGA font, so the Linux console gets an asterisk.
    if (name == 'bullet') return (term.state.utf8 && !term.state.local) ? '●' : '*';
    const g = GLYPHS[name];
    return g ? g[term.state.utf8 ? 0 : 1] : name;
};

// Word-wrap plain text to `width` columns.
wrap = function(text, width) {
    const out = [];
    for (let para in split(text ?? '', '\n')) {
        let line = '';
        for (let word in split(para, ' ')) {
            if (!length(word)) continue;
            if (!length(line)) line = word;
            else if (term.cols(line) + 1 + term.cols(word) <= width) line += ' ' + word;
            else { push(out, line); line = word; }
            // A word longer than the line — a URL, a fingerprint — breaks
            // across lines rather than losing its end: the end of a URL is the
            // part that says which gateway.
            while (term.cols(line) > width) {
                const chars = [];
                let i = 0;
                while (i < length(line)) {
                    let j = i + 1;
                    while (j < length(line) && ord(line, j) >= 0x80 && ord(line, j) < 0xc0) j++;
                    push(chars, substr(line, i, j - i));
                    i = j;
                }
                push(out, join('', slice(chars, 0, width)));
                line = join('', slice(chars, width));
            }
        }
        push(out, line);
    }
    return out;
};

// The web console's StatusBadge: a green word, a red one, or an amber one
// when `warn` is set.
status = function(ok, okLabel, badLabel, warn) {
    if (warn) return { badge: warn, tone: 'warning' };
    return ok ? { badge: okLabel ?? 'Up', tone: 'success' }
              : { badge: badLabel ?? 'Down', tone: 'error' };
};

badge = function(text, tone) {
    return style(text, tone ?? 'neutral', tone == 'neutral' ? null : 'bold');
};

// A fact's value: a string, a number, `null` for "not known", or
// { badge, tone } for a status word.
factValue = function(v) {
    if (v == null || v === '') return style(glyph('dash'), 'dim');
    if (type(v) == 'object') return v.badge != null ? badge(v.badge, v.tone) : style(v.text ?? '', v.tone);
    return sprintf('%s', v);
};

button = function(item, focused) {
    let text = '[ ' + item.label + ' ]';
    if (item.disabled) return style(text, 'dim', focused ? 'reverse' : null);
    return style(text, item.danger ? 'danger' : null, item.primary ? 'bold' : null,
                 focused ? 'reverse' : null);
};

// A row of samples as a sparkline. ▁ to ▇ are not in the VGA font, so the
// Linux console gets a ramp of ASCII instead.
spark = function(values, width, max) {
    const ramp = (term.state.utf8 && !term.state.local)
        ? [' ', '▁', '▂', '▃', '▄', '▅', '▆', '▇', '█']
        : [' ', '.', ':', '-', '=', '+', '*', '#', '#'];
    const vals = slice(values, length(values) > width ? length(values) - width : 0);
    let peak = max;
    if (!peak) { peak = 0; for (let v in vals) if (v != null && v > peak) peak = v; }
    let out = '';
    for (let v in vals) {
        if (v == null) { out += ' '; continue; }
        const i = peak > 0 ? int(v * 8.0 / peak + 0.5) : 0;
        out += ramp[i < 0 ? 0 : (i > 8 ? 8 : i)];
    }
    return out;
};

// A filled bar for a ratio, coloured by how full it is.
bar = function(ratio, width, tone) {
    const n = int((ratio > 1 ? 1 : (ratio < 0 ? 0 : ratio)) * width + 0.5);
    let full = '', empty = '';
    for (let i = 0; i < n; i++) full += glyph('full');
    for (let i = n; i < width; i++) empty += glyph('shade');
    return style(full, tone ?? 'success') + style(empty, 'dim');
};

rule = function(width) {
    let s = '';
    for (let i = 0; i < width; i++) s += glyph('hline');
    return s;
};

const LABEL = 20;

// Lay a list of blocks out at `width`.
//
// Returns { lines, items }: the styled lines, and every block that takes focus
// in the order focus moves through them, each with the line it is drawn on and
// a key that survives a refresh — so a field being edited stays the field
// being edited when a notice appears above it.
render = function(blocks, width, focusKey, edit) {
    const out = { lines: [], items: [] };
    const seen = {};
    for (let b in blocks) {
        if (b == null) continue;
        renderBlock(b, width, focusKey, edit, out, seen);
    }
    return out;
};

// A focusable item's key: its own, or its kind and label, numbered when two
// share them.
const keyFor = (b, seen) => {
    let k = b.key ?? ((b.t ?? '') + ':' + (b.label ?? ''));
    if (seen[k]) { seen[k]++; k += '#' + seen[k]; } else seen[k] = 1;
    return k;
};

renderBlock = function(b, width, focusKey, edit, out, seen) {
    const lines = out.lines;
    const add = (item) => {
        item.key = keyFor(item, seen);
        item.line = length(lines);
        push(out.items, item);
        return item.key == focusKey;
    };

    switch (b.t) {
    case 'blank':
        push(lines, '');
        break;

    case 'section': {
        if (length(lines) && lines[length(lines) - 1] != '') push(lines, '');
        let head = style(b.title ?? '', 'bold');
        if (b.note) head += '  ' + badge(b.note.badge, b.note.tone);
        push(lines, head);
        break;
    }

    case 'text':
        for (let l in wrap(b.text, width)) push(lines, style(l, b.tone));
        break;

    case 'pre':
        for (let l in b.lines) push(lines, l);
        break;

    case 'notice': {
        const mark = style(glyph('bar'), b.tone ?? 'info') + ' ';
        for (let l in wrap(b.text, width - 2))
            push(lines, mark + (b.tone == 'error' || b.tone == 'warning' ? style(l, b.tone) : l));
        break;
    }

    case 'fact': {
        const label = term.pad(style(term.clip(b.label, LABEL - 2), 'dim'), LABEL);
        const value = factValue(b.value);
        if (term.cols(value) <= width - LABEL || type(b.value) == 'object') {
            push(lines, label + value);
        } else {
            // A long plain value wraps under itself rather than off the edge.
            let first = true;
            for (let l in wrap(sprintf('%s', b.value), width - LABEL)) {
                push(lines, (first ? label : term.pad('', LABEL)) + l);
                first = false;
            }
        }
        break;
    }

    case 'buttons': {
        // One line, each button its own stop. Left and right move along it.
        // An optional label sits in the fact column, so a row of buttons can
        // belong to something: a saved network, say.
        const lead = b.label != null ? term.pad(style(term.clip(b.label, LABEL - 2), b.labelTone ?? 'dim'), LABEL) : '';
        let line = lead, group = {};
        for (let item in b.items) {
            if (!item) continue;
            item.t = 'button';
            item.row = group;
            const focused = add(item);
            const text = button(item, focused);
            if (line != lead && term.cols(line) + 2 + term.cols(text) > width) {
                push(lines, line); line = length(lead) ? term.pad('', LABEL) : '';
                item.line = length(lines);
            }
            line += (line != lead && length(line) && !match(line, / $/) ? '  ' : '') + text;
        }
        if (length(line)) push(lines, line);
        break;
    }

    case 'tabs': {
        let line = '', group = {};
        for (let item in b.items) {
            item.t = 'tab';
            item.row = group;
            const focused = add(item);
            let text = ' ' + item.label + ' ';
            if (item.mark) text += style(item.mark.text, item.mark.tone) + ' ';
            text = style(text, item.active ? 'bold' : 'dim', item.active ? 'underline' : null,
                         focused ? 'reverse' : null);
            if (length(line) && term.cols(line) + term.cols(text) > width) {
                push(lines, line); line = '';
                item.line = length(lines);
            }
            line += text;
        }
        push(lines, line);
        break;
    }

    case 'field': {
        b.t = 'field';
        const focused = add(b);
        const label = term.pad(style(term.clip(b.label, LABEL - 2), focused ? 'bold' : 'dim'), LABEL);
        const room = width - LABEL;
        const size = room < 12 ? room : (room > 48 ? 48 : room);
        let value;
        if (focused && edit) {
            // The buffer, scrolled so the cursor is in view, with the cursor
            // drawn as a reversed cell.
            const chars = b.secret ? map(edit.chars, () => '*') : edit.chars;
            let start = edit.cursor - size + 1;
            if (start < 0) start = 0;
            value = '';
            for (let i = start; i < start + size; i++) {
                const c = chars[i] ?? ' ';
                value += i == edit.cursor ? style(c, 'reverse') : c;
            }
            value = style('', 'underline') + value;
        } else {
            let text = b.value ?? '';
            if (b.secret && length(text)) text = replace(text, /./g, '*');
            text = length(text) ? term.clip(text, size) : style(term.clip(b.placeholder ?? '', size), 'dim');
            value = focused ? style(term.pad(text, size), 'reverse') : style(term.pad(text, size), 'underline');
        }
        push(lines, label + value);
        break;
    }

    case 'choice': {
        b.t = 'choice';
        const focused = add(b);
        const label = term.pad(style(term.clip(b.label, LABEL - 2), focused ? 'bold' : 'dim'), LABEL);
        let current = null;
        for (let o in b.options) if (o.value == b.value) current = o;
        const text = term.clip((current ? current.label : (b.value ?? '')) + ' ' + glyph('down'), width - LABEL);
        push(lines, label + (b.disabled ? style(text, 'dim') : style(text, focused ? 'reverse' : 'underline')));
        break;
    }

    case 'check': {
        b.t = 'check';
        const focused = add(b);
        const box = b.checked ? '[x] ' : '[ ] ';
        const text = term.clip(box + b.label, width);
        push(lines, style(text, b.disabled ? 'dim' : null, focused ? 'reverse' : null));
        break;
    }

    case 'radio': {
        // One stop per option, so a disabled one can be passed over and still
        // say why.
        //
        // The option is copied into a const before the closure takes it.
        // ucode's for-in has one binding for the whole loop, not one per
        // pass, so a closure over the loop variable itself sees only the last
        // option — every choice would select whatever came last.
        for (let each in b.options) {
            const o = each;
            const item = { t: 'option', label: o.label, key: (b.key ?? 'radio') + ':' + o.value,
                           disabled: o.disabled, run: () => b.set(o.value) };
            const focused = add(item);
            const mark = o.value == b.value ? '(*) ' : '( ) ';
            let text = mark + o.label;
            if (o.detail) text += '  ' + style(o.detail, 'dim');
            push(lines, style(text, o.disabled ? 'dim' : null, focused ? 'reverse' : null));
        }
        break;
    }

    case 'link': {
        // A row that opens something: a nav-like line inside a page.
        b.t = 'link';
        const focused = add(b);
        push(lines, style(term.pad(term.clip(b.label, width), width), focused ? 'reverse' : null));
        break;
    }

    case 'table': {
        // Fixed columns take their width; the one marked `flex` takes the rest.
        // On a narrow terminal the `optional` ones go, last first, until the
        // flexible one has room to say something.
        const gap = 2;
        let fixed = 0;
        const widthOf = (cs) => {
            let n = 0;
            for (let c in cs) if (!c.flex) n += c.width;
            return n + gap * (length(cs) - 1);
        };
        let shown = map(b.columns, (c, i) => i);
        for (let i = length(b.columns) - 1; i >= 0; i--) {
            if (width - widthOf(map(shown, (k) => b.columns[k])) >= 16) break;
            if (b.columns[i].optional) shown = filter(shown, (k) => k != i);
        }
        b = { columns: map(shown, (k) => b.columns[k]), empty: b.empty,
              rows: map(b.rows, (r) => ({ cells: map(shown, (k) => r.cells[k]),
                                         tones: r.tones ? map(shown, (k) => r.tones[k]) : null, tone: r.tone })) };
        fixed = widthOf(b.columns);
        const widths = map(b.columns, (c, i) => c.flex ? (width - fixed > 8 ? width - fixed : 8) : c.width);
        const cell = (text, i, align) => {
            const w = widths[i];
            const t = term.clip(sprintf('%s', text ?? ''), w);
            const n = term.cols(t);
            return align == 'right' ? sprintf('%' + (w - n) + 's', '') + t : term.pad(t, w);
        };
        let head = '';
        for (let i = 0; i < length(b.columns); i++) {
            const c = b.columns[i];
            head += (i ? '  ' : '') + style(cell(c.label + (c.sort ? ' ' + glyph(c.sort == 'desc' ? 'down' : 'up') : ''), i, c.align), 'dim');
        }
        push(lines, head);
        for (let row in b.rows) {
            let line = '';
            for (let i = 0; i < length(b.columns); i++) {
                let text = cell(row.cells[i], i, b.columns[i].align);
                if (row.tones && row.tones[i]) text = style(text, row.tones[i]);
                line += (i ? '  ' : '') + text;
            }
            push(lines, row.tone ? style(line, row.tone) : line);
        }
        if (!length(b.rows) && b.empty) push(lines, style(b.empty, 'dim'));
        break;
    }

    case 'spark': {
        const label = term.pad(style(term.clip(b.label, LABEL - 2), 'dim'), LABEL);
        const value = b.value ?? '';
        const room = width - LABEL - term.cols(value) - 2;
        push(lines, label + style(term.pad(spark(b.values ?? [], room > 0 ? room : 0, b.max), room > 0 ? room : 0), b.tone ?? 'info') + '  ' + value);
        break;
    }

    case 'meter': {
        const label = term.pad(style(term.clip(b.label, LABEL - 2), 'dim'), LABEL);
        const room = width - LABEL - 2 - term.cols(b.value ?? '');
        const size = room > 30 ? 30 : (room > 4 ? room : 4);
        push(lines, label + bar(b.ratio ?? 0, size, b.tone) + '  ' + (b.value ?? ''));
        break;
    }
    }
};

return { badge, bar, factValue, glyph, init, render, rule, spark, status, style, wrap };
