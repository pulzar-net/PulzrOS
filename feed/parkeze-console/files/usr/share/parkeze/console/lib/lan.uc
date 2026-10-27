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
let popen = _m_fs.popen;
let _m_util = loadfile('/usr/share/parkeze/console/lib/util.uc', { raw_mode: true })();

// ucode does not hoist function declarations; see util.uc.
let lan, status, setPolicy, reserve;

let runJson = _m_util.runJson;

const MAC = /^[0-9a-fA-F]{2}(:[0-9a-fA-F]{2}){5}$/;
const IPV4 = /^[0-9]{1,3}(\.[0-9]{1,3}){3}$/;
const NAME = /^[A-Za-z0-9-]{1,63}$/;

// parkeze-lan with arguments already checked against the patterns above, so
// none can carry a quote; quoted anyway. Its refusals are one line on stderr,
// which is what the caller shows.
lan = function(args) {
    const quoted = join(' ', map(args, (a) => "'" + a + "'"));
    const proc = popen('/usr/sbin/parkeze-lan ' + quoted + ' 2>&1', 'r');
    if (!proc) return { error: 'parkeze-lan is not on this gateway.' };
    const out = trim(proc.read('all') ?? '');
    const rc = proc.close();
    if (rc != 0) return { error: out ? uc(substr(out, 0, 1)) + substr(out, 1) + '.' : 'parkeze-lan failed.' };
    try { return json(out); } catch (e) { return { error: out }; }
};

status = function() {
    return runJson('/usr/sbin/parkeze-lan status') ?? { configured: false };
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
