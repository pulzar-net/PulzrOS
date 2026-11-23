// The resolver, through pulzr-dns: its upstream servers, the names the LAN
// resolves locally, and rebind protection.
//
// Everything changed here lands in UCI dhcp, which `pulzr-dns status` reads
// back, and that is what the MQTT agent's `dns` op sends Pulzr Cloud.

let _m_fs = require('fs');
let _m_util = loadfile('/usr/share/pulzr/console/lib/util.uc', { raw_mode: true })();

// ucode does not hoist function declarations; see util.uc.
let dns, status, setUpstream, setHost, setRebind, setDdns;

const TOOL = '/usr/sbin/pulzr-dns';

dns = (args) => _m_util.tool(TOOL, args);

status = function() {
    return _m_util.runJson(TOOL + ' status') ?? { error: 'pulzr-dns is not on this gateway.' };
};

// No servers is the uplinks' own, as the page's Automatic says.
setUpstream = function(req) {
    const servers = type(req.servers) == 'array' ? req.servers : [];
    return dns(['upstream', ...(length(servers) ? servers : ['auto'])]);
};

// No ip removes the name.
setHost = function(req) {
    if (!req.name) return { error: 'A name, like nas.' };
    if (req.ip == null || req.ip == '') return dns(['unhost', req.name ?? '']);
    return dns(['host', req.name ?? '', req.ip]);
};

setRebind = function(req) {
    const allowed = type(req.allowed) == 'array' ? req.allowed : [];
    return dns(['rebind', req.protection ? 'on' : 'off', ...allowed]);
};

// The token, when one is given, goes to pulzr-dns on stdin and nowhere
// else: not an argument, not the audit log, not the answer. Then the name.
setDdns = function(req) {
    if (req.enabled === false) return dns(['ddns', 'off']);
    if (req.token) {
        if (type(req.token) != 'string' || !match(req.token, /^[A-Za-z0-9_-]{20,128}$/))
            return { error: 'That is not a Cloudflare API token.' };
        const proc = _m_fs.popen(TOOL + ' ddns-token >/dev/null 2>&1', 'w');
        if (!proc) return { error: 'pulzr-dns is not on this gateway.' };
        proc.write(req.token);
        if (proc.close() != 0) return { error: 'The token was not saved.' };
    }
    return dns(['ddns', req.name ?? '', req.zone ?? '', req.uplink ?? '']);
};

return { setDdns, setHost, setRebind, setUpstream, status };
