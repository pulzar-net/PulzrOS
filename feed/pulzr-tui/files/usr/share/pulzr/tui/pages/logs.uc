// Logs — console/src/pages/Logs.tsx.
return function(ctx) {
    const ui = ctx.ui, api = ctx.api;
    const st = { raw: [], parsed: [], lines: 1000, follow: true, search: '', level: 'all', source: '',
                 sort: 'newest' };

    const LINE = /^[A-Za-z]{3} ([A-Za-z]{3}) +([0-9]+) ([0-9:]+) [0-9]{4} ([a-z]+)\.([a-z]+) ([^:]*): ?(.*)$/;
    const SEVERITY = { emerg: 0, alert: 1, crit: 2, err: 3, warn: 4, warning: 4, notice: 5, info: 6, debug: 7 };
    const severity = (level) => SEVERITY[level] ?? 6;

    const parse = (lines) => {
        const out = [];
        for (let l in lines) {
            if (!length(trim(l))) continue;
            const m = match(l, LINE);
            push(out, m
                ? { index: length(out), time: sprintf('%s %s %s', m[1], m[2], m[3]), facility: m[4], level: m[5],
                    source: trim(replace(m[6], /\[[0-9]+\]$/, '')), message: m[7] }
                : { index: length(out), time: '', level: '', facility: '', source: '', message: l });
        }
        return out;
    };

    return {
        interval: () => st.follow ? 5 : null,
        load: function() {
            st.raw = api.system.logs(sprintf('lines=%d', st.lines)).lines ?? [];
            st.parsed = parse(st.raw);
        },
        view: function(width) {
            const needle = lc(st.search);
            const rows = filter(st.parsed, (r) => {
                if (st.level == 'warn' && severity(r.level) > 4) return false;
                if (st.level == 'err' && severity(r.level) > 3) return false;
                if (length(st.source) && lc(r.source) != lc(st.source)) return false;
                if (length(needle)) {
                    const hay = lc(sprintf('%d %s %s %s', r.index, r.level, r.source, r.message));
                    if (index(hay, needle) < 0) return false;
                }
                return true;
            });
            if (st.sort == 'newest') sort(rows, (a, b) => b.index - a.index);
            else if (st.sort == 'oldest') sort(rows, (a, b) => a.index - b.index);
            else if (st.sort == 'level') sort(rows, (a, b) => severity(a.level) - severity(b.level) || b.index - a.index);
            else if (st.sort == 'source') sort(rows, (a, b) => (a.source < b.source ? -1 : (a.source > b.source ? 1 : b.index - a.index)));

            const seen = {}, sources = [];
            for (let r in st.parsed) if (length(r.source) && !seen[r.source]) { seen[r.source] = true; push(sources, r.source); }
            sort(sources);

            const reload = () => { ctx.refresh(); };
            const out = [
                { t: 'field', label: 'Search', value: st.search, placeholder: 'Search', set: (v) => { st.search = v; } },
                { t: 'choice', label: 'Level', value: st.level, options: [
                    { value: 'all', label: 'All levels' },
                    { value: 'warn', label: 'Warnings and worse' },
                    { value: 'err', label: 'Errors only' },
                ], set: (v) => { st.level = v; } },
                { t: 'choice', label: 'Source', value: st.source,
                  options: [ { value: '', label: 'All sources' }, ...map(sources, (s) => ({ value: s, label: s })) ],
                  set: (v) => { st.source = v; } },
                { t: 'choice', label: 'Lines', value: st.lines, options: map([ 200, 500, 1000, 2000 ],
                    (n) => ({ value: n, label: sprintf('Last %d', n) })), set: (v) => { st.lines = v; reload(); } },
                { t: 'choice', label: 'Sort', value: st.sort, options: [
                    { value: 'newest', label: 'Newest first' }, { value: 'oldest', label: 'Oldest first' },
                    { value: 'level', label: 'By level' }, { value: 'source', label: 'By source' },
                ], set: (v) => { st.sort = v; } },
                { t: 'check', label: 'Follow', checked: st.follow, set: (v) => { st.follow = v; } },
                { t: 'text', tone: 'dim', text: sprintf('%d of %d', length(rows), length(st.parsed)) },
                { t: 'table', empty: 'Nothing matches.', columns: [
                    { label: 'Time', width: 15, sort: st.sort == 'newest' ? 'desc' : (st.sort == 'oldest' ? 'asc' : null) },
                    { label: 'Level', width: 7, optional: true, sort: st.sort == 'level' ? 'asc' : null },
                    { label: 'Source', width: 14, optional: true, sort: st.sort == 'source' ? 'asc' : null },
                    { label: 'Message', flex: true },
                  ], rows: map(rows, (r) => {
                    const sev = severity(r.level);
                    const tone = sev <= 3 ? 'error' : (sev == 4 ? 'warning' : null);
                    return { cells: [ r.time, length(r.level) ? r.level : ui.glyph('dash'), r.source, r.message ],
                             tones: [ null, tone ?? 'dim', null, tone ] };
                  }) },
            ];
            return out;
        },
    };
};
