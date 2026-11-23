// Speed tests, through pulzr-speedtest: the history, running one now, and
// the schedule. The tunnel half is measured from Pulzr Cloud's end, against the
// two endpoints api/index.uc answers on the tunnel port (tunnelSource,
// tunnelSink).

let _m_util = loadfile('/usr/share/pulzr/console/lib/util.uc', { raw_mode: true })();

// ucode does not hoist function declarations; see util.uc.
let status, start, setSchedule;

const TOOL = '/usr/sbin/pulzr-speedtest';

status = function() {
    return _m_util.runJson(TOOL + ' status') ?? { error: 'pulzr-speedtest is not on this gateway.' };
};

// Every free uplink, or the one named; a metered one only with `metered`,
// which the console sends after showing the estimate (pulzr-speedtest).
start = function(req) {
    if (req?.iface == null) return _m_util.tool(TOOL, ['start']);
    return _m_util.tool(TOOL, ['start', req.iface, ...(req.metered === true ? ['metered'] : [])]);
};

setSchedule = function(req) {
    return _m_util.tool(TOOL, ['schedule', req.every ?? '']);
};

return { setSchedule, start, status };
