// The claim screen — console/src/pages/Onboarding.tsx.
//
// Shown before sign-in on a gateway nobody has adopted, and at /adopt from the
// "Not adopted" banner once signed in.
return function(ctx) {
    const ui = ctx.ui, api = ctx.api;
    const _m_fs = require('fs');
    const st = { status: null, qr: null, qrFor: null, bundleOpen: false, bundle: '', applyError: null };

    const url = () => {
        const p = _m_fs.popen('/usr/sbin/parkeze-claim qr 2>/dev/null', 'r');
        const out = p ? trim(p.read('all') ?? '') : '';
        if (p) p.close();
        return out;
    };

    return {
        // Every three seconds until somebody claims it, as the web page polls.
        interval: () => st.status?.adoption == 'adopted' ? null : 3,
        load: function() {
            st.status = api.claim.status();
            if (st.status.error) die(st.status.error);
            // The QR changes once parkeze.net knows the claim (a short URL
            // instead of the identity inline), so it follows the URL.
            const u = url();
            if (u != st.qrFor) { st.qrFor = u; st.qr = length(u) ? ctx.qr(u) : null; }
        },
        view: function(width) {
            const c = st.status, out = [];
            if (c.adoption == 'adopted') {
                push(out, { t: 'section', title: 'Adopted' });
                push(out, { t: 'text', text: sprintf('Belongs to %s. Local sign-in is off.', c.org ?? 'an organization') });
                push(out, { t: 'buttons', items: [ { label: 'Open the console', primary: true, run: () => ctx.home() } ] });
                return out;
            }

            push(out, { t: 'section', title: 'Claim this gateway' });
            if (st.qr && ctx.term.cols(st.qr[0]) <= width) push(out, { t: 'pre', lines: st.qr });
            else if (!st.qr) push(out, { t: 'notice', tone: 'error', text: 'Could not render the QR. Use the code below.' });
            push(out, { t: 'fact', label: 'Code', value: { text: c.claimId, tone: 'bold' } });
            if (c.url) push(out, { t: 'fact', label: 'Open in Parkeze', value: c.url });
            if (!c.online) push(out, { t: 'notice', tone: 'warning', text: 'No internet. The code still works from a phone with signal.' });
            else if (!c.registered) push(out, { t: 'notice', tone: 'info', text: 'Registering with Parkeze.' });

            push(out, { t: 'blank' }, { t: 'text', tone: 'dim', text: 'Waiting to be claimed' });
            push(out, { t: 'buttons', items: [ { label: 'Check now', run: () => {
                const r = ctx.act('claimPoll');
                if (!r.error) st.status = r;
            } } ] });
            if (!ctx.session())
                push(out, { t: 'buttons', items: [ { label: 'Look at the console without adopting', run: () => ctx.browse() } ] });

            if (!st.bundleOpen) {
                push(out, { t: 'buttons', items: [ { label: 'This gateway will never have internet', run: () => { st.bundleOpen = true; } } ] });
                return out;
            }
            push(out, { t: 'blank' });
            push(out, { t: 'field', label: 'Adoption bundle', value: st.bundle, placeholder: 'Paste the signed bundle from Parkeze',
                        max: 8192, set: (v) => { st.bundle = v; st.applyError = null; } });
            if (st.applyError) push(out, { t: 'notice', tone: 'error', text: st.applyError });
            push(out, { t: 'buttons', items: [ { label: 'Adopt this gateway', primary: true, disabled: !length(trim(st.bundle)),
                run: () => {
                    const r = ctx.act('claimApply', { bundle: trim(st.bundle) });
                    if (r.error) st.applyError = r.error;
                    else ctx.refresh();
                } } ] });
            return out;
        },
    };
};
