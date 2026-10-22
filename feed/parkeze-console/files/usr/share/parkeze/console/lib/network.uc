// Network and backhaul state.
//
// The console's job here is narrower than LuCI's on purpose. A Parkeze gateway
// has exactly two uplinks and one of them is not the operator's to configure:
//
//   ethernet   present, usually disabled, and NOT exposed in the UI. See
//              parkeze-base's 20-parkeze-network for the reasoning. This module
//              reports its state so the console can *show* it, and offers no
//              way to change it.
//
//   cellular   the default backhaul. Configurable, because an APN is a
//              site-by-site fact and waiting on parkeze.net to push one to a
//              gateway that has no working backhaul is circular.

let _m_fs = require('fs');
let readfile = _m_fs.readfile;
let _m_uci = require('uci');
let cursor = _m_uci.cursor;
let _m_util = loadfile('/usr/share/parkeze/console/lib/util.uc', { raw_mode: true })();

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
let ifaceStatus, status, modem, backhaul, setCellular, setEthernet, ipv4, maskToPrefix;

let run = _m_util.run;; let runJson = _m_util.runJson;; let ubus = _m_util.ubus;

ifaceStatus = function(name) {
    const status = ubus(sprintf('network.interface.%s', name), 'status');
    if (!status) return { configured: false };

    let address = null, gateway = null;
    for (let a in (status['ipv4-address'] ? status['ipv4-address'] : []))
        address = sprintf('%s/%d', a.address, a.mask);
    for (let r in (status.route ? status.route : []))
        if (r.target == '0.0.0.0' && r.mask == 0) gateway = r.nexthop;

    return {
        configured: true,
        up: !!status.up,
        available: !!status.available,
        device: status.l3_device,
        proto: status.proto,
        address: address,
        gateway: gateway,
        uptime: status.uptime,
    };
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
        wan: {
            // `manageable: false` is the contract with the console: render it,
            // grey it out, offer no controls. The UI does not decide this — if
            // a wired board ever should be operator-configurable, it changes
            // here and in board.conf, in one place, not in a React component.
            // Editable now. It used to be read-only on the grounds that the
            // uplink was Parkeze's to decide — but a site whose network needs
            // a static address is a site where the gateway cannot come up at
            // all until somebody standing there says so, and that somebody
            // has no other way to do it. Only `wan` is touched; the console
            // addresses on the same port are separate interfaces and stay put.
            manageable: true,
            reason: null,
            mode: uci.get('network', 'wan', 'proto') == 'static' ? 'static' : 'dhcp',
            staticAddress: uci.get('network', 'wan', 'ipaddr'),
            staticNetmask: uci.get('network', 'wan', 'netmask'),
            staticGateway: uci.get('network', 'wan', 'gateway'),
            dns: uci.get('network', 'wan', 'dns') ?? [],
            // Always on. The port has no off switch because switching it off
            // would also take away local access, which is the one thing that
            // has to keep working.
            enabled: true,
            ...ifaceStatus('wan'),
        },
        cellular: {
            manageable: true,
            enabled: uci.get('network', 'wwan', 'disabled') != '1',
            apn: uci.get('network', 'wwan', 'apn'),
            ...ifaceStatus('wwan'),
            modem: modem(),
        },
    };
};

modem = function() {
    // mmcli, not uqmi: OpenWrt 24.10 ships no uqmi and cellular now goes
    // through ModemManager. An absent modem is a normal state — a wired-only
    // board has none — so this returns null rather than erroring.
    const found = runJson('/usr/sbin/parkeze-modem-detect --status');
    if (!found || !found.present) return null;

    // `mmcli --output-keyvalue` is the stable machine-readable form; the human
    // output reflows between releases and is not worth parsing.
    const raw = run(sprintf('mmcli -m %d --output-keyvalue 2>/dev/null', found.index));
    if (!raw) return { model: found.model, registration: null };

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
        model: found.model,
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
// This is the view parkeze.net cares about most and the one an operator on
// site checks first: not "is there internet" but "can we be managed, and over
// which path". The two paths fail independently and for different reasons, and
// conflating them into a single "online" light is how a gateway ends up
// looking healthy while being unmanageable.
backhaul = function() {
    const route = runJson('/usr/sbin/parkeze-wireguard-route status');
    const config = runJson('cat /etc/parkeze/wireguard/tunnel.json 2>/dev/null');
    const state = run('/usr/sbin/parkeze-backhaul-check --tunnel') || 'none';

    // Seconds since the hub last completed a handshake, from the kernel.
    let lastHandshake = null;
    const handshakes = run('wg show wg0 latest-handshakes 2>/dev/null');
    if (handshakes) {
        const at = int(split(handshakes, /\s+/)[1]);
        if (at > 0) lastHandshake = time() - at;
    }

    return {
        wired: {
            up: route ? route.wiredUsable : false,
            device: route ? route.device : null,
            gateway: route ? route.gateway : null,
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
            up: ifaceStatus('wwan').up == true,
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

    if (req.enabled != null)
        uci.set('network', 'wwan', 'disabled', req.enabled ? '0' : '1');

    uci.commit('network');
    run('/sbin/ifup wwan >/dev/null 2>&1 &');

    return { ok: true, applied: { apn: req.apn, enabled: req.enabled } };
};

// A dotted IPv4 address as four octets, or null.
ipv4 = function(text) {
    const m = match(text ?? '', /^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$/);
    if (!m) return null;
    const octets = [ int(m[1]), int(m[2]), int(m[3]), int(m[4]) ];
    for (let o in octets) if (o > 255) return null;
    return octets;
};

// 255.255.255.0 -> 24, or null for a mask that is not contiguous.
maskToPrefix = function(text) {
    const o = ipv4(text);
    if (!o) return null;
    let bits = 0, ended = false;
    for (let octet in o)
        for (let i = 7; i >= 0; i--) {
            const on = (octet >> i) & 1;
            if (on && ended) return null;
            if (on) bits++; else ended = true;
        }
    return bits;
};

// The wired uplink: DHCP, or a static address for a site that needs one.
//
// Only `network.wan`. The console (192.168.61.1) and link-local addresses live
// on the same port as separate interfaces and are never touched here, so the
// technician making this change keeps their connection to the console whatever
// they type. That is also why there is no timed rollback: the person who can
// fix a wrong address is still connected.
//
// The management tunnel follows on its own. Bringing wan up fires its hotplug
// handler, which restarts it over the new route, and the report service's,
// which tells Parkeze the gateway is now wired.
setEthernet = function(req, session) {
    const uci = cursor();

    if (req.mode == 'dhcp') {
        uci.set('network', 'wan', 'proto', 'dhcp');
        for (let key in [ 'ipaddr', 'netmask', 'gateway', 'dns' ])
            uci.delete('network', 'wan', key);
    }
    else if (req.mode == 'static') {
        const address = ipv4(req.address);
        const prefix = maskToPrefix(req.netmask);
        const gateway = ipv4(req.gateway);
        if (!address) return { error: 'The address is not a valid IPv4 address.' };
        if (prefix == null || prefix < 1 || prefix > 30)
            return { error: 'The netmask is not valid.' };
        if (!gateway) return { error: 'The gateway is not a valid IPv4 address.' };

        // The console's own subnets. An uplink address inside either would
        // shadow the address the technician is using to reach this page.
        if ((address[0] == 192 && address[1] == 168 && address[2] == 61) ||
            (address[0] == 169 && address[1] == 254))
            return { error: 'That address overlaps the console network '
                          + '(192.168.61.0/24 or 169.254.0.0/16).' };

        // The gateway has to be reachable on the subnet the address is in, or
        // the uplink comes up with no route out.
        const mask = ipv4(req.netmask);
        for (let i = 0; i < 4; i++)
            if ((address[i] & mask[i]) != (gateway[i] & mask[i]))
                return { error: 'The gateway is not on the same subnet as the address.' };

        const dns = [];
        for (let server in (type(req.dns) == 'array' ? req.dns : [])) {
            if (!length(trim(server ?? ''))) continue;
            if (!ipv4(trim(server))) return { error: sprintf('%s is not a valid DNS server.', server) };
            push(dns, trim(server));
        }
        if (length(dns) > 3) return { error: 'At most three DNS servers.' };

        uci.set('network', 'wan', 'proto', 'static');
        uci.set('network', 'wan', 'ipaddr', trim(req.address));
        uci.set('network', 'wan', 'netmask', trim(req.netmask));
        uci.set('network', 'wan', 'gateway', trim(req.gateway));
        if (length(dns)) uci.set('network', 'wan', 'dns', dns);
        else uci.delete('network', 'wan', 'dns');
    }
    else {
        return { error: 'Mode must be dhcp or static.' };
    }

    uci.commit('network');
    // reload, not restart: netifd re-reads the config and bounces only the
    // interface that changed, so the console address never drops.
    run('ubus call network reload >/dev/null 2>&1');
    return { ok: true, mode: req.mode };
};

// ── module exports ──────────────────────────────────────────────────────────
//
// A returned object, not `export` statements. uhttpd's ucode plugin compiles
// its handler in TEMPLATE mode and loads anything else through loadfile(),
// neither of which is module mode — `export` is a syntax error there. See the
// header of api/index.uc for the full contract.
return { backhaul, setCellular, setEthernet, status };
