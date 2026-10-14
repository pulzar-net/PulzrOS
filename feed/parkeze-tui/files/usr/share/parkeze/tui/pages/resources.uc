// System / Resources — console/src/pages/system/Resources.tsx, and its
// Processes dialog, which here is a view of its own that Esc closes.
return function(ctx) {
    const ui = ctx.ui, fmt = ctx.fmt, api = ctx.api, term = ctx.term;
    const st = { span: 3600, history: null, stats: null, iface: null,
                 procs: false, list: null, prev: null, cpu: {}, search: '', sortBy: 'memory' };

    const STATE = { R: 'Running', S: 'Sleeping', D: 'Waiting', Z: 'Zombie', T: 'Stopped', I: 'Idle' };

    // Per-process CPU, as top works it out: the ticks a process used between
    // two polls over the ticks the machine had.
    const sample = () => {
        const now = api.system.processes();
        const cpu = {};
        if (st.prev && now.total > st.prev.total) {
            const before = {};
            for (let p in st.prev.processes) before[p.pid] = p.ticks;
            const elapsed = (now.total - st.prev.total) * 1.0;
            for (let p in now.processes)
                if (before[p.pid] != null) {
                    const v = (p.ticks - before[p.pid]) / elapsed * 100;
                    cpu[p.pid] = v > 0 ? v : 0;
                }
        }
        st.prev = now;
        st.cpu = cpu;
        st.list = now.processes;
    };

    const processView = (width) => {
        const needle = lc(st.search);
        const rows = filter(st.list ?? [], (p) => !length(needle)
            || index(lc(sprintf('%d %s %s', p.pid, p.name, p.command)), needle) >= 0);
        const by = {
            memory: (a, b) => b.rss - a.rss,
            cpu: (a, b) => (st.cpu[b.pid] ?? -1) - (st.cpu[a.pid] ?? -1),
            pid: (a, b) => a.pid - b.pid,
            name: (a, b) => a.name < b.name ? -1 : (a.name > b.name ? 1 : 0),
        };
        sort(rows, by[st.sortBy]);
        return [
            { t: 'section', title: 'Processes' },
            { t: 'buttons', items: [ { label: 'Close', key: 'close', run: () => { st.procs = false; } } ] },
            { t: 'field', label: 'Search', value: st.search, placeholder: 'Search', set: (v) => { st.search = v; } },
            { t: 'choice', label: 'Sort', value: st.sortBy, options: [
                { value: 'memory', label: 'Memory' }, { value: 'cpu', label: 'CPU' },
                { value: 'pid', label: 'PID' }, { value: 'name', label: 'Name' },
              ], set: (v) => { st.sortBy = v; } },
            { t: 'text', tone: 'dim', text: sprintf('%d', length(rows)) },
            { t: 'table', empty: 'Nothing matches.', columns: [
                { label: 'PID', width: 6, align: 'right' },
                { label: 'Name', width: 14 },
                { label: 'CPU', width: 6, align: 'right' },
                { label: 'Memory', width: 9, align: 'right', optional: true },
                { label: 'Thr', width: 3, align: 'right', optional: true },
                { label: 'State', width: 8, optional: true },
                { label: 'Command', flex: true },
              ], rows: map(rows, (p) => ({ cells: [
                p.pid, p.name,
                st.cpu[p.pid] != null ? sprintf('%.1f%%', st.cpu[p.pid]) : ui.glyph('dash'),
                p.rss ? fmt.bytes(p.rss) : ui.glyph('dash'),
                p.threads, STATE[p.state] ?? p.state,
                length(p.command) ? p.command : '[' + p.name + ']',
              ] })) },
        ];
    };

    return {
        interval: () => st.procs ? 3 : 20,
        load: function() {
            if (st.procs) return sample();
            st.history = api.system.history(sprintf('span=%d', st.span));
            st.stats = api.system.stats();
        },
        // Esc closes the process list before it leaves the page.
        back: function() {
            if (!st.procs) return false;
            st.procs = false;
            ctx.refresh();
            return true;
        },
        view: function(width) {
            if (st.procs) return processView(width);
            const points = st.history.points ?? [], s = st.stats;
            const last = length(points) ? points[length(points) - 1] : null;
            const dash = ui.glyph('dash');
            const out = [];

            push(out, { t: 'choice', label: 'Span', value: st.span, options: [
                { value: 3600, label: '1 hour' }, { value: 21600, label: '6 hours' }, { value: 86400, label: '24 hours' },
            ], set: (v) => { st.span = v; ctx.refresh(); } });
            push(out, { t: 'blank' });

            if (length(points) < 2) push(out, { t: 'text', tone: 'dim', text: 'Collecting samples' });

            const memTotal = last?.memTotal ?? s.memory?.total;
            push(out, { t: 'spark', label: 'CPU', max: 100, values: map(points, (p) => p.cpu),
                        value: last ? sprintf('%d%%', int(last.cpu + 0.5)) : dash });
            push(out, { t: 'spark', label: 'Memory', max: memTotal, values: map(points, (p) => p.mem),
                        value: last ? sprintf('%s of %s', fmt.bytes(last.mem), fmt.bytes(memTotal)) : dash });
            push(out, { t: 'spark', label: 'Load', values: map(points, (p) => p.load),
                        value: last ? sprintf('%.2f', last.load) : dash });

            // Every interface any sample saw; the busiest one unless one was
            // picked and is still there.
            const totals = {};
            for (let p in points) for (let name in (p.net ?? {}))
                totals[name] = (totals[name] ?? 0) + (p.net[name][0] ?? 0) + (p.net[name][1] ?? 0);
            const names = sort(keys(totals));
            let iface = st.iface;
            if (!iface || totals[iface] == null) {
                iface = null;
                for (let n in names) if (iface == null || totals[n] > totals[iface]) iface = n;
            }
            if (length(names) > 1)
                push(out, { t: 'choice', label: 'Interface', value: iface, options: map(names, (n) => ({ value: n, label: n })),
                            set: (v) => { st.iface = v; } });
            if (iface) {
                const rate = (p, i) => (p.net && p.net[iface]) ? p.net[iface][i] : null;
                const down = map(points, (p) => rate(p, 0)), up = map(points, (p) => rate(p, 1));
                const lastNet = (last && last.net && last.net[iface]) ? last.net[iface] : [ 0, 0 ];
                push(out, { t: 'spark', label: 'Network ' + ui.glyph('down'), values: down,
                            value: sprintf('%s/s', fmt.bytes(lastNet[0]) ?? '0 B') });
                push(out, { t: 'spark', label: 'Network ' + ui.glyph('up'), values: up, tone: 'success',
                            value: sprintf('%s/s', fmt.bytes(lastNet[1]) ?? '0 B') });
            }

            push(out, { t: 'section', title: 'Storage' });
            for (let d in (s.storage ?? [])) {
                const ro = d.mount == '/rom';
                const ratio = d.total ? (d.used * 1.0 / d.total) : 0;
                const pct = ro ? 'RO' : (ratio > 0 && ratio < 0.01 ? '<1%' : sprintf('%d%%', int(ratio * 100 + 0.5)));
                push(out, { t: 'meter', label: d.label, ratio: ro ? 1 : ratio,
                            tone: ro ? 'neutral' : (ratio > 0.95 ? 'error' : (ratio > 0.8 ? 'warning' : 'success')),
                            value: sprintf('%4s  %s', pct, ro ? fmt.bytes(d.total) + ', read-only'
                                                          : sprintf('%s of %s', fmt.bytes(d.used), fmt.bytes(d.total))) });
            }

            if (length(s.temperatures ?? [])) {
                push(out, { t: 'section', title: 'Temperature' });
                for (let t in s.temperatures)
                    push(out, { t: 'fact', label: t.name, value: sprintf('%.1f %sC', t.celsius, ui.glyph('degree')) });
            }
            if (length(s.power ?? [])) {
                push(out, { t: 'section', title: 'Power' });
                for (let p in s.power) {
                    const parts = filter([ p.type, p.online == null ? null : (p.online ? 'online' : 'offline'),
                                           p.volts == null ? null : sprintf('%.2f V', p.volts),
                                           p.capacity == null ? null : sprintf('%d%%', p.capacity) ], (x) => x != null && x != '');
                    push(out, { t: 'fact', label: p.name, value: join(' ' + ui.glyph('dot') + ' ', parts) });
                }
            }

            const cpu = s.cpu ?? {};
            push(out, { t: 'section', title: 'Processor' });
            push(out, { t: 'fact', label: 'Chip', value: cpu.model });
            push(out, { t: 'fact', label: 'Core', value: cpu.cores > 1 ? sprintf('%s %s %d', cpu.core, ui.glyph('times'), cpu.cores) : cpu.core });
            push(out, { t: 'fact', label: 'Processes', value: sprintf('%d (%d running)', cpu.processes, cpu.running) });
            push(out, { t: 'fact', label: 'Uptime', value: fmt.duration(s.uptime) });

            push(out, { t: 'section', title: 'Processes' });
            push(out, { t: 'buttons', items: [ { label: 'All processes', run: () => {
                st.procs = true;
                sample();
            } } ] });
            for (let p in slice(s.processes ?? [], 0, 5))
                push(out, { t: 'fact', label: p.name, value: fmt.bytes(p.rss) });
            return out;
        },
    };
};
