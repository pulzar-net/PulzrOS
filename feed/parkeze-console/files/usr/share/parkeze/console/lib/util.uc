// Small shared helpers. Nothing here knows what a gateway is.

let _m_fs = require('fs');

// ── forward declarations ────────────────────────────────────────────────────
//
// ucode does not hoist function declarations. A `function f()` defined below
// a function that calls it is simply not in scope there, and the call fails at
// RUNTIME with "left-hand side is not a function" — never at compile time, so
// nothing catches it until the request that needs it.
//
// Declaring the names first makes every one of them a known local before any
// body is compiled, so closures capture the binding rather than a missing
// global and definition order stops mattering. auth.uc alone had six of these.
let run, runJson, grepFile, ubus, tool;

let popen = _m_fs.popen;; let readfile = _m_fs.readfile;

// Run a command and return its stdout, trimmed. Returns null on failure, so a
// caller can tell "the command said nothing" from "the command is not there".
run = function(cmd) {
    const proc = popen(cmd, 'r');
    if (!proc) return null;
    const out = proc.read('all');
    const rc = proc.close();
    if (rc != 0) return null;
    return trim(out ? out : '');
};

// Run a command and parse its stdout as JSON.
runJson = function(cmd) {
    const out = run(cmd);
    if (!out) return null;
    try { return json(out); } catch (e) { return null; }
};

// First capture group of a regex against a file's contents, or null.
grepFile = function(path, pattern) {
    const content = readfile(path);
    if (!content) return null;
    const m = match(content, pattern);
    return m ? m[1] : null;
};

// ubus call, via the CLI rather than the ucode ubus binding.
//
// The binding would be faster, but the console is not on a hot path and this
// keeps the module importable in the syntax checker and in a shell on the
// device. If a view ever needs ubus in a loop, that view should switch.
ubus = function(object, method, args) {
    const payload = args ? sprintf(" '%J'", args) : '';
    return runJson(sprintf('ubus call %s %s%s', object, method, payload));
};

// One of the gateway's own tools (parkeze-lan, parkeze-dns, parkeze-uplinks)
// with arguments from a request. Each argument must be plain (letters,
// digits, dot, colon, hyphen, underscore) before it is quoted, so none can
// carry a quote; what each one means is the tool's to check. A refusal is the
// tool's one line on stderr, which is what the caller shows.
tool = function(path, args) {
    for (let a in args)
        if (type(a) != 'string' || !match(a, /^[A-Za-z0-9.:_-]{1,253}$/))
            return { error: 'Letters, digits, dots, colons and hyphens only.' };
    const quoted = join(' ', map(args, (a) => "'" + a + "'"));
    const proc = popen(path + ' ' + quoted + ' 2>&1', 'r');
    if (!proc) return { error: sprintf('%s is not on this gateway.', path) };
    const out = trim(proc.read('all') ?? '');
    const rc = proc.close();
    if (rc != 0) return { error: out ? uc(substr(out, 0, 1)) + substr(out, 1) + '.' : sprintf('%s failed.', path) };
    try { return json(out); } catch (e) { return { error: out }; }
};

// ── module exports ──────────────────────────────────────────────────────────
//
// A returned object, not `export` statements. uhttpd's ucode plugin compiles
// its handler in TEMPLATE mode and loads anything else through loadfile(),
// neither of which is module mode — `export` is a syntax error there. See the
// header of api/index.uc for the full contract.
return { grepFile, run, runJson, tool, ubus };
