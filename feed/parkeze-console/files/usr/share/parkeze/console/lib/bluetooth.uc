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

// On tmpfs, so the reboot clears it; see the same constant in system.uc.
const REBOOT_REQUIRED = '/var/run/parkeze/reboot-required';

status = function() {
    const uci = cursor();
    // on, off or absent: what the facts report says, so the console and
    // parkeze.net cannot read the same gateway two ways.
    const state = run('/usr/sbin/parkeze-ble state') ?? 'absent';
    const enabled = uci.get('parkeze', 'ble', 'enabled') == '1';
    const running = run('pgrep -f "parkeze-ble run"') != null;
    let heard = null;
    try { heard = json(readfile('/var/run/parkeze/ble/stats.json') ?? 'null'); } catch (e) {}
    return {
        state,
        enabled,
        // Running is the scanner actually up; enabled and not running after a
        // minute is worth a look at the log.
        running,
        // On, not scanning, and a boot is waiting to wire the chip: only the
        // reboot can fix that.
        rebootRequired: enabled && !running && !!readfile(REBOOT_REQUIRED),
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

    // The boot files follow the setting either way. They matter only to the
    // next boot, so whether one is needed now is the chip's to say: if it
    // attaches, it is already wired -- turned off and on again, say -- and the
    // changed files are not a reason to reboot. If it does not, on a Pi the
    // UART it needs is wired only at boot. Said, not done, as for the UART role.
    const boot = runJson('/usr/sbin/parkeze-boot-config') ?? {};
    if (!req.enabled) {
        system('/etc/init.d/parkeze-ble stop; /etc/init.d/parkeze-ble disable');
        return { ok: true, enabled: false, rebootRequired: false };
    }
    const attached = system('/usr/sbin/parkeze-ble attach >/dev/null 2>&1') == 0;
    system('/etc/init.d/parkeze-ble enable; /etc/init.d/parkeze-ble restart');
    const rebootRequired = !attached && !!boot.changed;
    if (rebootRequired) { _m_fs.mkdir('/var/run/parkeze'); writefile(REBOOT_REQUIRED, ''); }
    return { ok: true, enabled: true, rebootRequired };
};

return { set, status };
