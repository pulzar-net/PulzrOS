// Everything that changes the gateway, as one table both front ends call.
//
// The web console reaches these through api/index.uc and the terminal UI
// (pulzr-tui) calls them directly. Both used to be possible only by
// repeating the same lines — validate, call the module, write the audit
// record — in two places, and the first difference between them would have
// been an action that is audited from a browser and silent from a keyboard.
// So the API's route table keeps the HTTP (status codes, cookies, CSRF) and
// this keeps the rest.
//
// Each takes the request fields and the session, and returns what the module
// returned: an object with `error` when it was refused. Audit records are
// written only for what actually happened, as before.

let auth = loadfile('/usr/share/pulzr/console/lib/auth.uc', { raw_mode: true })();
let sys = loadfile('/usr/share/pulzr/console/lib/system.uc', { raw_mode: true })();
let network = loadfile('/usr/share/pulzr/console/lib/network.uc', { raw_mode: true })();
let lorawan = loadfile('/usr/share/pulzr/console/lib/lorawan.uc', { raw_mode: true })();
let claim = loadfile('/usr/share/pulzr/console/lib/claim.uc', { raw_mode: true })();
let io = loadfile('/usr/share/pulzr/console/lib/io.uc', { raw_mode: true })();
let access = loadfile('/usr/share/pulzr/console/lib/access.uc', { raw_mode: true })();
let firmware = loadfile('/usr/share/pulzr/console/lib/firmware.uc', { raw_mode: true })();
let bluetooth = loadfile('/usr/share/pulzr/console/lib/bluetooth.uc', { raw_mode: true })();
let signin = loadfile('/usr/share/pulzr/console/lib/signin.uc', { raw_mode: true })();
let lan = loadfile('/usr/share/pulzr/console/lib/lan.uc', { raw_mode: true })();
let dns = loadfile('/usr/share/pulzr/console/lib/dns.uc', { raw_mode: true })();
let uplinks = loadfile('/usr/share/pulzr/console/lib/uplinks.uc', { raw_mode: true })();
let ports = loadfile('/usr/share/pulzr/console/lib/ports.uc', { raw_mode: true })();
let speedtest = loadfile('/usr/share/pulzr/console/lib/speedtest.uc', { raw_mode: true })();

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
                       firmware.installFile(req.path, req.manifest, s.subject, !!s.shell));
    },

    // A shell from the terminal UI on a port; see shell() in tui/app.uc.
    // Recorded and nothing more: the shell is the TUI's to run.
    openShell: (req, s) => { auth.audit('console.shell', { by: s.subject, tty: req.tty }); return { ok: true }; },

    // ── network ─────────────────────────────────────────────────────────────
    setBluetooth: (req, s) => audited('bluetooth.set', { by: s.subject, enabled: req.enabled },
                                      bluetooth.set(req)),
    setCellular: (req, s) => network.setCellular(req, s),

    // ── ports: roles, VLANs, each uplink's addressing; see lib/ports.uc ─────
    setPorts: (req, s) => audited('ports.set', { by: s.subject, ports: req.ports }, ports.set(req, s)),
    setUplinkAddressing: (req, s) => audited('ports.addressing',
        { by: s.subject, port: req.port, vid: req.vid, mode: req.addressing?.mode,
          address: req.addressing?.address, gateway: req.addressing?.gateway },
        ports.setAddressing(req, s)),
    confirmPorts: (req, s) => ports.confirm(),

    // ── speed tests; see lib/speedtest.uc ──────────────────────────────────
    startSpeedtest: (req, s) => audited('speedtest.run', { by: s.subject }, speedtest.start()),
    setSpeedtestSchedule: (req, s) => audited('speedtest.schedule', { by: s.subject, every: req.every },
                                              speedtest.setSchedule(req)),
    revertPorts: (req, s) => audited('ports.revert', { by: s.subject }, ports.revert()),

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
    // A ticket into the WiFi sign-in proxy; see lib/signin.uc. `addr` is the
    // caller's address, which says which URL opens the proxy.
    startSignin: (req, s, addr) => audited('wifi.signin', { by: s.subject },
                                           signin.mintTicket(s.subject, addr)),
    // pulzr-wifi-uplink's check, now; see access.checkWifi.
    checkWifi: (req, s) => access.checkWifi(),

    // ── lan ─────────────────────────────────────────────────────────────────
    setLanPolicy: (req, s) => audited('lan.policy', { by: s.subject, mac: req.mac, policy: req.policy },
                                      lan.setPolicy(req)),
    setLanReserve: (req, s) => audited('lan.reserve',
        { by: s.subject, mac: req.mac, ip: req.ip || null, name: req.name || null },
        lan.reserve(req)),
    setLanCellular: (req, s) => audited('lan.cellular',
        { by: s.subject, mac: req.mac, mode: req.mode, blocks: req.blocks ?? [] },
        lan.setCellular(req)),
    setLanExpose: (req, s) => audited('lan.expose',
        { by: s.subject, proto: req.proto, port: req.port, ip: req.ip || null, dport: req.dport || null },
        lan.expose(req)),

    // ── dns ─────────────────────────────────────────────────────────────────
    setDnsUpstream: (req, s) => audited('dns.upstream', { by: s.subject, servers: req.servers ?? [] },
                                        dns.setUpstream(req)),
    setDnsHost: (req, s) => audited('dns.host', { by: s.subject, name: req.name, ip: req.ip || null },
                                    dns.setHost(req)),
    setDnsRebind: (req, s) => audited('dns.rebind',
        { by: s.subject, protection: !!req.protection, allowed: req.allowed ?? [] },
        dns.setRebind(req)),
    setDnsDdns: (req, s) => audited('dns.ddns',
        { by: s.subject, enabled: req.enabled !== false, name: req.name, zone: req.zone,
          uplink: req.uplink, token: req.token ? 'replaced' : 'kept' },
        dns.setDdns(req)),

    // ── uplinks ─────────────────────────────────────────────────────────────
    setUplinkOrder: (req, s) => audited('uplinks.order', { by: s.subject, order: req.order ?? [] },
                                        uplinks.setOrder(req)),
    setUplinkTrack: (req, s) => audited('uplinks.track', { by: s.subject, iface: req.iface, on: !!req.on },
                                        uplinks.setTrack(req)),
    setUplinkTracking: (req, s) => audited('uplinks.tracking',
        { by: s.subject, ips: req.ips ?? [], interval: req.interval, down: req.down, up: req.up },
        uplinks.setTracking(req)),

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
