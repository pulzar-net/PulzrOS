// Everything that changes the gateway, as one table both front ends call.
//
// The web console reaches these through api/index.uc and the terminal UI
// (parkeze-tui) calls them directly. Both used to be possible only by
// repeating the same lines — validate, call the module, write the audit
// record — in two places, and the first difference between them would have
// been an action that is audited from a browser and silent from a keyboard.
// So the API's route table keeps the HTTP (status codes, cookies, CSRF) and
// this keeps the rest.
//
// Each takes the request fields and the session, and returns what the module
// returned: an object with `error` when it was refused. Audit records are
// written only for what actually happened, as before.

let auth = loadfile('/usr/share/parkeze/console/lib/auth.uc', { raw_mode: true })();
let sys = loadfile('/usr/share/parkeze/console/lib/system.uc', { raw_mode: true })();
let network = loadfile('/usr/share/parkeze/console/lib/network.uc', { raw_mode: true })();
let lorawan = loadfile('/usr/share/parkeze/console/lib/lorawan.uc', { raw_mode: true })();
let claim = loadfile('/usr/share/parkeze/console/lib/claim.uc', { raw_mode: true })();
let io = loadfile('/usr/share/parkeze/console/lib/io.uc', { raw_mode: true })();
let access = loadfile('/usr/share/parkeze/console/lib/access.uc', { raw_mode: true })();
let firmware = loadfile('/usr/share/parkeze/console/lib/firmware.uc', { raw_mode: true })();
let bluetooth = loadfile('/usr/share/parkeze/console/lib/bluetooth.uc', { raw_mode: true })();

// ucode does not hoist function declarations; see util.uc.
let audited;

// `result`, after auditing `action` with `detail` unless it was a refusal.
audited = function(action, detail, result) {
    if (!result?.error) auth.audit(action, detail);
    return result;
};

const ACTIONS = {
    // ── system ──────────────────────────────────────────────────────────────
    reboot: (req, s) => { auth.audit('system.reboot', { by: s.subject }); return sys.reboot(); },
    setUart: (req, s) => audited('system.uart', { by: s.subject, role: req.role },
                                 sys.setUart(req.role)),
    setPassword: (req, s) => auth.setPassword(req.username, req.password),

    // From a file already on the gateway; see firmware.installFile. The web
    // console's upload streams its body and stays in api/index.uc.
    installFirmware: (req, s) => {
        auth.audit('system.firmware.file', { by: s.subject, path: req.path });
        return audited('system.firmware.apply', { by: s.subject, path: req.path },
                       firmware.installFile(req.path, req.manifest, s.subject));
    },

    // A shell from the terminal UI on a port; see shell() in tui/app.uc.
    // Recorded and nothing more: the shell is the TUI's to run.
    openShell: (req, s) => { auth.audit('console.shell', { by: s.subject, tty: req.tty }); return { ok: true }; },

    // ── network ─────────────────────────────────────────────────────────────
    setBluetooth: (req, s) => audited('bluetooth.set', { by: s.subject, enabled: req.enabled },
                                      bluetooth.set(req)),
    setCellular: (req, s) => network.setCellular(req, s),
    setEthernet: (req, s) => audited('network.ethernet',
        { by: s.subject, mode: req.mode, address: req.address, gateway: req.gateway },
        network.setEthernet(req, s)),

    // ── provisioning ────────────────────────────────────────────────────────
    claimPoll: (req, s) => claim.poll(),
    claimApply: (req, s) => claim.applyBundle(req),
    checkAdoption: (req, s) => claim.checkAdoption(),

    // ── access ──────────────────────────────────────────────────────────────
    setAp: (req, s) => access.setAp(req),
    raiseAp: (req, s) => { auth.audit('ap.raise', { by: s.subject }); return access.raiseAp(req); },
    lowerAp: (req, s) => { auth.audit('ap.lower', { by: s.subject }); return access.lowerAp(); },
    forgetWifi: (req, s) => {
        auth.audit('wifi.forget', { by: s.subject, ssid: req.ssid });
        return access.forgetWifi(req);
    },
    joinWifi: (req, s) => audited('wifi.join',
        { by: s.subject, ssid: req.ssid, security: req.eap ? 'eap' : (req.key ? 'psk' : 'open') },
        access.joinWifi(req)),
    probeWifi: (req, s) => audited('wifi.probe', { by: s.subject, ssid: req.ssid },
                                   access.probeWifi(req)),

    // ── io ──────────────────────────────────────────────────────────────────
    ioTest: (req, s) => { auth.audit('io.test', { by: s.subject }); return io.test(); },

    // ── lorawan ─────────────────────────────────────────────────────────────
    setConcentrator: (req, s) => lorawan.setConcentrator(req, s),
    setSlot: (req, s) => lorawan.setSlot(req.index, req, s),
    detect: (req, s) => { auth.audit('lorawan.detect', { by: s.subject }); return lorawan.detect(); },
    setBackhaul: (req, s) => {
        auth.audit('lorawan.backhaul', { by: s.subject, allowCellular: req.allowCellular, buffer: req.buffer });
        return lorawan.setBackhaul(req, s);
    },
    restart: (req, s) => { auth.audit('lorawan.restart', { by: s.subject }); return lorawan.restart(); },

    // ── gnss ────────────────────────────────────────────────────────────────
    setGpsSource: (req, s) => audited('gps.source',
        { by: s.subject, source: req.source, slot: req.slot, device: req.device },
        lorawan.setGpsSource(req)),
    detectGps: (req, s) => { auth.audit('gps.detect', { by: s.subject }); return lorawan.detectGps(); },
    syncGps: (req, s) => audited('gps.sync', { by: s.subject }, lorawan.syncGps()),
};

return ACTIONS;
