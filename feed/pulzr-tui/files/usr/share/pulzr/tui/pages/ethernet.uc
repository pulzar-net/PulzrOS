// Backhaul / Ethernet — console/src/pages/backhaul/Ethernet.tsx.
//
// One wired uplink at a time, picked by tab when pulzr-ports has made more
// than one. Addressing goes through the same undo window as the web page,
// confirmed at once: whoever is at this terminal is on the serial port, which
// no network change can take away.
return function(ctx) {
    const ui = ctx.ui, api = ctx.api;
    const st = { ports: null, net: null, pick: 0, forms: {}, result: null };

    const uplinks = () => {
        const out = [];
        for (let p in st.ports?.ports ?? []) {
            if (p.role == 'uplink' && p.uplink)
                push(out, { key: p.name, label: p.label, port: p.name, vid: null, ...p.uplink });
            for (let v in p.vlans ?? [])
                if (v.role == 'uplink' && v.uplink)
                    push(out, { key: sprintf('%s.%d', p.name, v.vid), label: sprintf('%s VLAN %d', p.label, v.vid),
                                port: p.name, vid: v.vid, ...v.uplink });
        }
        return out;
    };

    const formFor = (u) => {
        st.forms[u.key] ??= {
            mode: u.addressing?.mode ?? 'dhcp',
            address: u.addressing?.address ?? '',
            netmask: u.addressing?.netmask ?? '255.255.255.0',
            gateway: u.addressing?.gateway ?? '',
            dns: join(', ', u.addressing?.dns ?? []),
        };
        return st.forms[u.key];
    };

    const apply = (u) => {
        const f = formFor(u);
        const dns = filter(map(split(f.dns, ','), (x) => trim(x)), (x) => length(x));
        const addressing = f.mode == 'static'
            ? { mode: 'static', address: f.address, netmask: f.netmask, gateway: f.gateway, dns }
            : { mode: 'dhcp' };
        const r = ctx.act('setUplinkAddressing', { port: u.port, vid: u.vid, addressing });
        if (!r.error) ctx.act('confirmPorts', {});
        st.result = r.error ? { tone: 'error', text: r.error } : { tone: 'success', text: 'Applied.' };
        if (!r.error) ctx.refresh();
    };

    return {
        load: function() {
            st.ports = api.ports.status();
            st.net = api.network.status();
        },
        view: function(width) {
            const list = uplinks();
            const out = [];
            if (st.ports?.error) {
                push(out, { t: 'notice', tone: 'error', text: st.ports.error });
                return out;
            }
            if (!length(list)) {
                push(out, { t: 'notice', tone: 'info', text: 'No port is an uplink.' });
                return out;
            }
            if (st.pick >= length(list)) st.pick = 0;
            if (length(list) > 1)
                push(out, { t: 'tabs', items: map(list, (u, i) => ({
                    label: u.label, key: 'uplink:' + u.key, active: i == st.pick, run: () => { st.pick = i; },
                })) });
            const u = list[st.pick], f = formFor(u);
            push(out,
                { t: 'fact', label: 'State', value: ui.status(u.state?.up === true) },
                { t: 'fact', label: 'Address', value: u.state?.address },
                { t: 'fact', label: 'Gateway', value: u.state?.gateway });
            if (st.ports.console == u.port && u.vid == null)
                push(out,
                    { t: 'fact', label: 'Console address', value: st.net?.console?.address },
                    { t: 'fact', label: 'Link-local', value: st.net?.linkLocal?.address });
            push(out,
                { t: 'section', title: 'Addressing' },
                { t: 'tabs', items: [
                    { label: 'DHCP', key: 'mode:dhcp', active: f.mode == 'dhcp', run: () => { f.mode = 'dhcp'; } },
                    { label: 'Static', key: 'mode:static', active: f.mode == 'static', run: () => { f.mode = 'static'; } },
                ] });
            if (f.mode == 'static') {
                push(out, { t: 'field', label: 'Address', value: f.address, placeholder: '10.0.0.50', set: (v) => { f.address = v; } });
                push(out, { t: 'field', label: 'Netmask', value: f.netmask, set: (v) => { f.netmask = v; } });
                push(out, { t: 'field', label: 'Gateway', value: f.gateway, placeholder: '10.0.0.1', set: (v) => { f.gateway = v; } });
                push(out, { t: 'field', label: 'DNS', value: f.dns, placeholder: '1.1.1.1, 8.8.8.8', set: (v) => { f.dns = v; } });
            }
            if (st.result) push(out, { t: 'notice', tone: st.result.tone, text: st.result.text });
            push(out, { t: 'buttons', items: [ { label: 'Apply', primary: true, run: () => apply(u) } ] });
            return out;
        },
    };
};
