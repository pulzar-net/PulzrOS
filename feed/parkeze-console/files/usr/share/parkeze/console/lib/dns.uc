// The resolver, through parkeze-dns: its upstream servers, the names the LAN
// resolves locally, and rebind protection.
//
// Everything changed here lands in UCI dhcp, which `parkeze-dns status` reads
// back, and that is what the MQTT agent's `dns` op sends parkeze.net.

let _m_util = loadfile('/usr/share/parkeze/console/lib/util.uc', { raw_mode: true })();

// ucode does not hoist function declarations; see util.uc.
let dns, status, setUpstream, setHost, setRebind;

const TOOL = '/usr/sbin/parkeze-dns';

dns = (args) => _m_util.tool(TOOL, args);

status = function() {
    return _m_util.runJson(TOOL + ' status') ?? { error: 'parkeze-dns is not on this gateway.' };
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

return { setHost, setRebind, setUpstream, status };
