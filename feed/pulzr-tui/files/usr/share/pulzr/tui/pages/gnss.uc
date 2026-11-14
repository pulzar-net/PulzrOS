// GNSS — console/src/pages/Gnss.tsx.
return function(ctx) {
    const ui = ctx.ui, api = ctx.api;
    const st = { gps: null, choice: null, device: '', baud: 9600, from: null, result: null, syncError: null };
    const BAUDS = [ 4800, 9600, 19200, 38400, 57600, 115200 ];

    const serverChoice = (cfg) => cfg.source == 'concentrator' ? sprintf('concentrator:%d', cfg.slot) : cfg.source;

    return {
        // A minute once there is a fix; ten seconds while waiting for one.
        interval: () => st.gps?.fix ? 60 : 10,
        load: function() {
            st.gps = api.lorawan.gps();
            const cfg = st.gps.config ?? { source: 'auto', slot: 0, device: '', baud: 9600 };
            const from = sprintf('%s|%s|%s', serverChoice(cfg), cfg.device, cfg.baud);
            if (from != st.from) {
                st.from = from;
                st.choice = serverChoice(cfg);
                st.device = cfg.device ?? '';
                st.baud = cfg.baud ?? 9600;
            }
        },
        view: function(width) {
            const g = st.gps, ref = g.reference ?? {}, cfg = g.config ?? {}, opts = g.options ?? {};
            const out = [];

            push(out, { t: 'buttons', items: [
                { label: 'Re-detect', run: () => { ctx.act('detectGps'); ctx.refresh(); } },
                { label: 'Record position', primary: true, disabled: !g.fix, run: () => {
                    const r = ctx.act('syncGps');
                    st.syncError = r.error;
                    ctx.refresh();
                } },
            ] });
            if (!g.fix && g.reason) push(out, { t: 'notice', tone: 'info', text: g.reason });
            if (st.syncError) push(out, { t: 'notice', tone: 'error', text: st.syncError });

            push(out, { t: 'fact', label: 'Fix', value: g.fix ? { badge: 'Fix', tone: 'success' }
                : (g.present ? { badge: 'No fix', tone: 'warning' } : { badge: 'No receiver', tone: 'neutral' }) });
            if (g.fix) push(out, { t: 'fact', label: 'Position', value: sprintf('%s, %s', g.latitude, g.longitude) });
            if (g.fix && g.altitude != null) push(out, { t: 'fact', label: 'Altitude', value: sprintf('%s m', g.altitude) });
            if (g.satellites) push(out, { t: 'fact', label: 'Satellites', value: g.satellites });
            if (ref.latitude && ref.longitude) {
                push(out, { t: 'fact', label: 'Reported position', value: sprintf('%s, %s', ref.latitude, ref.longitude) });
                push(out, { t: 'fact', label: 'Recorded from', value: (ref.source ?? 'unknown')
                            + (ref.fixedAt ? ' ' + ui.glyph('dot') + ' ' + ref.fixedAt : '') });
            }

            push(out, { t: 'section', title: 'Source' });
            const options = [
                { value: 'auto', label: 'Automatic' },
                { value: 'modem', label: 'Cellular modem', disabled: !opts.modem, detail: opts.modem ? null : 'No GNSS' },
            ];
            for (let s in (opts.slots ?? []))
                push(options, { value: sprintf('concentrator:%d', s.index), label: sprintf('Concentrator %d', s.index + 1),
                                disabled: s.status != 'present', detail: s.status != 'present' ? s.status : null });
            push(options, { value: 'device', label: 'Separate receiver' });
            push(out, { t: 'radio', key: 'source', value: st.choice, options, set: (v) => { st.choice = v; } });

            if (st.choice == 'device') {
                push(out, { t: 'field', label: 'Device', value: st.device, placeholder: '/dev/ttyUSB0',
                            set: (v) => { st.device = v; } });
                push(out, { t: 'choice', label: 'Baud rate', value: st.baud,
                            options: map(BAUDS, (b) => ({ value: b, label: sprintf('%d', b) })),
                            set: (v) => { st.baud = v; } });
            }

            const unchanged = st.choice == serverChoice(cfg)
                && (st.choice != 'device' || (trim(st.device) == (cfg.device ?? '') && st.baud == cfg.baud));
            if (st.result) push(out, { t: 'notice', tone: st.result.tone, text: st.result.text });
            push(out, { t: 'buttons', items: [ { label: 'Apply', primary: true, disabled: unchanged, run: () => {
                const req = {};
                const m = match(st.choice, /^concentrator:([0-9]+)$/);
                if (m) { req.source = 'concentrator'; req.slot = int(m[1]); }
                else req.source = st.choice;
                if (st.choice == 'device') { req.device = trim(st.device); req.baud = int(st.baud); }
                const r = ctx.act('setGpsSource', req);
                st.result = r.error ? { tone: 'error', text: r.error }
                                    : { tone: 'success', text: 'Applied. The forwarders are restarting.' };
                ctx.refresh();
            } } ] });
            return out;
        },
    };
};
