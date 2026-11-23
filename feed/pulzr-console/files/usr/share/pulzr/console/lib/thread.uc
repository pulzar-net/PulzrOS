// Thread: the border router the pulzr-thread add-on runs, through
// /usr/sbin/pulzr-thread.
//
// Set up from Pulzr Net only, as add-ons are: a write needs an `sso` session,
// which only Pulzr Net mints for a person, and is audited with who. Pulzr
// Net holds the network's dataset sealed and is where the checks that are not
// the gateway's to make happen (an org admin acting as themselves, one network
// per organization's site). A local session reads the status and nothing else.
//
// The dataset and a joiner's PSKd reach pulzr-thread on stdin, from a file
// only root can read that is gone before the answer is sent; they are never
// on a command line, in a log or in an audit record. Only `dataset` answers
// with a secret, the dataset itself, for Pulzr Net to seal.

let _m_fs = require('fs');

// ucode does not hoist function declarations; see util.uc.
let thread, status, change, quote;

const TOOL = '/usr/sbin/pulzr-thread';
const RUN = '/var/run/pulzr-console';
// What each POST runs, and whether it takes a request on stdin.
const OPS = {
    use: false, release: false, scan: false, leave: false, 'permit-stop': false,
    form: true, join: true, permit: true, dataset: false,
};

quote = function(a) {
    return "'" + replace(a, /'/g, "'\\''") + "'";
};

// The tool's JSON answer, or its last line on stderr as the error.
thread = function(args, stdin) {
    if (!_m_fs.access(TOOL, 'x')) return { error: 'Thread is not installed on this gateway.', status: 409 };
    let input = null;
    if (stdin != null) {
        _m_fs.mkdir(RUN, 0o700);
        input = sprintf('%s/thread.%d', RUN, time());
        const f = _m_fs.open(input, 'w', 0o600);
        if (!f) return { error: 'Cannot hand the request to pulzr-thread.', status: 500 };
        f.write(sprintf('%J', stdin));
        f.close();
    }
    const cmd = TOOL + ' ' + join(' ', map(args, quote)) + (input ? ' < ' + quote(input) : ' < /dev/null') + ' 2>&1';
    const proc = _m_fs.popen(cmd, 'r');
    const out = trim(proc?.read('all') ?? '');
    const rc = proc ? proc.close() : 127;
    if (input) _m_fs.unlink(input);
    if (rc != 0) {
        const lines = split(out, '\n');
        return { error: lines[length(lines) - 1] || 'pulzr-thread failed.', status: rc == 2 ? 400 : 409 };
    }
    if (args[0] == 'dataset') return { dataset: out };
    try { return json(out); } catch (e) { return { error: out, status: 500 }; }
};

status = function() {
    return thread(['status']);
};

// POST /api/system/thread/<op>. { result } or { error, status }.
change = function(op, req, session) {
    if (session?.kind != 'sso')
        return { status: 403, error: 'Thread is set up from Pulzr Net.' };
    if (!(op in OPS))
        return { status: 404, error: 'No such Thread operation.' };
    let args = [op];
    if (op == 'use') {
        if (type(req?.radio) != 'string' || !match(req.radio, /^(usb|uart|lan)-[a-z0-9._-]{1,96}$/))
            return { status: 400, error: 'radio is a detected radio id.' };
        push(args, req.radio);
    }
    let stdin = null;
    if (OPS[op]) {
        stdin = op == 'permit'
            ? { eui64: req?.eui64 ?? '*', pskd: req?.pskd, seconds: req?.seconds }
            : { dataset: req?.dataset, network: req?.network };
    }
    const result = thread(args, stdin);
    if (result.error) return { status: result.status ?? 409, error: result.error };
    return { status: 200, result };
};

// ── module exports ──────────────────────────────────────────────────────────
//
// A returned object, not `export` statements; see the header of
// api/index.uc.
return { change, status };
