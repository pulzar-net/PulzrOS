// The console's diagnostic prompt: `!` for a session that may not have a shell.
//
// Somebody at a gateway's serial or USB port, signed in as an organization's
// admin, needs the logs and the state of the links to say what is wrong. A
// shell would give them that and a copy of PulzrOS with it (app.uc's
// mayShell). This gives them the first and not the second.
//
// What each command runs is the console's lib/diag.uc: fixed programs, the
// words typed passed on as separate arguments and never as a command line.
// As root they run here, attached to the terminal; as the unprivileged SSH
// account, pulzr-console-broker runs them and this prints what they said.

let _m_fs = require('fs');

const USAGE = [
    [ 'logs <topic> [lines]', 'recent log lines for a topic (200 unless given)' ],
    [ 'follow <topic>', 'a topic as it is written; Ctrl-C stops' ],
    [ 'topics', 'what the logs are divided into' ],
    [ 'status', 'addresses and routes' ],
    [ 'wifi', 'the radios and what they are connected to' ],
    [ 'ping <host>', 'four pings' ],
    [ 'help', 'this list' ],
    [ 'exit', 'back to the console' ],
];

let help, run;

help = function() {
    for (let u in USAGE) print(sprintf('  %-22s %s\n', u[0], u[1]));
};

run = function(api, name, args) {
    if (name == 'help') return help();
    if (api.unprivileged) {
        const r = api.diag.output(name, args);
        return print(r.error ? r.error + '\n' : r.output);
    }
    if (name == 'topics') return print(join('  ', api.diag.topics()), '\n');
    const list = api.diag.argvs(name, args);
    if (type(list) != 'array') return print(list.error, '\n');
    for (let i = 0; i < length(list); i++) {
        if (i) print('\n');
        try { system(list[i]); } catch (e) { print('could not run ', list[i][0], '\n'); }
    }
};

// Runs until `exit` or end of input. The caller has given the terminal back
// to cooked mode and set the signals so Ctrl-C reaches the program running,
// not the console.
return function(api) {
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
        if (words[0] == 'exit') return;
        run(api, words[0], slice(words, 1));
    }
};
