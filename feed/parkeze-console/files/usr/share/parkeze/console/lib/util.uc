// Small shared helpers. Nothing here knows what a gateway is.

let _m_fs = require('fs');
let popen = _m_fs.popen;; let readfile = _m_fs.readfile;

// Run a command and return its stdout, trimmed. Returns null on failure, so a
// caller can tell "the command said nothing" from "the command is not there".
function run(cmd) {
    const proc = popen(cmd, 'r');
    if (!proc) return null;
    const out = proc.read('all');
    const rc = proc.close();
    if (rc != 0) return null;
    return trim(out ? out : '');
}

// Run a command and parse its stdout as JSON.
function runJson(cmd) {
    const out = run(cmd);
    if (!out) return null;
    try { return json(out); } catch (e) { return null; }
}

// First capture group of a regex against a file's contents, or null.
function grepFile(path, pattern) {
    const content = readfile(path);
    if (!content) return null;
    const m = match(content, pattern);
    return m ? m[1] : null;
}

// ubus call, via the CLI rather than the ucode ubus binding.
//
// The binding would be faster, but the console is not on a hot path and this
// keeps the module importable in the syntax checker and in a shell on the
// device. If a view ever needs ubus in a loop, that view should switch.
function ubus(object, method, args) {
    const payload = args ? sprintf(" '%J'", args) : '';
    return runJson(sprintf('ubus call %s %s%s', object, method, payload));
}

// ── module exports ──────────────────────────────────────────────────────────
//
// A returned object, not `export` statements. uhttpd's ucode plugin compiles
// its handler in TEMPLATE mode and loads anything else through loadfile(),
// neither of which is module mode — `export` is a syntax error there. See the
// header of api/index.uc for the full contract.
return { grepFile, run, runJson, ubus };
