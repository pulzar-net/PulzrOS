// Sign-in — console/src/pages/Login.tsx, with its Recovery screen.
//
// "Sign in with Parkeze" is the web console's in shape but not in route. The
// browser handoff lands a token on a browser origin, and a terminal has none,
// so here the gateway shows a code and a QR of parkeze.net's approval page,
// somebody approves it from a phone, and the gateway collects the token for
// itself (auth.uc's terminalStart and terminalCollect). Online only, as the
// browser handoff is; recovery is the offline way in.
return function(ctx) {
    const ui = ctx.ui, api = ctx.api, fmt = ctx.fmt;
    const st = { methods: null, adopted: true, claim: null, mode: null, username: 'parkeze', password: '',
                 error: null, recovery: null, signature: '', verifyError: null, check: null, checking: false,
                 parkeze: null, parkezeError: null };

    // As the web console chooses: the password while local sign-in is on,
    // then Parkeze, then recovery.
    const mode = () => {
        if (st.mode) return st.mode;
        const m = st.methods ?? {};
        return m.local ? 'password' : (m.sso ? 'parkeze' : 'recovery');
    };

    const startParkeze = () => {
        st.mode = 'parkeze';
        st.parkezeError = null;
        ctx.flash('Asking Parkeze', 'neutral');
        const r = api.auth.terminalStart();
        ctx.flash(null);
        if (r.error) { st.parkezeError = r.error; st.parkeze = null; return; }
        st.parkeze = { code: r.code, url: r.url, until: time() + r.expiresIn,
                       interval: r.interval, qr: ctx.qr(r.url) };
    };

    const collect = () => {
        const p = st.parkeze;
        if (!p) return;
        if (time() >= p.until) { st.parkeze = null; st.parkezeError = 'That code has expired.'; return; }
        const r = api.auth.terminalCollect(p.code, ctx.addr());
        if (r.pending) return;
        st.parkeze = null;
        if (r.error) { st.parkezeError = r.error; return; }
        ctx.signIn(r.session);
    };

    const parkezeView = (out) => {
        const m = st.methods ?? {};
        if (!st.parkeze) push(out, { t: 'section', title: 'Sign in with Parkeze' });
        const p = st.parkeze;
        if (p) {
            // All of it on one screen, because half a QR does not scan: on a
            // 24-row serial console the code is about eighteen rows of it. The
            // link goes first when there is no room — the QR carries it, and
            // the code alone works at the approval page.
            const rows = ctx.term.state.rows - 3;
            const qr = (p.qr && ctx.term.cols(p.qr[0]) <= ctx.width()) ? p.qr : null;
            const qrRows = qr ? length(qr) : 0;
            if (qr) push(out, { t: 'pre', lines: qr });
            push(out, { t: 'fact', label: 'Code', value: { text: sprintf('%s  %s', p.code,
                        fmt.countdown(p.until - time())), tone: 'bold' } });
            if (qrRows + 5 <= rows || !qr) push(out, { t: 'fact', label: 'Open', value: p.url });
            push(out, { t: 'buttons', items: [ { label: 'Cancel', key: 'parkeze-cancel', run: () => { st.parkeze = null; } } ] });
            return;
        }
        if (st.parkezeError) push(out, { t: 'notice', tone: 'error', text: st.parkezeError });
        const buttons = [ { label: 'Sign in with Parkeze', key: 'parkeze-start', primary: true, run: startParkeze } ];
        if (m.recovery) push(buttons, { label: 'Recovery access', run: startRecovery });
        if (m.local) push(buttons, { label: 'Sign in with a password', run: () => { st.mode = 'password'; ctx.focus('password'); } });
        push(out, { t: 'buttons', items: buttons });
    };

    const signIn = () => {
        const r = api.auth.loginLocal(st.username, st.password, ctx.addr());
        st.password = '';
        if (r.error) { st.error = r.error; return; }
        st.error = null;
        ctx.signIn(r.session);
    };

    const startRecovery = () => {
        st.mode = 'recovery';
        if (!st.recovery) st.recovery = api.auth.recoveryChallenge();
        ctx.focus('signature');
    };

    const unlock = () => {
        const r = api.auth.recoveryVerify(trim(st.signature), ctx.addr());
        if (r.error) { st.verifyError = r.error; return; }
        st.verifyError = null;
        st.signature = '';
        ctx.signIn(r.session);
    };

    // Declared first: it schedules itself, and a const cannot name itself.
    let pollCheck;
    pollCheck = () => {
        const r = api.claim.adoptionCheckResult();
        st.check = r;
        if (r.checking !== false) { ctx.later(3, pollCheck); return; }
        st.checking = false;
        // Released by Parkeze: back to an unadopted gateway, which shows the
        // claim screen.
        if (r.adopted === false && r.released === true) { st.mode = null; st.recovery = null; ctx.refresh(); }
    };

    const recoveryView = (out) => {
        const m = st.methods ?? {};
        push(out, { t: 'section', title: 'Recovery access' });
        const r = st.recovery;
        if (!r) return;
        if (r.error) { push(out, { t: 'notice', tone: 'error', text: r.error }); }
        else {
            const minutes = int((r.challenge.expiresIn + 30) / 60);
            push(out, { t: 'text', text: '1. Give this code to Parkeze' });
            push(out, { t: 'text', tone: 'bold', text: r.challenge.code });
            push(out, { t: 'text', tone: 'dim', text: sprintf('Expires in %d minutes.', minutes > 0 ? minutes : 0) });
            push(out, { t: 'blank' });
            push(out, { t: 'text', text: '2. Paste the signature it gives you back' });
            push(out, { t: 'field', label: 'Signature', key: 'signature', value: st.signature, placeholder: 'Base64 signature from Parkeze',
                        max: 512, set: (v) => { st.signature = v; }, submit: () => { if (length(trim(st.signature))) unlock(); } });
            if (st.verifyError) push(out, { t: 'notice', tone: 'error', text: st.verifyError });
            const buttons = [ { label: 'Unlock', primary: true, disabled: !length(trim(st.signature)), run: unlock } ];
            if (m.local) push(buttons, { label: 'Back to sign in', run: () => { st.mode = 'password'; ctx.focus('password'); } });
            else if (m.sso) push(buttons, { label: 'Sign in with Parkeze', run: () => { st.mode = 'parkeze'; ctx.focus('parkeze-start'); } });
            push(out, { t: 'buttons', items: buttons });
        }

        push(out, { t: 'blank' });
        push(out, { t: 'buttons', items: [ { label: st.checking ? 'Checking with Parkeze' : 'Check with Parkeze',
            disabled: st.checking, run: () => {
                ctx.act('checkAdoption');
                st.checking = true;
                st.check = null;
                ctx.later(3, pollCheck);
            } } ] });
        const c = st.check;
        if (c && c.checked === false && c.reason)
            push(out, { t: 'text', tone: 'dim', text: c.reason == 'unreachable'
                ? 'Could not reach Parkeze. Nothing changed.' : sprintf('No answer: %s. Nothing changed.', c.reason) });
        else if (c && c.checked && c.adopted)
            push(out, { t: 'text', tone: 'dim', text: 'Still adopted.' });
    };

    return {
        interval: () => {
            if (!st.adopted && !ctx.browsing()) return st.claim ? st.claim.interval() : 3;
            // While a code is on screen: as often as parkeze.net asked.
            return st.parkeze ? st.parkeze.interval : null;
        },
        enter: function() { st.mode = null; st.error = null; st.focused = false; },
        load: function() {
            st.adopted = api.claim.isAdopted();
            if (!st.adopted && !ctx.browsing()) {
                if (!st.claim) st.claim = ctx.page('claim');
                st.claim.load();
                return;
            }
            if (st.parkeze) return collect();
            st.methods = api.auth.loginMethods();
            if (mode() == 'recovery' && !st.recovery) startRecovery();
            else if (mode() == 'password' && !st.focused) { st.focused = true; ctx.focus('password'); }
            else if (mode() == 'parkeze' && !st.focused) { st.focused = true; ctx.focus('parkeze-start'); }
        },
        back: function() {
            if (st.parkeze) { st.parkeze = null; return true; }
            if ((st.mode == 'recovery' || st.mode == 'parkeze') && st.methods?.local) {
                st.mode = 'password'; ctx.focus('password'); return true;
            }
            if (st.mode == 'recovery' && st.methods?.sso) { st.mode = 'parkeze'; ctx.focus('parkeze-start'); return true; }
            return false;
        },
        view: function(width) {
            if (!st.adopted && !ctx.browsing()) return st.claim.view(width);
            // The mark, except while a QR needs the rows.
            const out = st.parkeze ? [] : [ { t: 'pre', lines: ctx.banner(width) }, { t: 'blank' } ];
            if (mode() == 'recovery') { recoveryView(out); return out; }
            if (mode() == 'parkeze') { parkezeView(out); return out; }

            const m = st.methods ?? {};
            push(out, { t: 'section', title: 'Sign in' });
            if (m.note) push(out, { t: 'notice', tone: m.state == 'adopted' && m.local ? 'warning' : 'info', text: m.note });
            push(out, { t: 'field', label: 'Username', value: st.username, set: (v) => { st.username = v; } });
            push(out, { t: 'field', label: 'Password', key: 'password', value: st.password, secret: true,
                        set: (v) => { st.password = v; }, submit: signIn });
            if (st.error) push(out, { t: 'notice', tone: 'error', text: st.error });
            const buttons = [ { label: 'Sign in', primary: true, run: signIn } ];
            if (m.sso) push(buttons, { label: 'Sign in with Parkeze', run: () => { st.mode = 'parkeze'; ctx.focus('parkeze-start'); } });
            if (m.recovery) push(buttons, { label: 'Recovery access', run: startRecovery });
            push(out, { t: 'buttons', items: buttons });
            return out;
        },
    };
};
