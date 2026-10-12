// Bluetooth: whether this gateway scans for parking beacons beside its
// LoRaWAN radio, and what it heard. See parkeze-ble for the scanner.

let _m_fs = require('fs');
let readfile = _m_fs.readfile;; let writefile = _m_fs.writefile;
let _m_uci = require('uci');
let cursor = _m_uci.cursor;
let _m_util = loadfile('/usr/share/parkeze/console/lib/util.uc', { raw_mode: true })();

// ucode does not hoist function declarations; see system.uc.
let status, set;

let run = _m_util.run;; let runJson = _m_util.runJson;

status = function() {
    const uci = cursor();
    // on, off or absent: what the facts report says, so the console and
    // parkeze.net cannot read the same gateway two ways.
    const state = run('/usr/sbin/parkeze-ble state') ?? 'absent';
    const boot = runJson('/usr/sbin/parkeze-boot-config --dry-run') ?? {};
    let heard = null;
    try { heard = json(readfile('/var/run/parkeze/ble/stats.json') ?? 'null'); } catch (e) {}
    return {
        state,
        enabled: uci.get('parkeze', 'ble', 'enabled') == '1',
        // Running is the scanner actually up; enabled and not running after a
        // minute is worth a look at the log.
        running: run('pgrep -f "parkeze-ble run"') != null,
        // The boot files do not yet say what the setting does, which only the
        // next boot can fix.
        rebootRequired: !!boot.changed,
        oui: uci.get('parkeze', 'ble', 'oui') ?? '',
        minRssi: +(uci.get('parkeze', 'ble', 'min_rssi') ?? -100),
        heard,
    };
};

set = function(req) {
    if (type(req.enabled) != 'bool')
        return { error: 'enabled must be true or false.' };

    const uci = cursor();
    uci.set('parkeze', 'ble', 'ble');
    uci.set('parkeze', 'ble', 'enabled', req.enabled ? '1' : '0');
    uci.commit('parkeze');

    // On a Pi the chip's UART is wired at boot, so turning it on the first
    // time needs one; that is said, not done, the same as the UART role.
    const boot = runJson('/usr/sbin/parkeze-boot-config') ?? {};
    if (boot.changed) writefile('/etc/parkeze/boot-config-reboot-pending', '');

    system(req.enabled
        ? '/etc/init.d/parkeze-ble enable; /etc/init.d/parkeze-ble restart'
        : '/etc/init.d/parkeze-ble stop; /etc/init.d/parkeze-ble disable');
    return { ok: true, enabled: req.enabled, rebootRequired: !!boot.changed };
};

return { set, status };
