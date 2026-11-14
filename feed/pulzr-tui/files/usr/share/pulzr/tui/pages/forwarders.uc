// LoRaWAN / Forwarders — console/src/pages/lorawan/Forwarders.tsx.
//
// One forwarder per concentrator slot, each with the web page's four tabs.
return function(ctx) {
    const ui = ctx.ui, fmt = ctx.fmt, api = ctx.api;
    const st = { view: null, concentrator: null, index: 0, tab: 'status', form: {}, formFrom: {}, result: null };

    const TABS = [ [ 'status', 'Status' ], [ 'mqtt', 'MQTT' ], [ 'gnss', 'GNSS' ], [ 'concentrator', 'Concentrator' ] ];

    const dot = (f) => {
        if (f.slot.status != 'present') return 'neutral';
        if (!f.running) return 'error';
        if (f.mqtt != 'connected') return 'warning';
        return 'success';
    };

    const restart = () => { ctx.act('restart'); ctx.later(4, () => ctx.refresh()); };
    const redetect = () => { ctx.act('detect'); ctx.refresh(); };

    const statusTab = (f, out) => {
        const s = f.stats;
        if (f.slot.status != 'present')
            push(out, { t: 'notice', tone: 'warning', text: sprintf('Concentrator %d did not respond.', f.index + 1) });
        else if (!f.running)
            push(out, { t: 'notice', tone: 'error', text: 'Concentratord is not running.' });
        if (f.running && (s?.received ?? 0) == 0)
            push(out, { t: 'notice', tone: 'warning', text: 'Nothing heard.' });
        if ((s?.received ?? 0) > 0 && (s?.forwarded ?? 0) == 0)
            push(out, { t: 'notice', tone: 'warning', text: 'Hearing uplinks, forwarding none.' });
        push(out, { t: 'fact', label: 'Concentratord', value: ui.status(f.running, 'Running', 'Stopped') });
        push(out, { t: 'fact', label: 'MQTT forwarder', value: ui.status(f.forwarding, 'Running', 'Stopped') });
        push(out, { t: 'fact', label: 'Gateway ID', value: f.gatewayId ?? 'From the chip' });
        push(out, { t: 'fact', label: 'Channels', value: f.slot.profile?.channels ?? f.slot.channels });
        push(out, { t: 'fact', label: 'Uplinks heard', value: s ? fmt.count(s.received) : null });
        push(out, { t: 'fact', label: 'Uplinks forwarded', value: s ? fmt.count(s.forwarded) : null });
        push(out, { t: 'fact', label: 'Downlinks sent', value: s ? fmt.count(s.transmitted) : null });
        push(out, { t: 'fact', label: 'CRC valid', value: s && s.crcOkPercent != null ? sprintf('%s%%', s.crcOkPercent) : null });
        push(out, { t: 'fact', label: 'Last uplink', value: s ? s.lastUplink : null });
    };

    const mqttTab = (f, out) => {
        const m = st.view.mqtt ?? {};
        if (!m.host) {
            push(out, { t: 'notice', tone: 'info', text: 'Not adopted, so no broker.' });
            return;
        }
        const upstream = sprintf('ssl://%s:%d', m.host, m.port);
        push(out, { t: 'fact', label: 'Connection', value: f.mqtt == null ? null
                    : ui.status(f.mqtt == 'connected', 'Connected', 'Not connected') });
        push(out, { t: 'fact', label: 'Publishes to', value: m.buffered ? 'Local buffer' : upstream });
        if (m.buffered) push(out, { t: 'fact', label: 'LNS broker', value: upstream });
        push(out, { t: 'fact', label: 'Topic prefix', value: m.topicPrefix });
        push(out, { t: 'fact', label: 'Username', value: m.username });
        push(out, { t: 'fact', label: 'TLS', value: 'System CA bundle' });
    };

    const gnssTab = (f, out) => {
        const g = f.gnss ?? {}, loc = st.view.location ?? {};
        push(out, { t: 'fact', label: 'Receiver', value: g.attached ? g.device : { badge: 'None', tone: 'neutral' } });
        push(out, { t: 'fact', label: 'Timing', value: g.attached ? 'GPS time and PPS' : 'Gateway clock' });
        push(out, { t: 'fact', label: 'Reports', value: g.attached ? 'The receiver’s position' : 'The recorded position' });
        if (!g.attached) {
            push(out, { t: 'fact', label: 'Recorded position', value: loc.latitude && loc.longitude
                        ? sprintf('%s, %s', loc.latitude, loc.longitude) : null });
            push(out, { t: 'fact', label: 'Recorded from', value: loc.source });
        }
    };

    const concentratorTab = (f, out) => {
        const slot = f.slot, p = slot.profile ?? {};
        if (slot.mismatch)
            push(out, { t: 'notice', tone: 'warning', text: sprintf('Set to %s; detected %s.', slot.override, slot.detected) });
        push(out, { t: 'fact', label: 'State', value: { badge: slot.status,
            tone: slot.status == 'present' ? 'success' : (slot.status == 'absent' ? 'error' : 'warning') } });
        push(out, { t: 'fact', label: 'Device', value: slot.device });
        push(out, { t: 'fact', label: 'Detected', value: slot.detected });
        push(out, { t: 'fact', label: 'Active', value: slot.active });
        push(out, { t: 'fact', label: 'Chip', value: p.chip });
        push(out, { t: 'fact', label: 'Also sold as', value: p.known_as ? join(', ', p.known_as) : null });
        if (slot.bus == 'spi') push(out, { t: 'fact', label: 'Reset GPIO', value: slot.resetGpio || 'Not probed yet' });

        const c = st.concentrator;
        if (!c || !c.configurable) return;

        // The form follows the slot whenever the slot changes underneath it.
        const from = sprintf('%s|%s|%s|%s', slot.override ?? '', slot.bus, slot.device, slot.resetGpioOverride);
        if (st.formFrom[f.index] != from) {
            st.formFrom[f.index] = from;
            st.form[f.index] = { override: slot.override ?? '', bus: slot.bus ?? '', device: slot.device ?? '',
                                 resetGpio: slot.resetGpioOverride ?? '' };
        }
        const form = st.form[f.index];
        const parts = [ { value: '', label: 'Automatic ' + ui.glyph('dash') + ' use what is detected' } ];
        for (let s in (c.supported ?? []))
            push(parts, { value: s.id, label: s.detectable ? s.name : s.name + ' ' + ui.glyph('dash') + ' manual only' });

        push(out, { t: 'section', title: 'Hardware' });
        push(out, { t: 'choice', label: 'Part', value: form.override, options: parts, set: (v) => { form.override = v; } });
        push(out, { t: 'choice', label: 'Bus', value: form.bus, options: [
            { value: '', label: 'Automatic' }, { value: 'spi', label: 'SPI' },
            { value: 'usb', label: 'USB' }, { value: 'uart', label: 'UART' },
        ], set: (v) => { form.bus = v; } });
        push(out, { t: 'field', label: 'Device', value: form.device, placeholder: '/dev/spidev0.0',
                    set: (v) => { form.device = v; } });
        push(out, { t: 'field', label: 'Reset GPIO override', value: form.resetGpio,
                    placeholder: "Use the part's own pin", set: (v) => { form.resetGpio = v; } });
        if (st.result) push(out, { t: 'notice', tone: st.result.tone, text: st.result.text });
        push(out, { t: 'buttons', items: [ { label: 'Apply and restart', primary: true, run: () => {
            const r = ctx.act('setSlot', { index: slot.index, override: form.override, bus: form.bus,
                                           device: form.device, resetGpio: form.resetGpio });
            const err = r.error ?? r.concentrator?.error;
            st.result = err ? { tone: 'error', text: err }
                            : { tone: 'success', text: 'Applied. Re-detecting and restarting.' };
            ctx.refresh();
        } } ] });
    };

    return {
        interval: 10,
        load: function() {
            st.view = api.lorawan.forwarders();
            if (st.tab == 'concentrator') st.concentrator = api.lorawan.concentrator();
            if (st.index >= length(st.view.forwarders ?? [])) st.index = 0;
        },
        view: function(width) {
            const list = st.view.forwarders ?? [];
            const out = [];
            if (!length(list)) return out;

            push(out, { t: 'tabs', items: map(list, (f) => ({
                label: sprintf('Forwarder %d', f.index + 1), key: sprintf('fwd:%d', f.index),
                active: f.index == st.index, mark: { text: ui.glyph('bullet'), tone: dot(f) },
                run: () => { st.index = f.index; st.result = null; },
            })) });
            push(out, { t: 'tabs', items: map(TABS, (t) => ({
                label: t[1], key: 'tab:' + t[0], active: st.tab == t[0],
                run: () => {
                    st.tab = t[0];
                    if (t[0] == 'concentrator' && !st.concentrator) st.concentrator = api.lorawan.concentrator();
                },
            })) });
            const actions = [ { label: 'Restart', run: restart } ];
            if (st.tab == 'concentrator') push(actions, { label: 'Re-detect', run: redetect });
            push(out, { t: 'buttons', items: actions });
            push(out, { t: 'blank' });

            const f = list[st.index];
            if (st.tab == 'status') statusTab(f, out);
            else if (st.tab == 'mqtt') mqttTab(f, out);
            else if (st.tab == 'gnss') gnssTab(f, out);
            else concentratorTab(f, out);
            return out;
        },
    };
};
