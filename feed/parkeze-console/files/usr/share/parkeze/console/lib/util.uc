// Small shared helpers. Nothing here knows what a gateway is.

import { popen, readfile } from 'fs';

// Run a command and return its stdout, trimmed. Returns null on failure, so a
// caller can tell "the command said nothing" from "the command is not there".
export function run(cmd) {
    const proc = popen(cmd, 'r');
    if (!proc) return null;
    const out = proc.read('all');
    const rc = proc.close();
    if (rc != 0) return null;
    return trim(out ? out : '');
}

// Run a command and parse its stdout as JSON.
export function runJson(cmd) {
    const out = run(cmd);
    if (!out) return null;
    try { return json(out); } catch (e) { return null; }
}

// First capture group of a regex against a file's contents, or null.
export function grepFile(path, pattern) {
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
export function ubus(object, method, args) {
    const payload = args ? sprintf(" '%J'", args) : '';
    return runJson(sprintf('ubus call %s %s%s', object, method, payload));
}
