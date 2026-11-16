// The diagnostic prompt's commands (pulzr-tui's diag.uc), as fixed programs.
//
// The words typed are matched against the table below and passed on as
// separate arguments, never as a command line, so nothing typed becomes a
// command of its own. Here rather than in the TUI because the broker runs
// them too, for a terminal without the rights to (pulzr-console-broker): one
// table, so the two cannot disagree about what a command may run.

let _m_fs = require('fs');

const LOGS = '/usr/sbin/pulzr-logs';

// A host for ping: a name or an address, nothing a program could take for an
// option.
const HOST = /^[A-Za-z0-9][A-Za-z0-9.:-]{0,252}$/;

let topics, argvs, output;

topics = function() {
    const p = _m_fs.popen(LOGS + ' --topics 2>/dev/null', 'r');
    if (!p) return [];
    const out = p.read('all') ?? '';
    p.close();
    return filter(split(trim(out), '\n'), (t) => length(t));
};

// The programs a command runs, each an argument list, or { error }.
argvs = function(name, args) {
    args = type(args) == 'array' ? args : [];
    if (name == 'logs') {
        if (!(args[0] in topics())) return { error: 'logs: name a topic: ' + join(' ', topics()) };
        if (args[1] != null && !match(args[1], /^[0-9]{1,4}$/)) return { error: 'logs: lines is a number' };
        return [ [ LOGS, args[0], args[1] ?? '200' ] ];
    }
    if (name == 'follow') {
        if (!(args[0] in topics())) return { error: 'follow: name a topic: ' + join(' ', topics()) };
        return [ [ LOGS, args[0], '--follow' ] ];
    }
    if (name == 'status') return [ [ '/sbin/ip', '-br', 'addr' ], [ '/sbin/ip', 'route' ] ];
    if (name == 'wifi') return [ [ '/usr/bin/iwinfo' ] ];
    if (name == 'ping') {
        if (!match(args[0] ?? '', HOST)) return { error: 'ping: give a host name or an address' };
        return [ [ '/bin/ping', '-c', '4', '-W', '2', args[0] ] ];
    }
    return { error: sprintf('%s: not a command here. `help` lists them.', name) };
};

// What a command printed, for a caller that cannot run it itself. Not
// `follow`: it never ends, and the broker answers one call at a time.
output = function(name, args) {
    if (name == 'topics') return { output: join('  ', topics()) + '\n' };
    if (name == 'follow') return { error: 'follow: not over SSH. `logs` shows the latest lines.' };
    const list = argvs(name, args);
    if (type(list) != 'array') return list;
    const q = (s) => "'" + replace(s, "'", "'\\''") + "'";
    let out = '';
    for (let argv in list) {
        const p = _m_fs.popen(join(' ', map(argv, q)) + ' 2>&1', 'r');
        if (!p) continue;
        out += p.read('all') ?? '';
        p.close();
        if (length(list) > 1) out += '\n';
    }
    return { output: out };
};

return { argvs, output, topics };
