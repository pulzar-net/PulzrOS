// LoRaWAN / Settings — console/src/pages/lorawan/Settings.tsx.
return function(ctx) {
    const ui = ctx.ui, fmt = ctx.fmt, api = ctx.api;
    const st = { status: null, concentrator: null, region: null, regionFrom: null, result: null };
    const REGIONS = [ 'US915', 'EU868', 'AU915', 'AS923', 'IN865', 'KR920', 'RU864' ];

    const setDelivery = (req) => {
        ctx.act('setBackhaul', req);
        ctx.later(3, () => ctx.refresh());
    };

    return {
        interval: 15,
        load: function() {
            st.status = api.lorawan.status();
            st.concentrator = api.lorawan.concentrator();
            if (st.concentrator.region != st.regionFrom) {
                st.regionFrom = st.concentrator.region;
                st.region = st.concentrator.region;
            }
        },
        view: function(width) {
            const out = [];
            push(out, { t: 'section', title: 'Region plan' });
            push(out, { t: 'choice', label: 'Region', value: st.region, options: map(REGIONS, (r) => ({ value: r, label: r })),
                        set: (v) => { st.region = v; } });
            if (st.result) push(out, { t: 'notice', tone: st.result.tone, text: st.result.text });
            push(out, { t: 'buttons', items: [ { label: 'Apply and restart', primary: true,
                disabled: st.region == st.concentrator.region, run: () => {
                    const r = ctx.act('setConcentrator', { region: st.region });
                    st.result = r.error ? { tone: 'error', text: r.error }
                                        : { tone: 'success', text: 'Applied. The forwarders are restarting.' };
                    ctx.refresh();
                } } ] });

            const b = st.status.backhaul;
            if (b == null) return out;
            const buffer = st.status.buffer;
            const confined = !b.sending;
            const holding = buffer?.enabled ?? false;
            const brokerMissing = holding && !buffer.running;

            push(out, { t: 'section', title: 'Uplink delivery' });
            if (brokerMissing)
                push(out, { t: 'notice', tone: 'error', text: 'Holding is on and the local broker is not running. Uplinks are being lost.' });
            else if (confined && holding)
                push(out, { t: 'notice', tone: 'warning', text: 'Wired and WiFi are down. Uplinks are being held.' });
            else if (confined)
                push(out, { t: 'notice', tone: 'error', text: 'Wired and WiFi are down. Uplinks are being dropped.' });

            push(out, { t: 'fact', label: 'Sending', value: ui.status(b.sending, 'Yes', holding ? 'Held' : 'No') });
            push(out, { t: 'fact', label: 'Wired', value: ui.status(b.wiredUp) });
            if (b.wifiUp != null) push(out, { t: 'fact', label: 'WiFi', value: ui.status(b.wifiUp) });
            if (holding) {
                push(out, { t: 'fact', label: 'Queued', value: buffer.persistent ? fmt.bytes(buffer.queuedBytes) : 'In memory' });
                push(out, { t: 'fact', label: 'Local broker', value: ui.status(buffer.running,
                            sprintf('Running on %s', buffer.port), 'Not running') });
            }
            push(out, { t: 'check', label: 'Allow uplinks over cellular', checked: !!b.allowCellular,
                        set: (v) => setDelivery({ allowCellular: v }) });
            push(out, { t: 'check', label: 'Hold uplinks that cannot be sent', checked: holding,
                        set: (v) => setDelivery({ buffer: v }) });
            return out;
        },
    };
};
