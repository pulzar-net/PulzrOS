// System / Maintenance — console/src/pages/system/Maintenance.tsx.
//
// The firmware upload is the one thing that differs: a terminal has no file
// picker, so the image is a path on the gateway — the SD card, or /tmp after
// copying it over SSH — and goes through the same checks as an upload.
return function(ctx) {
    const ui = ctx.ui, api = ctx.api;
    const st = { summary: null, password: '', confirm: '', pwResult: null,
                 image: '', manifest: '', fwResult: null, upgrading: false, rebooting: false, rebootError: null };

    return {
        load: function() { st.summary = api.system.summary(); },
        view: function(width) {
            const fw = st.summary.firmware ?? {}, id = st.summary.identity ?? {};
            const out = [];

            const mismatch = length(st.confirm) && st.confirm != st.password;
            const tooShort = length(st.password) && length(st.password) < 12;
            push(out, { t: 'section', title: 'Local password' });
            push(out, { t: 'field', label: 'New password', value: st.password, secret: true, set: (v) => { st.password = v; } });
            push(out, { t: 'field', label: 'Confirm', value: st.confirm, secret: true, set: (v) => { st.confirm = v; } });
            if (mismatch) push(out, { t: 'notice', tone: 'error', text: 'The two passwords do not match.' });
            if (st.pwResult) push(out, { t: 'notice', tone: st.pwResult.tone, text: st.pwResult.text });
            push(out, { t: 'buttons', items: [ { label: 'Change password', primary: true,
                disabled: !length(st.password) || mismatch || tooShort, run: () => {
                    const r = ctx.act('setPassword', { password: st.password });
                    if (r.error) st.pwResult = { tone: 'error', text: r.error };
                    else { st.pwResult = { tone: 'success', text: 'Password changed.' }; st.password = ''; st.confirm = ''; }
                } } ] });

            push(out, { t: 'section', title: 'Firmware' });
            push(out, { t: 'fact', label: 'PulzrOS', value: fw.version ? sprintf('%s (build %s)', fw.version, fw.build) : null });
            push(out, { t: 'fact', label: 'Commit', value: fw.commit });
            push(out, { t: 'fact', label: 'OpenWrt', value: fw.openwrt });
            push(out, { t: 'fact', label: 'Kernel', value: fw.kernel });
            push(out, { t: 'fact', label: 'Board', value: id.boardName });
            if (st.upgrading) {
                push(out, { t: 'notice', tone: 'info', text: 'Upgrading. The gateway restarts in a few minutes.' });
            } else {
                push(out, { t: 'field', label: 'Image', value: st.image, placeholder: '/mnt/storage/pulzr.bin',
                            set: (v) => { st.image = v; st.fwResult = null; } });
                push(out, { t: 'field', label: 'Signature', value: st.manifest, placeholder: 'optional',
                            set: (v) => { st.manifest = v; st.fwResult = null; } });
                if (st.fwResult) push(out, { t: 'notice', tone: 'error', text: st.fwResult });
                push(out, { t: 'buttons', items: [ { label: 'Upgrade', danger: true, disabled: !length(trim(st.image)),
                    confirm: sprintf('Install %s and restart?', trim(st.image)), confirmLabel: 'Upgrade',
                    run: () => {
                        const r = ctx.act('installFirmware', { path: trim(st.image), manifest: trim(st.manifest) });
                        if (r.error) st.fwResult = r.error;
                        else st.upgrading = true;
                    } } ] });
            }

            push(out, { t: 'section', title: 'Power' });
            if (st.rebooting) {
                push(out, { t: 'notice', tone: 'info', text: 'Rebooting. Back in a minute.' });
            } else {
                if (st.rebootError) push(out, { t: 'notice', tone: 'error', text: st.rebootError });
                push(out, { t: 'buttons', items: [ { label: 'Reboot gateway', danger: true,
                    confirm: 'Reboot the gateway?', confirmLabel: 'Yes, reboot now', run: () => {
                        const r = ctx.act('reboot');
                        if (r.error) st.rebootError = r.error; else st.rebooting = true;
                    } } ] });
            }
            return out;
        },
    };
};
