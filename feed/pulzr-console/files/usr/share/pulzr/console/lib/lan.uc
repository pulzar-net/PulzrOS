// The devlan zone, through pulzr-lan: what the console reads and what it
// may change per client (policy, reservation, cellular rule), and the ports
// exposed on the wired and WiFi uplinks.
//
// Tunnel forwards are not here: they are the cloud's, opened over MQTT
// (lan-forward), and the console reads the open ones in status and nothing
// more. An exposed port is the site's, made at the gateway by somebody
// standing at it, and never reaches the tunnel (see pulzr-lan).
//
// Everything changed here lands in pulzr-lan's own state (UCI dhcp and
// pulzr), which `pulzr-lan status` reads back, so Pulzar Cloud's `lan` op
// sees a reservation made at the gateway exactly as one it made itself.

let _m_fs = require('fs');
let readfile = _m_fs.readfile;
let _m_util = loadfile('/usr/share/pulzr/console/lib/util.uc', { raw_mode: true })();

// ucode does not hoist function declarations; see util.uc.
let lan, links, status, setPolicy, reserve, setCellular, expose;

let runJson = _m_util.runJson;

const MAC = /^[0-9a-fA-F]{2}(:[0-9a-fA-F]{2}){5}$/;
const IPV4 = /^[0-9]{1,3}(\.[0-9]{1,3}){3}$/;
const NAME = /^[A-Za-z0-9-]{1,63}$/;

// pulzr-lan with arguments already checked against the patterns above.
lan = (args) => _m_util.tool('/usr/sbin/pulzr-lan', args);

// Each LAN port's link, from the kernel. pulzr-lan reports the ports by
// name only, and "nothing answers on lan2" is usually a cable.
links = function(ports) {
    return map(ports, (name) => {
        const sys = sprintf('/sys/class/net/%s/', name);
        const speed = int(trim(readfile(sys + 'speed') ?? ''));
        return { name, up: trim(readfile(sys + 'operstate') ?? '') == 'up', speed: speed > 0 ? speed : null };
    });
};

status = function() {
    const s = runJson('/usr/sbin/pulzr-lan status') ?? { configured: false };
    if (!s.configured) return s;
    const ports = filter(s.ports ?? [], (p) => match(p, /^[A-Za-z0-9._-]+$/));
    s.links = links(ports);
    return s;
};

setPolicy = function(req) {
    const mac = req.mac ?? '';
    if (!match(mac, MAC)) return { error: 'A MAC address, like 00:11:22:33:44:55.' };
    // Compat: `parkeze` is the policy value the cloud sends and reads.
    if (req.policy != 'parkeze' && req.policy != 'internet')
        return { error: 'Policy is parkeze or internet.' };
    return lan(['policy', mac, req.policy]);
};

// No ip releases the reservation, as lan-reserve does over MQTT.
reserve = function(req) {
    const mac = req.mac ?? '';
    if (!match(mac, MAC)) return { error: 'A MAC address, like 00:11:22:33:44:55.' };
    if (req.ip == null || req.ip == '') return lan(['unreserve', mac]);
    if (!match(req.ip, IPV4)) return { error: 'An IPv4 address on the LAN.' };
    if (req.name != null && req.name != '' && !match(req.name, NAME))
        return { error: 'A name is letters, digits and hyphens.' };
    const args = ['reserve', mac, req.ip];
    if (req.name) push(args, req.name);
    return lan(args);
};

// allow with no ports is the default; allow with ports blocks those on
// cellular; block keeps the client off cellular altogether.
setCellular = function(req) {
    const mac = req.mac ?? '';
    if (!match(mac, MAC)) return { error: 'A MAC address, like 00:11:22:33:44:55.' };
    if (req.mode != 'allow' && req.mode != 'block') return { error: 'Cellular is allow or block.' };
    const blocks = type(req.blocks) == 'array' ? req.blocks : [];
    return lan(['cellular', mac, req.mode, ...(req.mode == 'allow' ? blocks : [])]);
};

// No ip removes it.
expose = function(req) {
    const proto = req.proto ?? '', port = sprintf('%d', int(req.port ?? 0));
    if (proto != 'tcp' && proto != 'udp') return { error: 'TCP or UDP.' };
    if (req.ip == null || req.ip == '') return lan(['unexpose', proto, port]);
    if (!match(req.ip, IPV4)) return { error: 'An IPv4 address on the LAN.' };
    const args = ['expose', proto, port, req.ip];
    if (req.dport) push(args, sprintf('%d', int(req.dport)));
    return lan(args);
};

return { expose, reserve, setCellular, setPolicy, status };
