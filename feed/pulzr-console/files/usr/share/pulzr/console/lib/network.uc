// Network and backhaul state.
//
//   ethernet   every wired uplink is pulzr-ports' (lib/ports.uc): which
//              ports and VLANs are uplinks, and each one's addressing. This
//              reports the console's fixed addresses and the path the tunnel
//              is on.
//
//   cellular   configurable here, because an APN is a site-by-site fact and
//              waiting on Pulzr Cloud to push one to a gateway that has no
//              working backhaul is circular.

let _m_fs = require('fs');
let readfile = _m_fs.readfile;
let _m_uci = require('uci');
let cursor = _m_uci.cursor;
let _m_util = loadfile('/usr/share/pulzr/console/lib/util.uc', { raw_mode: true })();

// ── forward declarations ────────────────────────────────────────────────────
//
// ucode does not hoist function declarations. A `function f()` defined below
// a function that calls it is simply not in scope there, and the call fails at
// RUNTIME with "left-hand side is not a function" — never at compile time, so
// nothing catches it until the request that needs it.
//
// Declaring the names first makes every one of them a known local before any
// body is compiled, so closures capture the binding rather than a missing
// global and definition order stops mattering. auth.uc alone had six of these.
let ifaceStatus, linkSpeed, cellularStatus, status, modem, backhaul, setCellular, setSimSlot;

let run = _m_util.run;; let runJson = _m_util.runJson;; let ubus = _m_util.ubus;

ifaceStatus = function(name) {
    const status = ubus(sprintf('network.interface.%s', name), 'status');
    if (!status) return { configured: false };

    // Every address, not one: an interface can hold several (a static list,
    // a lease and an alias), and the page lists them all. `address` is the
    // first, which is the one netifd configured first.
    let addresses = map(status['ipv4-address'] ? status['ipv4-address'] : [],
                        (a) => sprintf('%s/%d', a.address, a.mask));
    let address = length(addresses) ? addresses[0] : null, gateway = null;
    for (let r in (status.route ? status.route : []))
        if (r.target == '0.0.0.0' && r.mask == 0) gateway = r.nexthop;

    return {
        configured: true,
        up: !!status.up,
        available: !!status.available,
        device: status.l3_device,
        proto: status.proto,
        address: address,
        addresses: addresses,
        gateway: gateway,
        uptime: status.uptime,
    };
};

// Negotiated speed in Mb/s, or null: the kernel answers -1 or nothing for a
// port with no link, and a virtual device has no speed at all.
linkSpeed = function(dev) {
    if (!dev || !match(dev, /^[A-Za-z0-9._-]+$/)) return null;
    const speed = int(trim(readfile(sprintf('/sys/class/net/%s/speed', dev)) ?? ''));
    return speed > 0 ? speed : null;
};

// The cellular uplink carrying traffic, as ifaceStatus reports it. wwan is
// the modem ModemManager drives; usbwan a HiLink dongle or a tethered phone
// (pulzr-usb-cellular). wwan unless only usbwan is up, the same order the
// tunnel and the route metrics take them in.
cellularStatus = function() {
    const wwan = ifaceStatus('wwan');
    if (wwan.up) return wwan;
    const usb = ifaceStatus('usbwan');
    return usb.up ? usb : wwan;
};

status = function() {
    const uci = cursor();
    return {
        // The console addresses on the shared ethernet port. Reported so the
        // Backhaul page can show that local access is up even when the uplink
        // is not — those are independent on this hardware, and conflating them
        // is what makes a gateway look dead when it is merely unplugged.
        console: ifaceStatus('console'),
        linkLocal: ifaceStatus('linklocal'),
        cellular: {
            manageable: true,
            enabled: uci.get('network', 'wwan', 'disabled') != '1',
            apn: uci.get('network', 'wwan', 'apn'),
            ...cellularStatus(),
            modem: modem(),
        },
    };
};

modem = function() {
    // mmcli, not uqmi: cellular goes through ModemManager, chosen when
    // OpenWrt 24.10 shipped no uqmi. An absent modem is a normal state — a wired-only
    // board has none — so this returns null rather than erroring.
    const found = runJson('/usr/sbin/pulzr-modem-detect --status');
    if (!found || !found.present) return null;

    // A HiLink dongle or a phone. Not ModemManager's, so there is no index to
    // ask and no SIM, operator or signal to read: the model is what the USB
    // device calls itself, and that is all there is.
    if (found.kind == 'hilink' || found.kind == 'tether')
        return { kind: found.kind, model: found.model || null, registration: null,
                 network: null, technology: null, quality: null,
                 rssi: null, rsrp: null, snr: null };

    // `mmcli --output-keyvalue` is the stable machine-readable form; the human
    // output reflows between releases and is not worth parsing.
    const raw = run(sprintf('mmcli -m %d --output-keyvalue 2>/dev/null', found.index));
    if (!raw) return { kind: found.kind, model: found.model, registration: null, slots: found.slots ?? null };

    const field = {};
    for (let line in split(raw, '\n')) {
        const at = index(line, ':');
        if (at < 0) continue;
        field[trim(substr(line, 0, at))] = trim(substr(line, at + 1));
    }

    // Signal quality is a percentage from ModemManager; the dBm figures come
    // from the extended signal API and are only present once `mmcli
    // --signal-setup` has run, so they are reported when available and skipped
    // when not rather than faked from the percentage.
    return {
        kind: found.kind,
        model: found.model,
        // Each SIM holder, on a modem with more than one; null otherwise.
        slots: found.slots ?? null,
        imei: found.imei,
        registration: field['modem.generic.state'] || null,
        network: field['modem.3gpp.operator-name'] || null,
        technology: field['modem.generic.access-technologies.value[1]'] || null,
        quality: field['modem.generic.signal-quality.value']
                 ? int(field['modem.generic.signal-quality.value']) : null,
        rssi: field['modem.signal.lte.rssi']
              ? int(field['modem.signal.lte.rssi']) : null,
        rsrp: field['modem.signal.lte.rsrp']
              ? int(field['modem.signal.lte.rsrp']) : null,
        snr: field['modem.signal.lte.snr']
             ? int(field['modem.signal.lte.snr']) : null,
    };
};

// Which management paths are actually working right now.
//
// This is the view Pulzr Cloud cares about most and the one an operator on
// site checks first: not "is there internet" but "can we be managed, and over
// which path". The two paths fail independently and for different reasons, and
// conflating them into a single "online" light is how a gateway ends up
// looking healthy while being unmanageable.
backhaul = function() {
    const route = runJson('/usr/sbin/pulzr-wireguard-route status');
    const config = runJson('cat /etc/pulzr/wireguard/tunnel.json 2>/dev/null');
    const state = run('/usr/sbin/pulzr-backhaul-check --tunnel') || 'none';

    // Seconds since the hub last completed a handshake, from the kernel.
    let lastHandshake = null;
    const handshakes = run('wg show wg0 latest-handshakes 2>/dev/null');
    if (handshakes) {
        const at = int(split(handshakes, /\s+/)[1]);
        if (at > 0) lastHandshake = time() - at;
    }

    // The wired uplink the tunnel would take: wan, or another port's or
    // VLAN's (pulzr-ports), whichever pulzr-wireguard-route found first.
    const wiredIface = route?.iface || 'wan';
    const wan = ifaceStatus(wiredIface), wwifi = ifaceStatus('wwifi'), cell = cellularStatus();
    const wiredDevice = route ? route.device : null;

    return {
        wired: {
            up: route ? route.wiredUsable : false,
            iface: route?.iface || null,
            device: wiredDevice,
            gateway: route ? route.gateway : null,
            address: wan.address,
            addresses: wan.addresses ?? [],
            proto: wan.proto,
            speed: linkSpeed(wiredDevice || wan.device),
        },
        wifi: {
            up: wwifi.up == true,
            device: wwifi.device,
            address: wwifi.address,
            addresses: wwifi.addresses ?? [],
        },
        tunnel: {
            // Deliberately restated on every response rather than assumed by
            // the UI: somebody will eventually ask why the tunnel dies when
            // ethernet does, and the answer should be in the payload.
            wiredOnly: true,
            note: 'The management tunnel runs over ethernet or WiFi only, so it '
                + 'can never bill cellular data.',
            configured: !!config,
            // wired, wifi, cellular or none: the path its packets leave on now.
            via: route ? route.via : 'none',
            // none: not enrolled yet. waiting: configured, the hub has not
            // answered recently. up: a handshake in the last three minutes.
            state: state,
            address: config ? config.address : null,
            endpoint: config ? config.endpoint : null,
            lastHandshake: lastHandshake,
        },
        cellular: {
            up: cell.up == true,
            device: cell.device,
            modem: modem(),
        },
    };
};

setCellular = function(req, session) {
    const uci = cursor();

    // An APN is the only thing worth exposing. Everything else about a 1NCE
    // SIM is fixed by the carrier, and a console that offers to change the PDP
    // type is a console that offers a way to strand a gateway.
    if (req.apn != null) {
        if (!match(req.apn, /^[A-Za-z0-9._-]{1,63}$/))
            return { error: 'That does not look like an APN.' };
        uci.set('network', 'wwan', 'apn', req.apn);
    }

    // Both cellular interfaces: "Use cellular as a backhaul" off means a
    // phone plugged in later is not used either.
    if (req.enabled != null) {
        uci.set('network', 'wwan', 'disabled', req.enabled ? '0' : '1');
        if (uci.get('network', 'usbwan'))
            uci.set('network', 'usbwan', 'disabled', req.enabled ? '0' : '1');
    }

    uci.commit('network');
    run('/sbin/ifup wwan >/dev/null 2>&1 &');
    if (uci.get('network', 'usbwan'))
        run('/sbin/ifup usbwan >/dev/null 2>&1 &');

    return { ok: true, applied: { apn: req.apn, enabled: req.enabled } };
};

// Which SIM the modem uses, on one with several holders. Kept in
// pulzr.cellular.sim_slot, so the apply window's snapshot can put the old one
// back if the new SIM cuts the gateway off (pulzr-modem-detect).
setSimSlot = function(req) {
    const slot = int(req.slot ?? 0);
    if (slot < 1 || slot > 9) return { error: 'A SIM slot number.' };
    return _m_util.tool('/usr/sbin/pulzr-modem-detect', ['--set-slot', sprintf('%d', slot)]);
};

// ── module exports ──────────────────────────────────────────────────────────
//
// A returned object, not `export` statements. uhttpd's ucode plugin compiles
// its handler in TEMPLATE mode and loads anything else through loadfile(),
// neither of which is module mode — `export` is a syntax error there. See the
// header of api/index.uc for the full contract.
return { backhaul, setCellular, setSimSlot, status };
