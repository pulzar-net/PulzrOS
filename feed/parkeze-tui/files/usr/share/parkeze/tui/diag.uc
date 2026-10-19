// The console's diagnostic prompt: `!` for a session that may not have a shell.
//
// Somebody at a gateway's serial or USB port, signed in as an organization's
// admin, needs the logs and the state of the links to say what is wrong. A
// shell would give them that and a copy of ParkezeOS with it (app.uc's
// mayShell). This gives them the first and not the second.
//
// Every command is a fixed program run without a shell: the words typed are
// matched against the table below and passed on as separate arguments, never
// as a command line, so nothing typed can become a command of its own. Nothing
// here reads a file, edits anything or starts a process that outlives it.

let _m_fs = require('fs');

const LOGS = '/usr/sbin/parkeze-logs';

let topics, run, commands, help;

topics = function() {
    const p = _m_fs.popen(LOGS + ' --topics 2>/dev/null', 'r');
    if (!p) return [];
    const out = p.read('all') ?? '';
    p.close();
    return filter(split(trim(out), '\n'), (t) => length(t));
};

run = function(argv) {
    try { system(argv); } catch (e) { print('could not run ', argv[0], '\n'); }
};

// A host for ping: a name or an address, nothing a program could take for an
// option.
const HOST = /^[A-Za-z0-9][A-Za-z0-9.:-]{0,252}$/;

commands = {
    help: {
        usage: 'help',
        what: 'this list',
        fn: () => help(),
    },
    topics: {
        usage: 'topics',
        what: 'what the logs are divided into',
        fn: () => print(join('  ', topics()), '\n'),
    },
    logs: {
        usage: 'logs <topic> [lines]',
        what: 'recent log lines for a topic (200 unless given)',
        fn: function(args) {
            if (!(args[0] in topics())) return print('logs: name a topic: ', join(' ', topics()), '\n');
            if (args[1] != null && !match(args[1], /^[0-9]{1,4}$/)) return print('logs: lines is a number\n');
            run([ LOGS, args[0], args[1] ?? '200' ]);
        },
    },
    follow: {
        usage: 'follow <topic>',
        what: 'a topic as it is written; Ctrl-C stops',
        fn: function(args) {
            if (!(args[0] in topics())) return print('follow: name a topic: ', join(' ', topics()), '\n');
            run([ LOGS, args[0], '--follow' ]);
        },
    },
    status: {
        usage: 'status',
        what: 'addresses and routes',
        fn: function() {
            run([ '/sbin/ip', '-br', 'addr' ]);
            print('\n');
            run([ '/sbin/ip', 'route' ]);
        },
    },
    wifi: {
        usage: 'wifi',
        what: 'the radios and what they are connected to',
        fn: () => run([ '/usr/bin/iwinfo' ]),
    },
    ping: {
        usage: 'ping <host>',
        what: 'four pings',
        fn: function(args) {
            if (!match(args[0] ?? '', HOST)) return print('ping: give a host name or an address\n');
            run([ '/bin/ping', '-c', '4', '-W', '2', args[0] ]);
        },
    },
    exit: {
        usage: 'exit',
        what: 'back to the console',
        fn: () => null,
    },
};

help = function() {
    for (let name in [ 'logs', 'follow', 'topics', 'status', 'wifi', 'ping', 'help', 'exit' ]) {
        const c = commands[name];
        print(sprintf('  %-22s %s\n', c.usage, c.what));
    }
};

// Runs until `exit` or end of input. The caller has given the terminal back
// to cooked mode and set the signals so Ctrl-C reaches the program running,
// not the console.
return function() {
    print('\nDiagnostics. `help` lists the commands; `exit` returns to the console.\n\n');
    while (true) {
        print('diag> ');
        _m_fs.stdout.flush();
        const line = _m_fs.stdin.read('line');
        if (line == null || line == '') {
            // A Ctrl-C at the prompt interrupts the read; only end of input ends this.
            if (index(_m_fs.error() ?? '', 'nterrupted') >= 0) { print('\n'); continue; }
            print('\n');
            return;
        }
        const words = filter(split(trim(line), /[ \t]+/), (w) => length(w));
        if (!length(words)) continue;
        const c = commands[words[0]];
        if (!c) { print(words[0], ': not a command here. `help` lists them.\n'); continue; }
        if (words[0] == 'exit') return;
        c.fn(slice(words, 1));
    }
};
