// The LoRaWAN side: what is fitted, and whether it is working.

let _m_fs = require('fs');
let readfile = _m_fs.readfile;; let lsdir = _m_fs.lsdir;
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
let profile, supported, slotView, concentrator, setConcentrator, setSlot, detect, gps, syncGps, detectGps, status, restart;

let run = _m_util.run;; let runJson = _m_util.runJson;

const PROFILE_DIR = '/usr/share/parkeze/concentrator';

profile = function(id) {
    if (!id) return null;
    const raw = readfile(sprintf('%s/%s.json', PROFILE_DIR, id));
    if (!raw) return null;
    try { return json(raw); } catch (e) { return null; }
};

// Every concentrator this build can drive, for the console's hardware menu.
//
// Read from the filesystem rather than hardcoded, so adding a profile JSON to
// the package is the whole of adding support for a part — no console change,
// no rebuild of the SPA.
supported = function() {
    const out = [];
    for (let name in (lsdir(PROFILE_DIR) || [])) {
        if (!match(name, /\.json$/)) continue;
        const id = replace(name, /\.json$/, '');
        const p = profile(id);
        if (!p) continue;
        out[length(out)] = {
            id: id,
            name: p.name,
            chip: p.chip,
            interface: p.interface,
            knownAs: p.known_as,
            // UART parts cannot be probed — see sx130x_probe. Surfaced so the
            // menu can say so rather than letting somebody select one and
            // wonder why detection disagrees.
            detectable: p.interface != 'uart',
        };
    }
    return out;
};

slotView = function(uci, index) {
    const section = sprintf('slot%d', index);
    const get = (key) => uci.get('parkeze', section, key);

    const detected = get('detected');
    const override = get('override');
    const active = get('active');
    const prof = profile(active);

    return {
        index: index,
        bus: get('bus') || '',
        device: get('device') || '',
        resetGpio: get('reset_gpio') || '',
        powerGpio: get('power_gpio') || '',
        status: get('status') || 'unknown',
        detected: detected || null,
        override: override || null,
        active: active || null,
        profile: prof,
        // An override that disagrees with the hardware is legitimate — it is
        // how you drive a UART part, or work around a bad probe — but it is
        // also the first thing to suspect when a slot hears nothing.
        mismatch: !!(override && detected && override != detected),
        channels: prof ? prof.channels : 0,
    };
};

concentrator = function() {
    const uci = cursor();
    const count = int(uci.get('parkeze', 'concentrator', 'slots') || '1');

    const slots = [];
    for (let i = 0; i < count; i++) slots[length(slots)] = slotView(uci, i);

    return {
        // 'partial' is its own state and not a rounding of 'present': a
        // 16-channel gateway running on one concentrator works, at half its
        // channel count, and nothing about the uplink counts makes that
        // obvious.
        status: uci.get('parkeze', 'concentrator', 'status') || 'unknown',
        slots: slots,
        slotCount: count,
        presentCount: int(uci.get('parkeze', 'concentrator', 'present') || '0'),
        channels: int(uci.get('parkeze', 'concentrator', 'channels') || '0'),
        // False on fixed-hardware boards. The device decides, not the UI.
        configurable: uci.get('parkeze', 'concentrator', 'configurable') != '0',
        supported: supported(),
        region: uci.get('parkeze', 'lorawan', 'region'),
    };
};

const REGIONS = /^(US915|EU868|AU915|AS923|IN865|KR920|RU864)$/;

setConcentrator = function(req, session) {
    const uci = cursor();

    if (req.region != null) {
        if (!match(req.region, REGIONS))
            return { error: 'Unknown region plan.' };
        uci.set('parkeze', 'lorawan', 'region', req.region);
        uci.commit('parkeze');
        restart();
    }

    return { ok: true, concentrator: concentrator() };
};

setSlot = function(index, req, session) {
    const uci = cursor();

    if (uci.get('parkeze', 'concentrator', 'configurable') == '0')
        return { error: "This board's concentrators are fixed in hardware." };

    const section = sprintf('slot%d', index);
    if (!uci.get('parkeze', section))
        return { error: sprintf('This gateway has no slot %d.', index) };

    if (req.override != null) {
        // Empty clears the override and returns to whatever the probe finds —
        // the only way back from a wrong manual choice, so it must be
        // reachable from the UI.
        if (req.override == '') {
            uci.delete('parkeze', section, 'override');
        } else {
            if (!profile(req.override))
                return { error: 'This build ships no profile for that part.' };
            uci.set('parkeze', section, 'override', req.override);
        }
    }

    if (req.bus != null) {
        if (req.bus != '' && !match(req.bus, /^(spi|usb|uart)$/))
            return { error: 'Bus must be spi, usb or uart.' };
        uci.set('parkeze', section, 'bus', req.bus);
    }

    if (req.device != null) {
        // A device node, not an arbitrary path: this ends up in a config file
        // the packet forwarder opens, and it comes from a form.
        if (req.device != '' && !match(req.device, /^\/dev\/[A-Za-z0-9._-]{1,32}$/))
            return { error: 'That does not look like a device node.' };
        uci.set('parkeze', section, 'device', req.device);
    }

    if (req.resetGpio != null) {
        if (req.resetGpio != '' && !match(req.resetGpio, /^[0-9]{1,3}$/))
            return { error: 'A GPIO line is a number.' };
        uci.set('parkeze', section, 'reset_gpio', req.resetGpio);
    }

    uci.commit('parkeze');
    detect();
    restart();

    return { ok: true, concentrator: concentrator() };
};

detect = function() {
    run('/usr/sbin/parkeze-concentrator-detect >/dev/null 2>&1');
    return { ok: true, concentrator: concentrator() };
};

// GNSS position and fix state.
//
// Whether this reads the receiver directly or a cached position depends on
// whether the packet forwarder is holding the serial port — parkeze-gps
// handles that, and the `source` field in the reply says which happened, so
// the console can be honest about how fresh the coordinate is.
gps = function() {
    const state = runJson('/usr/sbin/parkeze-gps status');
    if (!state) return { present: false, fix: false,
                         reason: 'GNSS subsystem is not responding.' };

    const uci = cursor();
    // The recorded reference position, which is what gets reported to the
    // network server when there is no live fix. Shown beside the live one so
    // it is obvious which of the two a gateway is actually announcing.
    state.reference = {
        latitude: uci.get('parkeze', 'location', 'latitude'),
        longitude: uci.get('parkeze', 'location', 'longitude'),
        altitude: uci.get('parkeze', 'location', 'altitude'),
        source: uci.get('parkeze', 'location', 'source'),
        fixedAt: uci.get('parkeze', 'location', 'fixed_at'),
    };
    return state;
};

// Freeze the current fix as the gateway's reference coordinates.
//
// The install-time action: a gateway on a roof gets a fix once, and from then
// on reports that position whether or not the receiver has sky view on any
// given boot.
syncGps = function() {
    const output = run('/usr/sbin/parkeze-gps sync 2>&1');
    if (output == null)
        return { error: 'No fix yet, so there is nothing to record. Check the '
                      + 'antenna has a clear view of the sky.' };
    return { ok: true, message: output, gps: gps() };
};

detectGps = function() {
    run('/usr/sbin/parkeze-gps-detect >/dev/null 2>&1');
    return { ok: true, gps: gps() };
};

status = function() {
    const uci = cursor();
    const stats = runJson('/usr/sbin/parkeze-forwarder-stats 2>/dev/null');
    const running = run('/etc/init.d/parkeze-packet-forwarder running >/dev/null 2>&1 && echo yes');

    return {
        gatewayEui: uci.get('parkeze', 'identity', 'gateway_eui'),
        region: uci.get('parkeze', 'lorawan', 'region'),
        concentrator: {
            status: uci.get('parkeze', 'concentrator', 'status') || 'unknown',
            slots: int(uci.get('parkeze', 'concentrator', 'slots') || '1'),
            present: int(uci.get('parkeze', 'concentrator', 'present') || '0'),
            channels: int(uci.get('parkeze', 'concentrator', 'channels') || '0'),
        },
        forwarder: {
            running: running == 'yes',
            // Received and forwarded are never summed. They answer different
            // questions with different fixes — see parkeze-forwarder-stats.
            received: stats ? stats.rx_received : null,
            forwarded: stats ? stats.rx_forwarded : null,
            transmitted: stats ? stats.tx_emitted : null,
            crcOkPercent: stats ? stats.crc_ok_percent : null,
            lastUplink: stats ? stats.last_uplink : null,
        },
        bridge: {
            // Written by mqtt-forwarder's connect and connection-error
            // callbacks; see parkeze-lora-config.
            connected: run('cat /var/run/parkeze/lora/slot0.mqtt 2>/dev/null') == 'connected',
            broker: uci.get('parkeze', 'mqtt', 'host'),
        },
    };
};

restart = function() {
    run('/etc/init.d/parkeze-packet-forwarder restart >/dev/null 2>&1 &');
    return { ok: true, message: 'Packet forwarder restarting.' };
};

// ── module exports ──────────────────────────────────────────────────────────
//
// A returned object, not `export` statements. uhttpd's ucode plugin compiles
// its handler in TEMPLATE mode and loads anything else through loadfile(),
// neither of which is module mode — `export` is a syntax error there. See the
// header of api/index.uc for the full contract.
return { concentrator, detect, detectGps, gps, restart, setConcentrator, setSlot, status, supported, syncGps };
