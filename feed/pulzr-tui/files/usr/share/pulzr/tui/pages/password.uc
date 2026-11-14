// The forced password change — console/src/components/PasswordPrompt.tsx.
return function(ctx) {
    const st = { password: '', confirm: '', error: null };

    const submit = () => {
        const r = ctx.act('setPassword', { password: st.password });
        if (r.error) { st.error = r.error; return; }
        ctx.passwordChanged();
    };

    return {
        view: function(width) {
            const mismatch = length(st.confirm) && st.confirm != st.password;
            const tooShort = length(st.password) && length(st.password) < 12;
            const out = [
                { t: 'section', title: 'Choose a password' },
                { t: 'field', label: 'New password', value: st.password, secret: true, set: (v) => { st.password = v; } },
                { t: 'field', label: 'Confirm', value: st.confirm, secret: true, set: (v) => { st.confirm = v; } },
            ];
            if (mismatch) push(out, { t: 'notice', tone: 'error', text: 'The two passwords do not match.' });
            if (st.error) push(out, { t: 'notice', tone: 'error', text: st.error });
            push(out, { t: 'buttons', items: [
                { label: 'Set password', primary: true, disabled: !length(st.password) || mismatch || tooShort, run: submit },
                { label: 'Sign out', run: () => ctx.signOut() },
            ] });
            return out;
        },
    };
};
