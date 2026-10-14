// Backhaul / Cellular — console/src/pages/backhaul/Cellular.tsx.
return function(ctx) {
    const ui = ctx.ui, api = ctx.api;
    const st = { net: null, form: null, server: null, result: null };

    const apply = () => {
        const r = ctx.act('setCellular', { apn: trim(st.form.apn), enabled: st.form.enabled });
        st.result = r.error ? { tone: 'error', text: r.error }
                            : { tone: 'success', text: 'Applied. The modem is re-attaching.' };
        if (!r.error) ctx.refresh();
    };

    return {
        load: function() {
            st.net = api.network.status();
            const c = st.net.cellular ?? {};
            // Follows the gateway whenever the gateway's own values change,
            // as the web form does, and not otherwise.
            const server = sprintf('%s|%s', c.apn ?? '', c.enabled);
            if (server != st.server) {
                st.server = server;
                st.form = { apn: c.apn ?? '', enabled: !!c.enabled };
            }
        },
        view: function(width) {
            const c = st.net.cellular ?? {}, m = c.modem ?? {};
            const out = [
                { t: 'fact', label: 'State', value: ui.status(c.up === true) },
                { t: 'fact', label: 'Address', value: c.address },
                { t: 'fact', label: 'Network', value: m.network },
                { t: 'fact', label: 'Technology', value: m.technology },
                { t: 'fact', label: 'Signal', value: m.rssi != null ? sprintf('%d dBm', m.rssi) : null },
                { t: 'section', title: 'Connection' },
                { t: 'field', label: 'APN', value: st.form.apn, set: (v) => { st.form.apn = v; } },
                { t: 'check', label: 'Use cellular as a backhaul', checked: st.form.enabled,
                  set: (v) => { st.form.enabled = v; } },
            ];
            if (st.result) push(out, { t: 'notice', tone: st.result.tone, text: st.result.text });
            push(out, { t: 'buttons', items: [ { label: 'Apply', primary: true, run: apply } ] });
            return out;
        },
    };
};
