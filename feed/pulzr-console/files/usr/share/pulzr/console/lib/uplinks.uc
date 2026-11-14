// The uplink order and tracking, through pulzr-uplinks.
//
// The order and tracking settings land in UCI (pulzr.uplinks), which
// `pulzr-uplinks status` reads back, and that is what the MQTT agent's
// `uplinks` op sends Pulzar Cloud.

let _m_util = loadfile('/usr/share/pulzr/console/lib/util.uc', { raw_mode: true })();

// ucode does not hoist function declarations; see util.uc.
let uplinks, status, setOrder, setTrack, setTracking;

const TOOL = '/usr/sbin/pulzr-uplinks';

uplinks = (args) => _m_util.tool(TOOL, args);

status = function() {
    return _m_util.runJson(TOOL + ' status') ?? { error: 'pulzr-uplinks is not on this gateway.' };
};

setOrder = function(req) {
    return uplinks(['order', ...(type(req.order) == 'array' ? req.order : [])]);
};

setTrack = function(req) {
    return uplinks(['track', req.iface ?? '', req.on ? 'on' : 'off']);
};

setTracking = function(req) {
    const ips = type(req.ips) == 'array' ? req.ips : [];
    if (!length(ips)) return { error: 'One to four addresses to ping.' };
    for (let ip in ips)
        if (type(ip) != 'string' || index(ip, ',') >= 0) return { error: 'An IPv4 address, like 1.1.1.1.' };
    return uplinks(['tracking', join(',', ips), sprintf('%d', int(req.interval ?? 0)),
                    sprintf('%d', int(req.down ?? 0)), sprintf('%d', int(req.up ?? 0))]);
};

return { setOrder, setTrack, setTracking, status };
