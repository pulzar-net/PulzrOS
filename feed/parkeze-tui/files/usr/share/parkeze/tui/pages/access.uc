// Access — console/src/pages/Access.tsx.
return function(ctx) {
    const ui = ctx.ui, fmt = ctx.fmt, api = ctx.api;
    const st = { access: null, backhaul: null, key: null, showKey: false };

    const ap = (name, req) => { ctx.act(name, req); ctx.refresh(); };

    return {
        // Ten seconds while the access point is up, thirty when it is not.
        interval: () => st.access?.ap?.up ? 10 : 30,
        load: function() {
            st.access = api.access.status();
            st.backhaul = api.network.backhaul();
        },
        view: function(width) {
            const a = st.access, p = a.ap ?? {}, out = [];

            push(out, { t: 'section', title: 'Setup access point', note: !p.capable ? null
                : (p.up ? { badge: 'Broadcasting', tone: 'warning' }
                        : { badge: p.enabled ? 'Standby' : 'Disabled', tone: 'neutral' }) });
            if (!p.capable) {
                push(out, { t: 'notice', tone: 'info', text: p.reason ?? 'This board has no WiFi radio.' });
            } else {
                push(out, { t: 'fact', label: 'Network', value: p.ssid });
                push(out, { t: 'fact', label: 'Security', value: p.secured
                    ? { badge: 'WPA2, per-device key', tone: 'success' }
                    : { badge: 'Open ' + ui.glyph('dash') + ' gateway is unadopted', tone: 'warning' } });
                push(out, { t: 'fact', label: 'Connected', value: p.clients ? sprintf('%d device(s)', p.clients) : 'Nobody' });
                if (p.up && p.remainingSeconds > 0)
                    push(out, { t: 'fact', label: 'Comes down in', value: fmt.duration(p.remainingSeconds) });
                if (p.secured) {
                    if (st.showKey)
                        push(out, { t: 'buttons', label: 'Passphrase', items: [
                            { label: 'Hide', key: 'key', run: () => { st.showKey = false; } } ] },
                            { t: 'fact', label: '', value: st.key?.key });
                    else
                        push(out, { t: 'buttons', label: 'Passphrase', items: [ { label: 'Show', key: 'key', run: () => {
                            st.showKey = true;
                            st.key = api.access.key();
                        } } ] });
                }
                push(out, { t: 'blank' });
                push(out, { t: 'check', label: 'Allow the setup access point', checked: !!p.enabled,
                            set: (v) => ap('setAp', { enabled: v }) });
                push(out, { t: 'check', label: 'Raise it automatically when the gateway goes offline', checked: !!p.fallback,
                            disabled: !p.enabled, set: (v) => ap('setAp', { fallback: v }) });
                push(out, { t: 'buttons', items: [ p.up
                    ? { label: 'Take it down now', danger: true, run: () => ap('lowerAp', {}) }
                    : { label: 'Raise it for 30 minutes', disabled: !p.enabled, run: () => ap('raiseAp', { window: 1800 }) } ] });
            }

            const b = st.backhaul, t = b?.tunnel ?? {}, wired = b?.wired ?? {};
            push(out, { t: 'section', title: 'Management tunnel' });
            push(out, { t: 'fact', label: 'State', value: b == null ? null : ui.status(t.state == 'up', 'Connected',
                t.state == 'none' ? 'Not enrolled' : (t.state == 'waiting' ? 'No recent handshake' : 'Unknown')) });
            push(out, { t: 'fact', label: 'Address', value: t.address });
            push(out, { t: 'fact', label: 'Hub', value: t.endpoint });
            push(out, { t: 'fact', label: 'Last handshake', value: t.lastHandshake != null ? sprintf('%ds ago', t.lastHandshake) : null });
            push(out, { t: 'fact', label: 'Egress', value: wired.device ? sprintf('%s %s %s', wired.device, ui.glyph('right'), wired.gateway)
                : (b ? { badge: 'No wired route', tone: 'warning' } : null) });

            const port = a.port ?? {};
            push(out, { t: 'section', title: 'Ethernet port', note: port.uplink
                ? { badge: 'Uplink up', tone: 'success' } : { badge: 'No uplink', tone: 'neutral' } });
            push(out, { t: 'fact', label: 'Local name', value: sprintf('https://%s.local', port.hostname) });
            push(out, { t: 'fact', label: 'Console address', value: sprintf('https://%s', port.console) });
            push(out, { t: 'fact', label: 'Uplink', value: port.uplink ?? 'No lease' });

            // The USB port, on a board built with it: see parkeze-usb-gadget.
            const usb = a.usb;
            if (usb && usb.present) {
                push(out, { t: 'section', title: 'USB port', note: usb.connected
                    ? { badge: 'Connected', tone: 'success' } : { badge: 'Nothing attached', tone: 'neutral' } });
                push(out, { t: 'fact', label: 'Local name', value: sprintf('https://%s', usb.name) });
                push(out, { t: 'fact', label: 'Console address', value: sprintf('https://%s', usb.address) });
            }
            return out;
        },
    };
};
