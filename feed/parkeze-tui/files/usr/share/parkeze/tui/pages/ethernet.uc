// Backhaul / Ethernet — console/src/pages/backhaul/Ethernet.tsx.
return function(ctx) {
    const ui = ctx.ui, api = ctx.api;
    const st = { net: null, form: null, result: null };

    const apply = () => {
        const f = st.form;
        const dns = filter(map(split(f.dns, ','), (x) => trim(x)), (x) => length(x));
        const r = ctx.act('setEthernet', { mode: f.mode, address: f.address, netmask: f.netmask,
                                           gateway: f.gateway, dns });
        st.result = r.error ? { tone: 'error', text: r.error } : { tone: 'success', text: 'Applied.' };
        if (!r.error) ctx.refresh();
    };

    return {
        load: function() {
            st.net = api.network.status();
            // The form starts from the first load and is then the
            // technician's, as the web form is: a refresh must not wipe what
            // is half typed.
            if (!st.form) {
                const wan = st.net.wan ?? {};
                st.form = {
                    mode: wan.mode ?? 'dhcp',
                    address: wan.staticAddress ?? '',
                    netmask: wan.staticNetmask ?? '255.255.255.0',
                    gateway: wan.staticGateway ?? '',
                    dns: join(', ', wan.dns ?? []),
                };
            }
        },
        view: function(width) {
            const wan = st.net.wan ?? {}, f = st.form;
            const out = [
                { t: 'fact', label: 'State', value: ui.status(wan.up === true) },
                { t: 'fact', label: 'Address', value: wan.address },
                { t: 'fact', label: 'Gateway', value: wan.gateway },
                { t: 'fact', label: 'Console address', value: st.net.console?.address },
                { t: 'fact', label: 'Link-local', value: st.net.linkLocal?.address },
                { t: 'section', title: 'Addressing' },
                { t: 'tabs', items: [
                    { label: 'DHCP', key: 'mode:dhcp', active: f.mode == 'dhcp', run: () => { f.mode = 'dhcp'; } },
                    { label: 'Static', key: 'mode:static', active: f.mode == 'static', run: () => { f.mode = 'static'; } },
                ] },
            ];
            if (f.mode == 'static') {
                push(out, { t: 'field', label: 'Address', value: f.address, placeholder: '10.0.0.50', set: (v) => { f.address = v; } });
                push(out, { t: 'field', label: 'Netmask', value: f.netmask, set: (v) => { f.netmask = v; } });
                push(out, { t: 'field', label: 'Gateway', value: f.gateway, placeholder: '10.0.0.1', set: (v) => { f.gateway = v; } });
                push(out, { t: 'field', label: 'DNS', value: f.dns, placeholder: '1.1.1.1, 8.8.8.8', set: (v) => { f.dns = v; } });
            }
            if (st.result) push(out, { t: 'notice', tone: st.result.tone, text: st.result.text });
            push(out, { t: 'buttons', items: [ { label: 'Apply', primary: true, run: apply } ] });
            return out;
        },
    };
};
