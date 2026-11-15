// A change that is undone unless it is confirmed, through pulzr-apply.
//
// The network setters in the console API (cellular, Wi-Fi, the uplink order,
// the DNS upstream) can each cut off whoever makes them, so the API arms the
// gateway's rollback window before the change and the caller confirms by
// reaching the gateway again afterwards. A port layout arms it itself
// (pulzr-ports set); the same confirm and revert serve both.
//
// Armed here, in the API, and not in actions.uc: the terminal UI calls those
// actions too, and nobody at a serial console confirms a window that was
// armed for a browser. Whoever is typing there can see whether the change
// worked.

let _m_fs = require('fs');

// ucode does not hoist function declarations; see util.uc.
let apply, status, arm, settle, discard, confirm, revert, guard;

const TOOL = '/usr/sbin/pulzr-apply';

// The tool's JSON answer, or its one line on stderr as the error.
apply = function(args) {
    const quoted = join(' ', map(args, (a) => "'" + replace(a, "'", "'\\''") + "'"));
    const proc = _m_fs.popen(TOOL + ' ' + quoted + ' 2>&1', 'r');
    if (!proc) return { error: 'pulzr-apply is not on this gateway.' };
    const out = trim(proc.read('all') ?? '');
    const rc = proc.close();
    if (rc != 0) return { error: out || 'The change could not be armed.' };
    try { return json(out); } catch (e) { return { error: out }; }
};

status = function() {
    return apply(['status']);
};

arm = function(window, by) {
    return apply(['arm', '-w', sprintf('%d', window), ...(by ? [by] : [])]);
};

settle = function() {
    return apply(['settle']);
};

discard = function() {
    return apply(['discard']);
};

confirm = function() {
    return apply(['confirm']);
};

revert = function() {
    return apply(['revert']);
};

// `change`'s answer with the window running, or why it was refused. Armed
// first so the snapshot is what the gateway was running; a change that is
// refused changed nothing, so its window is dropped. The window counts from
// the end of the change: the confirm has to wait for the network to settle.
guard = function(window, session, change) {
    const armed = arm(window, session?.subject);
    if (armed.error) return armed;
    const result = change();
    if (result?.error) {
        discard();
        return result;
    }
    const settled = settle();
    return { ...result, pending: settled.pending ?? armed.pending };
};

// ── module exports ──────────────────────────────────────────────────────────
//
// A returned object, not `export` statements; see the header of
// api/index.uc.
return { arm, confirm, discard, guard, revert, settle, status };
