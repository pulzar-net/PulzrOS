// Bluetooth — console/src/pages/Bluetooth.tsx.
return function(ctx) {
    const ui = ctx.ui, api = ctx.api;
    const st = { bt: null, error: null };

    return {
        interval: 10,
        load: function() { st.bt = api.bluetooth.status(); },
        view: function(width) {
            const b = st.bt, out = [];
            if (b.state == 'absent') {
                push(out, { t: 'notice', tone: 'info', text: 'This gateway has no Bluetooth radio.' });
                return out;
            }
            const actions = [];
            if (b.rebootRequired) push(actions, { label: 'Reboot', run: () => ctx.act('reboot') });
            push(actions, b.enabled
                ? { label: 'Turn off', key: 'toggle', run: () => {
                      const r = ctx.act('setBluetooth', { enabled: false }); st.error = r.error; ctx.refresh(); } }
                : { label: 'Turn on', key: 'toggle', primary: true, run: () => {
                      const r = ctx.act('setBluetooth', { enabled: true }); st.error = r.error; ctx.refresh(); } });
            push(out, { t: 'buttons', items: actions });

            if (b.enabled && b.rebootRequired)
                push(out, { t: 'notice', tone: 'warning', text: 'Bluetooth starts after a reboot.' });
            else if (b.enabled && !b.running)
                push(out, { t: 'notice', tone: 'error', text: 'Bluetooth is on but not scanning. The log says why.' });
            if (st.error) push(out, { t: 'notice', tone: 'error', text: st.error });

            push(out, { t: 'fact', label: 'Scanning', value: !b.enabled ? 'Off' : (b.running ? 'Yes' : 'No') });
            if (b.enabled && b.heard) push(out, { t: 'fact', label: 'Beacons heard', value: sprintf('%s', b.heard.beacons) });
            push(out, { t: 'fact', label: 'Sending', value: b.oui ? join(', ', split(b.oui, ' ')) : 'Every beacon' });
            push(out, { t: 'fact', label: 'Weakest sent', value: sprintf('%s dBm', b.minRssi) });
            return out;
        },
    };
};
