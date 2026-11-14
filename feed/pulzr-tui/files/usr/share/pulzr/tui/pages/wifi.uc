// Backhaul / WiFi — console/src/pages/backhaul/Wifi.tsx.
//
// The join flow is the web console's, step for step: pick or type a network,
// and for 802.1X look at the server's certificate before trusting it — the
// gateway pins the certificate it was shown, so it is never asked to trust
// one it was not.
return function(ctx) {
    const ui = ctx.ui, api = ctx.api;
    const st = {
        access: null, detail: null, scan: null, scanned: false,
        form: { ssid: '', security: 'psk', key: '', method: 'peap', identity: '', password: '',
                anonymous: '', allowOpen: false },
        probing: false, probe: null, probeError: null,
        forgetError: null, rejoin: null, join: null,
    };

    const commonName = (subject) => {
        const m = match(subject ?? '', /CN=([^\/,]+)/);
        return m ? m[1] : subject;
    };
    const fingerprint = (hash) => {
        if (!hash) return null;
        const h = uc(hash), pairs = [];
        for (let i = 0; i < length(h); i += 2) push(pairs, substr(h, i, 2));
        return join(':', pairs);
    };
    const resetProbe = () => { st.probing = false; st.probe = null; st.probeError = null; };
    const refreshSoon = (seconds) => ctx.later(seconds, () => ctx.refresh());

    // The scan entry for the typed name, which decides the security.
    const selected = () => {
        for (let n in (st.scan?.networks ?? [])) if (n.ssid == st.form.ssid) return n;
        return null;
    };
    const security = () => selected()?.encryption ?? st.form.security;
    const eapMethod = () => st.form.method == 'peap' ? 'peap' : 'ttls';
    const phase2 = () => st.form.method == 'ttls-pap' ? 'PAP' : 'MSCHAPV2';

    const result = () => (st.probe && st.probe.ssid == trim(st.form.ssid)) ? st.probe : null;
    const leaf = () => {
        const r = result();
        if (!r || r.state != 'done') return null;
        for (let c in (r.chain ?? [])) if (c.depth == 0) return c;
        return null;
    };
    const issuer = () => {
        for (let c in (result()?.chain ?? [])) if (c.depth == 1) return c;
        return null;
    };

    const forget = (ssid) => {
        const r = ctx.act('forgetWifi', { ssid });
        if (r.error) st.forgetError = r.error;
        else { st.forgetError = null; refreshSoon(3); }
    };
    const rejoin = (ssid) => {
        const r = ctx.act('joinWifi', { ssid, saved: true });
        st.rejoin = r.error ? { tone: 'error', text: r.error } : { tone: 'success', text: r.message };
        if (!r.error) refreshSoon(4);
    };
    const checkCertificate = () => {
        const f = st.form;
        const req = { ssid: trim(f.ssid), method: eapMethod(), identity: trim(f.identity) };
        if (length(trim(f.anonymous))) req.anonymousIdentity = trim(f.anonymous);
        const r = ctx.act('probeWifi', req);
        if (r.error) { st.probeError = r.error; return; }
        st.probeError = null;
        st.probing = true;
        st.probe = null;
    };
    const join_ = () => {
        const f = st.form, sec = security();
        let req;
        if (sec == 'eap') {
            const l = leaf();
            req = { ssid: trim(f.ssid), eap: { method: eapMethod(), phase2: phase2(), identity: trim(f.identity),
                    password: f.password, certHash: l.hash, certSubject: l.subject } };
            if (length(trim(f.anonymous))) req.eap.anonymousIdentity = trim(f.anonymous);
        } else {
            req = { ssid: trim(f.ssid), allowOpen: f.allowOpen };
            if (length(f.key)) req.key = f.key;
        }
        const r = ctx.act('joinWifi', req);
        st.join = r.error ? { tone: 'error', text: r.error } : { tone: 'success', text: r.message };
        if (!r.error) refreshSoon(4);
    };

    return {
        // Every two seconds while a certificate probe runs, as the web page
        // polls it; every fifteen otherwise.
        interval: () => st.probing ? 2 : 15,
        load: function() {
            st.access = api.access.status();
            try { st.detail = api.access.wifiDetail(); } catch (e) { st.detail = null; }
            if (!st.scanned) { st.scan = api.access.scan(); st.scanned = true; }
            if (st.probing) {
                // A setup-AP client loses the radio during a probe, which is
                // why the web page retries forever. So does this.
                try {
                    st.probe = api.access.probeResult();
                    if (st.probe && st.probe.state != 'probing' && st.probe.state != 'none') st.probing = false;
                } catch (e) {}
            }
        },
        view: function(width) {
            const out = [];
            const wifi = st.access.wifi ?? {}, detail = st.detail ?? {};

            // ── the network it is on ─────────────────────────────────────
            if (wifi.configured) {
                push(out, { t: 'buttons', items: [ { label: 'Forget network', key: 'forget-current', run: () => forget(wifi.ssid) } ] });
                push(out, { t: 'fact', label: 'Network', value: wifi.ssid });
                // Signing in to a portal takes a browser: the console's Sign in,
                // locally or through Pulzar Cloud. Here it is a state and a MAC.
                const warn = { portal: 'Sign-in required', offline: 'No internet', unchecked: 'Checking' };
                push(out, { t: 'fact', label: 'State', value: ui.status(wifi.up, 'Connected', 'Not connected',
                                                                         wifi.up ? warn[wifi.uplink] : null) });
                push(out, { t: 'fact', label: 'Address', value: wifi.address });
                push(out, { t: 'fact', label: 'Signal', value: wifi.signal != null ? sprintf('%d dBm', wifi.signal) : null });
                push(out, { t: 'fact', label: 'MAC', value: wifi.mac });
                if (detail.identity) push(out, { t: 'fact', label: 'Username', value: detail.identity });
                if (detail.certSubject) push(out, { t: 'fact', label: 'Certificate', value: commonName(detail.certSubject) });
                if (detail.certHash) push(out, { t: 'fact', label: 'SHA-256', value: fingerprint(detail.certHash) });
                if (st.forgetError) push(out, { t: 'notice', tone: 'error', text: st.forgetError });
            }

            // ── remembered networks ──────────────────────────────────────
            const saved = filter(detail.saved ?? [], (n) => !n.active);
            if (length(saved)) {
                push(out, { t: 'section', title: 'Saved networks' });
                // A const per pass: a closure over a for-in variable sees only
                // its last value in ucode (see the radio block in ui.uc).
                for (let each in saved) {
                    const n = each;
                    let label = n.ssid + (n.security == 'eap' ? ' 802.1X' : (n.security == 'open' ? ' open' : ''));
                    push(out, { t: 'buttons', label, labelTone: 'bold', items: [
                        { label: 'Join', key: 'join:' + n.ssid, run: () => rejoin(n.ssid) },
                        { label: 'Forget', key: 'forget:' + n.ssid, run: () => forget(n.ssid) },
                    ] });
                }
                if (st.rejoin) push(out, { t: 'notice', tone: st.rejoin.tone, text: st.rejoin.text });
            }

            // ── joining another ──────────────────────────────────────────
            if (st.scan && st.scan.capable === false) {
                push(out, { t: 'notice', tone: 'info', text: 'This board has no WiFi radio.' });
                return out;
            }
            push(out, wifi.configured ? { t: 'section', title: 'Join a different network' } : { t: 'blank' });
            push(out, { t: 'buttons', items: [ { label: 'Scan', run: () => {
                ctx.flash('Scanning', 'neutral');
                st.scan = api.access.scan();
                ctx.flash(null);
            } } ] });
            if (st.scan?.error) push(out, { t: 'notice', tone: 'info', text: st.scan.error });

            const nets = sort(slice(st.scan?.networks ?? []), (a, b) => (b.quality ?? 0) - (a.quality ?? 0));
            for (let each in nets) {
                const n = each;
                const kind = n.encryption == 'eap' ? '802.1X' : (n.encryption == 'open' ? 'open' : '');
                const right = sprintf('%6s  %s', kind, n.signal != null ? sprintf('%d dBm', n.signal) : '');
                const room = width - ctx.term.cols(right) - 2;
                let text = ctx.term.pad((n.ssid == st.form.ssid ? '> ' : '  ') + ctx.term.clip(n.ssid, room - 2), room) + right;
                push(out, { t: 'link', key: 'net:' + n.ssid, label: text, run: () => {
                    st.form.ssid = n.ssid;
                    st.form.allowOpen = false;
                    resetProbe();
                } });
            }

            const f = st.form, sec = security();
            push(out, { t: 'blank' });
            push(out, { t: 'field', label: 'Network name', value: f.ssid,
                        set: (v) => { if (v != f.ssid) resetProbe(); f.ssid = v; } });
            if (!selected())
                push(out, { t: 'choice', label: 'Security', value: f.security, options: [
                    { value: 'psk', label: 'Password' },
                    { value: 'eap', label: 'Username and password' },
                    { value: 'open', label: 'None' },
                ], set: (v) => { f.security = v; resetProbe(); } });

            if (sec == 'psk')
                push(out, { t: 'field', label: 'Passphrase', value: f.key, secret: true, set: (v) => { f.key = v; } });

            if (sec == 'open') {
                push(out, { t: 'notice', tone: 'warning', text: sprintf('%s is an open network.', trim(f.ssid)) });
                push(out, { t: 'check', label: 'Use this open network anyway', checked: f.allowOpen,
                            set: (v) => { f.allowOpen = v; } });
            }

            if (sec == 'eap') {
                push(out, { t: 'choice', label: 'Method', value: f.method, options: [
                    { value: 'peap', label: 'PEAP (MSCHAPv2)' },
                    { value: 'ttls-pap', label: 'TTLS (PAP)' },
                    { value: 'ttls-mschapv2', label: 'TTLS (MSCHAPv2)' },
                ], set: (v) => { f.method = v; resetProbe(); } });
                push(out, { t: 'field', label: 'Username', value: f.identity,
                            set: (v) => { if (v != f.identity) resetProbe(); f.identity = v; } });
                push(out, { t: 'field', label: 'Password', value: f.password, secret: true, set: (v) => { f.password = v; } });
                push(out, { t: 'field', label: 'Anonymous identity', value: f.anonymous, placeholder: 'anonymous@example.edu',
                            set: (v) => { if (v != f.anonymous) resetProbe(); f.anonymous = v; } });

                const l = leaf(), r = result();
                if (l) {
                    push(out, { t: 'fact', label: 'Server', value: commonName(l.subject) });
                    const iss = issuer();
                    if (iss) push(out, { t: 'fact', label: 'Issued by', value: commonName(iss.subject) });
                    push(out, { t: 'fact', label: 'SHA-256', value: fingerprint(l.hash) });
                }
                if (r && r.state == 'failed') push(out, { t: 'notice', tone: 'error', text: r.error });
                if (st.probeError) push(out, { t: 'notice', tone: 'error', text: st.probeError });
                if (!l) {
                    const checking = st.probing && (!r || r.state == 'probing');
                    push(out, { t: 'buttons', items: [ {
                        label: checking ? 'Checking certificate' : 'Check certificate', key: 'check-cert', primary: true,
                        disabled: checking || !length(trim(f.ssid)) || !length(trim(f.identity)) || !length(f.password),
                        run: checkCertificate,
                    } ] });
                    if (st.join) push(out, { t: 'notice', tone: st.join.tone, text: st.join.text });
                    return out;
                }
            }

            const disabled = !length(trim(f.ssid))
                || (sec == 'open' && !f.allowOpen)
                || (sec == 'psk' && !length(f.key))
                || (sec == 'eap' && (!length(f.password) || !length(trim(f.identity))));
            if (st.join) push(out, { t: 'notice', tone: st.join.tone, text: st.join.text });
            push(out, { t: 'buttons', items: [ { label: sec == 'eap' ? 'Trust and join' : 'Join', key: 'join-new',
                                                 primary: true, disabled, run: join_ } ] });
            return out;
        },
    };
};
