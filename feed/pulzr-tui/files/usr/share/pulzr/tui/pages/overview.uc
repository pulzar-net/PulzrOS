// Overview — console/src/pages/Overview.tsx.
return function(ctx) {
    const ui = ctx.ui, fmt = ctx.fmt, api = ctx.api;
    const st = { summary: null, backhaul: null, lora: null, addons: null, features: null };

    // The web console's addonBadge, word for word: an add-on an upgrade has
    // yet to put back reads Restoring until it is in.
    const STATES = {
        downloading: [ 'Downloading', 'info' ], installing: [ 'Installing', 'info' ],
        removing: [ 'Removing', 'info' ], reverted: [ 'Reverted', 'warning' ],
        failed: [ 'Failed', 'error' ], 'pending-restore': [ 'Restoring', 'info' ],
        unavailable: [ 'Unavailable', 'neutral' ],
    };
    const addonBadge = (it) => {
        if (it.state != 'installed') {
            const s = STATES[it.state] ?? [ it.state, 'neutral' ];
            return { badge: s[0], tone: s[1] };
        }
        if (it.health == 'ok') return { badge: 'Running', tone: 'success' };
        if (it.health == 'idle') return { badge: 'Idle', tone: 'neutral' };
        if (it.health == 'failing') return { badge: 'Failing', tone: 'error' };
        return { badge: 'Installed', tone: 'success' };
    };

    return {
        interval: 15,
        load: function() {
            st.summary = api.system.summary();
            st.backhaul = api.network.backhaul();
            st.lora = api.lorawan.status();
            st.addons = api.addons.status();
            st.features = api.system.features();
        },
        view: function(width) {
            const s = st.summary, b = st.backhaul ?? {}, l = st.lora;
            const id = s.identity ?? {}, fw = s.firmware ?? {}, health = s.health ?? {};
            const out = [];

            // The mark, where the screen can spare eight rows for it: a Pi's
            // HDMI, a big SSH window. Not on a 24-row serial console.
            if (ctx.term.state.rows >= 34) push(out, { t: 'pre', lines: ctx.banner(width) }, { t: 'blank' });

            if (id.serialSource == 'random')
                push(out, { t: 'notice', tone: 'warning', text: 'No hardware serial. Using a random one, which changes on reflash.' });
            const c = l ? l.concentrator : null;
            if (c && c.status == 'partial')
                push(out, { t: 'notice', tone: 'warning', text: sprintf(
                    '%d of %d concentrators responded. Running at %d of %d channels.',
                    c.present, c.slots, c.channels, c.slots * 8) });

            const tunnel = b.tunnel ?? {};
            push(out, { t: 'section', title: 'Wired ' + ui.glyph('dot') + ' Management tunnel' });
            push(out, { t: 'fact', label: 'Ethernet', value: ui.status(b.wired?.up) });
            push(out, { t: 'fact', label: 'Tunnel', value: ui.status(tunnel.state == 'up', 'Connected',
                                                                      tunnel.state == 'none' ? 'Not enrolled' : 'Offline') });
            push(out, { t: 'fact', label: 'Address', value: tunnel.address });

            const cell = b.cellular ?? {};
            const kind = cell.modem?.kind;
            // A dongle or a phone carries whatever SIM is in it, not 1NCE's.
            const usb = kind == 'hilink' || kind == 'tether';
            // Cellular where the web console shows it (hooks/useCellular): the
            // add-on built into a board with a soldered modem, or a modem
            // plugged in. An Opal with neither read "Adapter Absent".
            const builtIn = st.addons?.items?.['pulzr-cellular']?.builtIn === true;
            if ('cellular' in (st.features ?? []) && (builtIn || cell.modem != null)) {
                push(out, { t: 'section', title: usb ? 'Cellular' : 'Cellular ' + ui.glyph('dot') + ' 1NCE' });
                push(out, { t: 'fact', label: 'Adapter',
                            value: ui.status(cell.modem != null, fmt.modemKind(kind) ?? 'Present', 'Absent') });
                push(out, { t: 'fact', label: 'Data', value: ui.status(cell.up) });
                push(out, { t: 'fact', label: 'Signal', value: cell.modem?.rssi != null ? sprintf('%d dBm', cell.modem.rssi) : null });
            }

            const adoption = s.adoption ?? {};
            push(out, { t: 'section', title: 'Identity' });
            push(out, { t: 'fact', label: 'Gateway EUI', value: id.gatewayEui });
            push(out, { t: 'fact', label: 'Serial', value: id.serial });
            push(out, { t: 'fact', label: 'Board', value: id.boardName ? sprintf('%s (%s)', id.boardName, id.board) : null });
            push(out, { t: 'fact', label: 'Adoption', value: adoption.state == 'adopted'
                ? { badge: adoption.org ? 'Adopted ' + ui.glyph('dot') + ' ' + adoption.org : 'Adopted', tone: 'success' }
                : { badge: 'Not adopted', tone: 'warning' } });

            const items = st.addons?.items ?? {};
            if (length(keys(items))) {
                push(out, { t: 'section', title: 'Add-ons' });
                for (let n in sort(keys(items)))
                    push(out, { t: 'fact', label: items[n].title ?? n, value: addonBadge(items[n]) });
            }

            push(out, { t: 'section', title: 'Firmware' });
            push(out, { t: 'fact', label: 'PulzrOS', value: fw.version ? sprintf('%s (%s)', fw.version, fw.commit) : null });
            push(out, { t: 'fact', label: 'Uptime', value: fmt.duration(health.uptime) });
            if (health.temperature != null)
                push(out, { t: 'fact', label: 'Temperature', value: sprintf('%.1f %sC', health.temperature, ui.glyph('degree')) });
            return out;
        },
    };
};
