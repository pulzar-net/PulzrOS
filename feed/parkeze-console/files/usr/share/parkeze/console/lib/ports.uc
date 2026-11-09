// The port layout, through parkeze-ports: each port's role, its VLANs, and
// each uplink's addressing.
//
// Every change is a whole layout handed to `parkeze-ports set`, which applies
// it and undoes it unless `confirm` follows inside its window. The console
// confirms from the browser once it reaches the gateway again after the
// change, so a layout that cuts off the person making it comes back on its
// own. Addressing for one uplink is a layout too: the uplink carrying the
// tunnel is the one a wrong static address takes away from somebody working
// through Pulzr Net.

let _m_fs = require('fs');
let popen = _m_fs.popen;
let writefile = _m_fs.writefile;
let unlink = _m_fs.unlink;
let readfile = _m_fs.readfile;
let _m_util = loadfile('/usr/share/parkeze/console/lib/util.uc', { raw_mode: true })();

// ucode does not hoist function declarations; see util.uc.
let ports, status, set, confirm, revert, setAddressing, layoutOf;

const TOOL = '/usr/sbin/parkeze-ports';

// The tool's JSON answer, or its one line on stderr as the error.
ports = function(args, input, by) {
    let path = null;
    if (input != null) {
        path = sprintf('/tmp/parkeze-ports.%s.json', trim(readfile('/proc/sys/kernel/random/uuid') ?? sprintf('%d', time())));
        writefile(path, sprintf('%J', input));
        push(args, path);
        if (by) push(args, by);
    }
    const quoted = join(' ', map(args, (a) => "'" + replace(a, "'", "'\\''") + "'"));
    const proc = popen(TOOL + ' ' + quoted + ' 2>&1', 'r');
    if (!proc) {
        if (path) unlink(path);
        return { error: 'parkeze-ports is not on this gateway.' };
    }
    const out = trim(proc.read('all') ?? '');
    const rc = proc.close();
    if (path) unlink(path);
    if (rc != 0) return { error: out || 'The ports could not be changed.' };
    try { return json(out); } catch (e) { return { error: out }; }
};

status = function() {
    return ports(['status']);
};

// The layout `set` takes, from what `status` reports.
layoutOf = function(st) {
    return {
        ports: map(st.ports ?? [], (p) => ({
            name: p.name, role: p.role, addressing: p.addressing,
            vlans: map(p.vlans ?? [], (v) => ({ vid: v.vid, role: v.role, addressing: v.addressing })),
        })),
    };
};

set = function(req, session) {
    if (type(req?.ports) != 'array') return { error: 'A layout is a list of ports.' };
    return ports(['set'], { ports: req.ports }, session?.subject);
};

// One uplink's addressing, by port and VLAN (none for untagged), with the
// rest of the layout as it is.
setAddressing = function(req, session) {
    const st = status();
    if (st.error) return st;
    const layout = layoutOf(st);
    let found = false;
    for (let p in layout.ports) {
        if (p.name != req.port) continue;
        if (req.vid == null) {
            if (p.role != 'uplink') return { error: 'That port is not an uplink.' };
            p.addressing = req.addressing;
            found = true;
        }
        for (let v in p.vlans)
            if (v.vid == req.vid) {
                if (v.role != 'uplink') return { error: 'That VLAN is not an uplink.' };
                v.addressing = req.addressing;
                found = true;
            }
    }
    if (!found) return { error: 'No such uplink.' };
    return ports(['set'], layout, session?.subject);
};

confirm = function() {
    return ports(['confirm']);
};

revert = function() {
    return ports(['revert']);
};

// ── module exports ──────────────────────────────────────────────────────────
//
// A returned object, not `export` statements; see the header of
// api/index.uc.
return { confirm, revert, set, setAddressing, status };
