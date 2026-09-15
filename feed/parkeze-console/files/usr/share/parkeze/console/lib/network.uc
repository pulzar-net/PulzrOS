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
let run = _m_util.run;; let runJson = _m_util.runJson;; let ubus = _m_util.ubus;

function ifaceStatus(name) {
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
}

function status() {
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
            manageable: false,
            reason: 'Ethernet is the wired backhaul and is managed by '
                  + 'parkeze.net. Nothing routed is accepted from it — the '
                  + 'console and SSH answer only a directly connected machine.',
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
}

function modem() {
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
}

// Which management paths are actually working right now.
//
// This is the view parkeze.net cares about most and the one an operator on
// site checks first: not "is there internet" but "can we be managed, and over
// which path". The two paths fail independently and for different reasons, and
// conflating them into a single "online" light is how a gateway ends up
// looking healthy while being unmanageable.
function backhaul() {
    const tailscale = runJson('/usr/sbin/parkeze-tailscale-route status');
    const ts = runJson('tailscale --socket=/var/run/tailscale/tailscaled.sock status --json 2>/dev/null');

    return {
        wired: {
            up: tailscale ? tailscale.wiredUsable : false,
            device: tailscale ? tailscale.device : null,
            gateway: tailscale ? tailscale.gateway : null,
        },
        tailscale: {
            // Deliberately restated on every response rather than assumed by
            // the UI: somebody will eventually ask why the tunnel dies when
            // ethernet does, and the answer should be in the payload.
            wiredOnly: true,
            note: 'Tailscale is pinned to the wired uplink so it can never '
                + 'bill cellular data.',
            running: !!ts,
            state: ts ? ts.BackendState : 'Stopped',
            self: ts && ts.Self ? {
                hostname: ts.Self.HostName,
                addresses: ts.Self.TailscaleIPs,
                online: ts.Self.Online,
            } : null,
        },
        cellular: {
            up: ifaceStatus('wwan').up == true,
            modem: modem(),
        },
    };
}

function setCellular(req, session) {
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
}

// ── module exports ──────────────────────────────────────────────────────────
//
// A returned object, not `export` statements. uhttpd's ucode plugin compiles
// its handler in TEMPLATE mode and loads anything else through loadfile(),
// neither of which is module mode — `export` is a syntax error there. See the
// header of api/index.uc for the full contract.
return { backhaul, setCellular, status };
