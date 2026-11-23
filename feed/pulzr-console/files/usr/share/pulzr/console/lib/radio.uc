// Radio networks: the Zigbee and Z-Wave coordinators, one process per radio
// running its protocol's module binary (pulzr-edge-zigbee, pulzr-edge-zwave,
// each in its add-on), and the gateway's controller in its organization's
// Matter fabric, as the radio `matter` (docs/src/content/docs/radio-modules.md). Every op goes
// through `pulzr-radios call`, which picks the radio's binary.
//
// Set up from Pulzr Net only, as add-ons and Thread are: a change needs an
// `sso` session, which only Pulzr Net mints for a person, and is audited
// with who. Pulzr Net holds the networks' keys and backups sealed and makes
// the checks that are not the gateway's (an org admin acting as themselves,
// one network per radio). A local session reads status and nothing else.
//
// The request reaches the radio's module on stdin, from a file only root can
// read that is gone before the answer is sent: `form` carries a network key,
// `restore` a backup, `provision` install codes, `dsk` an S2 PIN. Never a
// command line, a log or an audit record. Only `backup` answers with a
// secret, for Pulzr Net to seal.
//
// The radio is in the body (`radio`), not the path: the router matches whole
// paths, and the radio id is checked here instead.

let _m_fs = require('fs');

// ucode does not hoist function declarations; see util.uc.
let run, list, status, change, quote, valid;

const RADIOS_TOOL = '/usr/sbin/pulzr-radios';
const RADIOS = '/etc/pulzr-edge/radios';
const RUN = '/var/run/pulzr-console';
// What a module takes. `use` and `release` are pulzr-radios', the rest the
// module's own (pulzr-radios call <id> <op>).
const OPS = [
    'use', 'release', 'scan', 'form', 'restore', 'backup', 'leave', 'permit',
    'permit-stop', 'provision', 'grant', 'dsk', 'abort', 'remove', 'replace',
    'channel', 'region', 'map',
    // Matter's: join the organization's fabric, add and share devices.
    'csr', 'join', 'commission', 'share', 'decommission',
];

quote = function(a) {
    return "'" + replace(a, /'/g, "'\\''") + "'";
};

valid = function(radio) {
    return radio == 'matter' || (type(radio) == 'string' && !!match(radio, /^(usb|uart|lan)-[a-z0-9._-]{1,96}$/));
};

// A tool's JSON answer; on failure its last stderr line, with the status the
// exit code means (docs/src/content/docs/radio-modules.md: 2 bad request, 3 no module).
run = function(cmd, stdin, name) {
    let input = null;
    if (stdin != null) {
        _m_fs.mkdir(RUN, 0o700);
        // One change per radio at a time (the module refuses a second), so
        // the radio and the op make the name unique.
        input = sprintf('%s/radio.%s.%d', RUN, name, time());
        const f = _m_fs.open(input, 'w', 0o600);
        if (!f) return { error: 'Cannot hand the request to the radio module.', status: 500 };
        f.write(sprintf('%J', stdin));
        f.close();
    }
    const proc = _m_fs.popen(cmd + (input ? ' < ' + quote(input) : ' < /dev/null') + ' 2>&1', 'r');
    const out = trim(proc?.read('all') ?? '');
    const rc = proc ? proc.close() : 127;
    if (input) _m_fs.unlink(input);
    if (rc != 0) {
        const lines = split(out, '\n');
        const why = lines[length(lines) - 1];
        if (rc == 3) return { error: why || 'No radio module runs on that radio.', status: 409 };
        return { error: why || 'The radio module failed.', status: rc == 2 ? 400 : 409 };
    }
    try { return json(out); } catch (e) { return { error: 'The radio module answered something that is not JSON.', status: 500 }; }
};

// The radios a module was started on: one file each.
list = function() {
    const out = [];
    for (let f in (_m_fs.lsdir(RADIOS) ?? [])) {
        const m = match(f, /^((usb|uart|lan)-[a-z0-9._-]{1,96}|matter)\.json$/);
        if (m) push(out, m[1]);
    }
    return sort(out);
};

// GET /api/system/radio: every module's status, or why it has none.
status = function() {
    const radios = [];
    for (let id in list()) {
        const s = run(RADIOS_TOOL + ' call ' + quote(id) + ' status', null);
        push(radios, s.error ? { radio: id, state: 'down', error: s.error } : s);
    }
    return { radios };
};

// POST /api/system/radio/<op>, `radio` in the body. { result } or { error, status }.
change = function(op, req, session) {
    if (session?.kind != 'sso')
        return { status: 403, error: 'Radio networks are set up from Pulzr Net.' };
    if (!(op in OPS))
        return { status: 404, error: 'No such radio operation.' };
    if (!valid(req?.radio))
        return { status: 400, error: 'radio is a detected radio id.' };
    let result;
    if (op == 'use') {
        if (!(req?.protocol in ['zigbee', 'zwave', 'matter']) || ((req.radio == 'matter') != (req.protocol == 'matter')))
            return { status: 400, error: 'protocol is zigbee or zwave on a radio, matter on the radio matter.' };
        result = run(RADIOS_TOOL + ' use ' + quote(req.radio) + ' ' + quote(req.protocol), null);
    } else if (op == 'release') {
        result = run(RADIOS_TOOL + ' release ' + quote(req.radio), null);
    } else {
        const params = {};
        for (let k, v in req) if (k != 'radio') params[k] = v;
        result = run(RADIOS_TOOL + ' call ' + quote(req.radio) + ' ' + quote(op), params, req.radio + '.' + op);
    }
    if (result.error) return { status: result.status ?? 409, error: result.error };
    return { status: 200, result };
};

// ── module exports ──────────────────────────────────────────────────────────
//
// A returned object, not `export` statements; see the header of
// api/index.uc.
return { change, status, list };
