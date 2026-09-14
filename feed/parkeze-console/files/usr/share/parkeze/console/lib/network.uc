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

import { readfile } from 'fs';
import { cursor } from 'uci';
import { run, runJson, ubus } from './util.uc';

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

export function status() {
    const uci = cursor();
    return {
        lan: ifaceStatus('lan'),
        wan: {
            // `manageable: false` is the contract with the console: render it,
            // grey it out, offer no controls. The UI does not decide this — if
            // a wired board ever should be operator-configurable, it changes
            // here and in board.conf, in one place, not in a React component.
            manageable: false,
            reason: 'Ethernet WAN is managed by parkeze.net on this gateway.',
            enabled: uci.get('network', 'wan', 'disabled') != '1',
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
    // uqmi against the QMI control device. Absent modem is a normal state —
    // a wired-only board has none — so this returns null rather than erroring.
    const dev = '/dev/cdc-wdm0';
    if (!readfile('/sys/class/net') && !dev) return null;

    const signal = runJson(sprintf('uqmi -d %s --get-signal-info 2>/dev/null', dev));
    const serving = runJson(sprintf('uqmi -d %s --get-serving-system 2>/dev/null', dev));
    if (!signal && !serving) return null;

    return {
        registration: serving ? serving.registration : null,
        network:      serving ? serving.plmn_description : null,
        technology:   signal ? signal.type : null,
        rssi:         signal ? signal.rssi : null,
        rsrp:         signal ? signal.rsrp : null,
        snr:          signal ? signal.snr : null,
    };
}

// Which management paths are actually working right now.
//
// This is the view parkeze.net cares about most and the one an operator on
// site checks first: not "is there internet" but "can we be managed, and over
// which path". The two paths fail independently and for different reasons, and
// conflating them into a single "online" light is how a gateway ends up
// looking healthy while being unmanageable.
export function backhaul() {
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

export function setCellular(req, session) {
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
