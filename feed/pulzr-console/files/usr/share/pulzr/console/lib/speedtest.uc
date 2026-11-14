// Speed tests, through pulzr-speedtest: the history, running one now, and
// the schedule. The tunnel half is measured from Pulzar Cloud's end, against the
// two endpoints api/index.uc answers on the tunnel port (tunnelSource,
// tunnelSink).

let _m_util = loadfile('/usr/share/pulzr/console/lib/util.uc', { raw_mode: true })();

// ucode does not hoist function declarations; see util.uc.
let status, start, setSchedule;

const TOOL = '/usr/sbin/pulzr-speedtest';

status = function() {
    return _m_util.runJson(TOOL + ' status') ?? { error: 'pulzr-speedtest is not on this gateway.' };
};

start = function() {
    return _m_util.tool(TOOL, ['start']);
};

setSchedule = function(req) {
    return _m_util.tool(TOOL, ['schedule', req.every ?? '']);
};

return { setSchedule, start, status };
