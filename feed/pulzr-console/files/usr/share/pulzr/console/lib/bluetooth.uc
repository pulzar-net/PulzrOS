// Bluetooth: whether this gateway scans for parking beacons beside its
// LoRaWAN radio, and what it heard. See pulzr-ble for the scanner.

let _m_fs = require('fs');
let readfile = _m_fs.readfile;; let writefile = _m_fs.writefile;
let _m_uci = require('uci');
let cursor = _m_uci.cursor;
let _m_util = loadfile('/usr/share/pulzr/console/lib/util.uc', { raw_mode: true })();

// ucode does not hoist function declarations; see system.uc.
let status, set;

let run = _m_util.run;; let runJson = _m_util.runJson;

// On tmpfs, so the reboot clears it; see the same constant in system.uc.
const REBOOT_REQUIRED = '/var/run/pulzr/reboot-required';

status = function() {
    const uci = cursor();
    // on, off or absent: what the facts report says, so the console and
    // Pulzar Cloud cannot read the same gateway two ways.
    const state = run('/usr/sbin/pulzr-ble state') ?? 'absent';
    const enabled = uci.get('pulzr', 'ble', 'enabled') == '1';
    const running = run('pgrep -f "pulzr-ble run"') != null;
    let heard = null;
    try { heard = json(readfile('/var/run/pulzr/ble/stats.json') ?? 'null'); } catch (e) {}
    return {
        state,
        enabled,
        // Running is the scanner actually up; enabled and not running after a
        // minute is worth a look at the log.
        running,
        // On, not scanning, and a boot is waiting to wire the chip: only the
        // reboot can fix that.
        rebootRequired: enabled && !running && !!readfile(REBOOT_REQUIRED),
        oui: uci.get('pulzr', 'ble', 'oui') ?? '',
        minRssi: +(uci.get('pulzr', 'ble', 'min_rssi') ?? -100),
        heard,
    };
};

set = function(req) {
    if (type(req.enabled) != 'bool')
        return { error: 'enabled must be true or false.' };

    const uci = cursor();
    uci.set('pulzr', 'ble', 'ble');
    uci.set('pulzr', 'ble', 'enabled', req.enabled ? '1' : '0');
    uci.commit('pulzr');

    // The boot files follow the setting either way. They matter only to the
    // next boot, so whether one is needed now is the chip's to say: if it
    // attaches, it is already wired -- turned off and on again, say -- and the
    // changed files are not a reason to reboot. If it does not, on a Pi the
    // UART it needs is wired only at boot. Said, not done, as for the UART role.
    const boot = runJson('/usr/sbin/pulzr-boot-config') ?? {};
    if (!req.enabled) {
        system('/etc/init.d/pulzr-ble stop; /etc/init.d/pulzr-ble disable');
        return { ok: true, enabled: false, rebootRequired: false };
    }
    const attached = system('/usr/sbin/pulzr-ble attach >/dev/null 2>&1') == 0;
    system('/etc/init.d/pulzr-ble enable; /etc/init.d/pulzr-ble restart');
    const rebootRequired = !attached && !!boot.changed;
    if (rebootRequired) { _m_fs.mkdir('/var/run/pulzr'); writefile(REBOOT_REQUIRED, ''); }
    return { ok: true, enabled: true, rebootRequired };
};

return { set, status };
