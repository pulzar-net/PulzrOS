// Add-ons: what this gateway has, and installing or removing one, through
// pulzr-addon.
//
// Installs come from Pulzar Net, never from this console's own sign-in. An
// add-on is root code on the gateway, and the platform is where the checks
// that are not the gateway's to make happen: that the person is an org admin
// or Pulzar staff acting as themselves (not an API key, not an agent), that a
// metered link was consented to, that no firmware job is open. So a write
// needs an `sso` session, which only Pulzar Net mints, and names the person in
// the gateway's audit log and add-on journal. A local password or recovery
// session reads the list and is told where installs come from.
//
// A deny (a capability locked off, Modbus on a production gateway) can be added
// here and never taken away: Pulzar Net writes its lock back after a factory
// reset wiped the gateway's copy, and nothing that reaches this API should be
// able to undo that. Unlocking is `pulzr-addon undeny` from a root shell.

let _m_fs = require('fs');

// ucode does not hoist function declarations; see util.uc.
let addon, status, request, deny, quote;

const TOOL = '/usr/sbin/pulzr-addon';
const NAME = /^[a-z0-9-]{1,40}$/;

quote = function(a) {
    return "'" + replace(a, /'/g, "'\\''") + "'";
};

// The tool's JSON answer, or its one line on stderr as the error.
addon = function(args) {
    const proc = _m_fs.popen(TOOL + ' ' + join(' ', map(args, quote)) + ' 2>&1', 'r');
    if (!proc) return { error: 'pulzr-addon is not on this gateway.' };
    const out = trim(proc.read('all') ?? '');
    const rc = proc.close();
    if (rc != 0) return { error: out || 'pulzr-addon failed.' };
    try { return json(out); } catch (e) { return { error: out }; }
};

// The session subject as pulzr-addon records it: an address at most.
const who = (session) => replace(session?.subject ?? '', /[^A-Za-z0-9._@+-]/g, '') || 'console';

status = function() {
    return addon(['status']);
};

// { name, action: 'install'|'remove', purge? }. Answers once the job is
// running; how it ends is in status and in the next report.
request = function(req, session) {
    if (session?.kind != 'sso')
        return { status: 403, error: 'Add-ons are installed from Pulzar Net.' };
    const name = req?.name, action = req?.action;
    if (type(name) != 'string' || !match(name, NAME))
        return { status: 400, error: 'That is not an add-on name.' };
    if (action != 'install' && action != 'remove')
        return { status: 400, error: 'The action is install or remove.' };
    const purge = action == 'remove' && req?.purge === true;
    const result = addon(['start', action, name, who(session), ...(purge ? ['--purge'] : [])]);
    if (result.error) return { status: 409, error: result.error };
    return { status: 202, ok: true, name, action, purge };
};

// { deny: ['modbus'], reason }. Adds; what is already denied stays denied.
deny = function(req, session) {
    if (session?.kind != 'sso')
        return { status: 403, error: 'Add-ons are locked from Pulzar Net.' };
    const caps = req?.deny;
    if (type(caps) != 'array' || !length(caps) || length(caps) > 16)
        return { status: 400, error: 'deny is a list of capability words.' };
    for (let c in caps)
        if (type(c) != 'string' || !match(c, NAME))
            return { status: 400, error: 'deny is a list of capability words.' };
    const reason = type(req?.reason) == 'string' ? substr(req.reason, 0, 200) : '';
    const result = addon(['deny', who(session), reason, ...caps]);
    if (result.error) return { status: 400, error: result.error };
    return { status: 200, ...result };
};

// ── module exports ──────────────────────────────────────────────────────────
//
// A returned object, not `export` statements; see the header of
// api/index.uc.
return { deny, request, status };
