// The devlan zone, through parkeze-lan: what the console reads and the two
// things it may change, a client's policy and its reservation.
//
// Forwards are not here. The one way into the LAN is the tunnel forward
// net-api opens over MQTT (lan-forward), and a console that could open one
// would be a second; it reads the open ones in status and nothing more.
//
// Everything changed here lands in parkeze-lan's own state (UCI dhcp and
// parkeze), which `parkeze-lan status` reads back, so parkeze.net's `lan` op
// sees a reservation made at the gateway exactly as one it made itself.

let _m_fs = require('fs');
let readfile = _m_fs.readfile;
let _m_uci = require('uci');
let cursor = _m_uci.cursor;
let _m_util = loadfile('/usr/share/parkeze/console/lib/util.uc', { raw_mode: true })();

// ucode does not hoist function declarations; see util.uc.
let lan, links, portOf, status, setPolicy, reserve;

let runJson = _m_util.runJson;

const MAC = /^[0-9a-fA-F]{2}(:[0-9a-fA-F]{2}){5}$/;
const IPV4 = /^[0-9]{1,3}(\.[0-9]{1,3}){3}$/;
const NAME = /^[A-Za-z0-9-]{1,63}$/;

// parkeze-lan with arguments already checked against the patterns above.
lan = (args) => _m_util.tool('/usr/sbin/parkeze-lan', args);

// Each LAN port's link, from the kernel. parkeze-lan reports the ports by
// name only, and "nothing answers on lan2" is usually a cable.
links = function(ports) {
    return map(ports, (name) => {
        const sys = sprintf('/sys/class/net/%s/', name);
        const speed = int(trim(readfile(sys + 'speed') ?? ''));
        return { name, up: trim(readfile(sys + 'operstate') ?? '') == 'up', speed: speed > 0 ? speed : null };
    });
};

// Which port each client is behind, from the bridge's forwarding table.
// `bridge fdb` and not the bridge's own sysfs table: on a DSA switch the
// addresses are learned in hardware, and only the dump through the ports
// lists them.
portOf = function(ports) {
    const bridge = cursor().get('network', 'devlan_dev', 'name');
    const out = {};
    if (!bridge || !match(bridge, /^[A-Za-z0-9._-]+$/)) return out;
    for (let e in (runJson(sprintf('bridge -j fdb show br %s 2>/dev/null', bridge)) ?? []))
        if (e.mac && (e.ifname in ports) && !('permanent' in (e.flags ?? [])) && e.state != 'permanent')
            out[lc(e.mac)] ??= e.ifname;
    return out;
};

status = function() {
    const s = runJson('/usr/sbin/parkeze-lan status') ?? { configured: false };
    if (!s.configured) return s;
    const ports = filter(s.ports ?? [], (p) => match(p, /^[A-Za-z0-9._-]+$/));
    s.links = links(ports);
    const where = portOf(ports);
    for (let c in (s.clients ?? []))
        c.port = where[lc(c.mac)] ?? null;
    return s;
};

setPolicy = function(req) {
    const mac = req.mac ?? '';
    if (!match(mac, MAC)) return { error: 'A MAC address, like 00:11:22:33:44:55.' };
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

return { reserve, setPolicy, status };
