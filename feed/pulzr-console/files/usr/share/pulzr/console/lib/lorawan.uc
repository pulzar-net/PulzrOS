// The LoRaWAN side: what is fitted, and whether it is working.

let _m_fs = require('fs');
let readfile = _m_fs.readfile;; let lsdir = _m_fs.lsdir;
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
let profile, supported, slotView, concentrator, setConcentrator, setSlot, detect, gps, syncGps, detectGps, setGpsSource, forwarders, status, restart, setBackhaul;

let run = _m_util.run;; let runJson = _m_util.runJson;

const PROFILE_DIR = '/usr/share/pulzr/concentrator';

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
    const get = (key) => uci.get('pulzr', section, key);

    const detected = get('detected');
    const override = get('override');
    const active = get('active');
    const prof = profile(active);

    return {
        index: index,
        bus: get('bus') || '',
        device: get('device') || '',
        // What was actually probed with last — informational, not editable.
        // reset_gpio_override is the operator's own choice, if they made one;
        // see setSlot for why the two cannot be the same field.
        resetGpio: get('reset_gpio') || '',
        powerGpio: get('power_gpio') || '',
        resetGpioOverride: get('reset_gpio_override') || '',
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
    const count = int(uci.get('pulzr', 'concentrator', 'slots') || '1');

    const slots = [];
    for (let i = 0; i < count; i++) slots[length(slots)] = slotView(uci, i);

    return {
        // 'partial' is its own state and not a rounding of 'present': a
        // 16-channel gateway running on one concentrator works, at half its
        // channel count, and nothing about the uplink counts makes that
        // obvious.
        status: uci.get('pulzr', 'concentrator', 'status') || 'unknown',
        slots: slots,
        slotCount: count,
        presentCount: int(uci.get('pulzr', 'concentrator', 'present') || '0'),
        channels: int(uci.get('pulzr', 'concentrator', 'channels') || '0'),
        // False on fixed-hardware boards. The device decides, not the UI.
        configurable: uci.get('pulzr', 'concentrator', 'configurable') != '0',
        supported: supported(),
        region: uci.get('pulzr', 'lorawan', 'region'),
    };
};

const REGIONS = /^(US915|EU868|AU915|AS923|IN865|KR920|RU864)$/;

setConcentrator = function(req, session) {
    const uci = cursor();

    if (req.region != null) {
        if (!match(req.region, REGIONS))
            return { error: 'Unknown region plan.' };
        uci.set('pulzr', 'lorawan', 'region', req.region);
        uci.commit('pulzr');
        restart();
    }

    return { ok: true, concentrator: concentrator() };
};

setSlot = function(index, req, session) {
    const uci = cursor();

    if (uci.get('pulzr', 'concentrator', 'configurable') == '0')
        return { error: "This board's concentrators are fixed in hardware." };

    const section = sprintf('slot%d', index);
    if (!uci.get('pulzr', section))
        return { error: sprintf('This gateway has no slot %d.', index) };

    if (req.override != null) {
        // Empty clears the override and returns to whatever the probe finds —
        // the only way back from a wrong manual choice, so it must be
        // reachable from the UI.
        if (req.override == '') {
            uci.delete('pulzr', section, 'override');
        } else {
            if (!profile(req.override))
                return { error: 'This build ships no profile for that part.' };
            uci.set('pulzr', section, 'override', req.override);
        }
    }

    if (req.bus != null) {
        if (req.bus != '' && !match(req.bus, /^(spi|usb|uart)$/))
            return { error: 'Bus must be spi, usb or uart.' };
        uci.set('pulzr', section, 'bus', req.bus);
    }

    if (req.device != null) {
        // A device node, not an arbitrary path: this ends up in a config file
        // the packet forwarder opens, and it comes from a form.
        if (req.device != '' && !match(req.device, /^\/dev\/[A-Za-z0-9._-]{1,32}$/))
            return { error: 'That does not look like a device node.' };
        uci.set('pulzr', section, 'device', req.device);
    }

    if (req.resetGpio != null) {
        if (req.resetGpio != '' && !match(req.resetGpio, /^[0-9]{1,3}$/))
            return { error: 'A GPIO line is a number.' };
        // A separate field from reset_gpio, which detection overwrites on
        // every run with whatever it actually probed — writing there directly
        // meant this box was cosmetic, on every board, from the day it
        // shipped: the very next detect() call this handler makes below
        // replaced it with the auto value regardless of what was just typed.
        // Empty clears it and returns to the profile's own pins, matching how
        // `override` clears back to automatic.
        if (req.resetGpio == '')
            uci.delete('pulzr', section, 'reset_gpio_override');
        else
            uci.set('pulzr', section, 'reset_gpio_override', req.resetGpio);
    }

    uci.commit('pulzr');
    detect();
    restart();

    return { ok: true, concentrator: concentrator() };
};

detect = function() {
    run('/usr/sbin/pulzr-concentrator-detect >/dev/null 2>&1');
    return { ok: true, concentrator: concentrator() };
};

// GNSS position and fix state.
//
// Whether this reads the receiver directly or a cached position depends on
// whether the packet forwarder is holding the serial port — pulzr-gps
// handles that, and the `source` field in the reply says which happened, so
// the console can be honest about how fresh the coordinate is.
gps = function() {
    const state = runJson('/usr/sbin/pulzr-gps status');
    if (!state) return { present: false, fix: false,
                         reason: 'GNSS subsystem is not responding.' };

    const uci = cursor();
    // The recorded reference position, which is what gets reported to the
    // network server when there is no live fix. Shown beside the live one so
    // it is obvious which of the two a gateway is actually announcing.
    state.reference = {
        latitude: uci.get('pulzr', 'location', 'latitude'),
        longitude: uci.get('pulzr', 'location', 'longitude'),
        altitude: uci.get('pulzr', 'location', 'altitude'),
        source: uci.get('pulzr', 'location', 'source'),
        fixedAt: uci.get('pulzr', 'location', 'fixed_at'),
    };

    // Where the position comes from, and what there is to choose between.
    // pulzr-gps's header describes each source.
    state.config = {
        source: uci.get('pulzr', 'gps', 'source') || 'auto',
        slot: int(uci.get('pulzr', 'gps', 'slot') || '0'),
        device: uci.get('pulzr', 'gps', 'source_device') || '',
        baud: int(uci.get('pulzr', 'gps', 'source_baud') || '9600'),
    };
    const count = int(uci.get('pulzr', 'concentrator', 'slots') || '1');
    const slots = [];
    for (let i = 0; i < count; i++)
        slots[length(slots)] = {
            index: i,
            status: uci.get('pulzr', sprintf('slot%d', i), 'status') || 'unknown',
        };
    state.options = {
        modem: uci.get('pulzr', 'cellular', 'gps_capable') == '1',
        slots: slots,
    };
    return state;
};

const GPS_SOURCES = /^(auto|modem|concentrator|device)$/;
const GPS_BAUDS = [4800, 9600, 19200, 38400, 57600, 115200];

// Choose where the gateway's position comes from.
//
// Detection runs straight away so the answer reflects the new choice, and the
// LoRa stack restarts because which concentrator holds the receiver is fixed
// when its config is rendered. The recorded position is refreshed from the new
// source when it has a fix; when it has none the old one stands, because a
// gateway reporting no position at all is worse than one reporting yesterday's.
setGpsSource = function(req) {
    if (!match(req.source ?? '', GPS_SOURCES))
        return { error: 'Unknown GNSS source.' };

    const uci = cursor();
    const count = int(uci.get('pulzr', 'concentrator', 'slots') || '1');

    if (req.source == 'concentrator') {
        const slot = int(req.slot ?? -1);
        if (slot < 0 || slot >= count)
            return { error: sprintf('This gateway has concentrators 1 to %d.', count) };
        uci.set('pulzr', 'gps', 'slot', sprintf('%d', slot));
    }

    if (req.source == 'device') {
        if (!match(req.device ?? '', /^\/dev\/tty[A-Za-z0-9._-]{1,24}$/))
            return { error: 'Give the receiver as a serial device, like /dev/ttyUSB0.' };
        for (let i = 0; i < count; i++)
            if (uci.get('pulzr', sprintf('slot%d', i), 'device') == req.device)
                return { error: sprintf('%s is concentrator %d.', req.device, i + 1) };
        const baud = int(req.baud ?? 9600);
        if (index(GPS_BAUDS, baud) < 0)
            return { error: 'Unsupported baud rate.' };
        uci.set('pulzr', 'gps', 'source_device', req.device);
        uci.set('pulzr', 'gps', 'source_baud', sprintf('%d', baud));
    }

    if (req.source == 'modem' && uci.get('pulzr', 'cellular', 'gps_capable') != '1')
        return { error: 'The modem has no GNSS.' };

    uci.set('pulzr', 'gps', 'gps');
    uci.set('pulzr', 'gps', 'source', req.source);
    uci.commit('pulzr');

    run('/usr/sbin/pulzr-gps-detect >/dev/null 2>&1');
    run('(/usr/sbin/pulzr-gps sync; /etc/init.d/pulzr-packet-forwarder restart) >/dev/null 2>&1 &');
    return { ok: true, gps: gps() };
};

// Freeze the current fix as the gateway's reference coordinates.
//
// The install-time action: a gateway on a roof gets a fix once, and from then
// on reports that position whether or not the receiver has sky view on any
// given boot.
syncGps = function() {
    const output = run('/usr/sbin/pulzr-gps sync 2>&1');
    if (output == null)
        return { error: 'No fix yet, so there is nothing to record. Check the '
                      + 'antenna has a clear view of the sky.' };
    return { ok: true, message: output, gps: gps() };
};

detectGps = function() {
    run('/usr/sbin/pulzr-gps-detect >/dev/null 2>&1');
    return { ok: true, gps: gps() };
};

// Each concentrator slot's pair — concentratord and its MQTT forwarder — as one
// forwarder. They start, stop and fail together, and a second slot is a second
// gateway as far as the network server is concerned.
forwarders = function() {
    const uci = cursor();
    const count = int(uci.get('pulzr', 'concentrator', 'slots') || '1');
    const service = runJson('ubus call service list \'{"name":"pulzr-packet-forwarder"}\'') || {};
    const instances = (service['pulzr-packet-forwarder'] || {}).instances || {};

    const gpsSource = uci.get('pulzr', 'gps', 'source') || 'auto';
    const gpsSlot = (gpsSource == 'auto' || gpsSource == 'concentrator')
        ? int(uci.get('pulzr', 'gps', 'slot') || '0') : -1;
    const gpsPresent = uci.get('pulzr', 'gps', 'status') == 'present';

    const list = [];
    for (let i = 0; i < count; i++) {
        const radio = instances[sprintf('concentratord%d', i)];
        const bridge = instances[sprintf('forwarder%d', i)];
        const running = !!(radio && radio.running);
        const stats = running
            ? runJson(sprintf('/usr/sbin/pulzr-forwarder-stats --slot %d 2>/dev/null', i))
            : null;
        const attached = i == gpsSlot && gpsPresent;

        list[length(list)] = {
            index: i,
            slot: slotView(uci, i),
            running: running,
            forwarding: !!(bridge && bridge.running),
            // Slot 0 carries the gateway's EUI; another slot uses its chip's
            // own, which only concentratord can read.
            gatewayId: i == 0 ? uci.get('pulzr', 'identity', 'gateway_eui') : null,
            mqtt: trim(readfile(sprintf('/var/run/pulzr/lora/slot%d.mqtt', i)) || '') || null,
            stats: stats ? {
                received: stats.rx_received,
                forwarded: stats.rx_forwarded,
                transmitted: stats.tx_emitted,
                crcOkPercent: stats.crc_ok_percent,
                lastUplink: stats.last_uplink || null,
            } : null,
            gnss: {
                attached: attached,
                device: attached ? uci.get('pulzr', 'gps', 'device') : null,
            },
        };
    }

    return {
        region: uci.get('pulzr', 'lorawan', 'region'),
        mqtt: {
            host: uci.get('pulzr', 'mqtt', 'host'),
            port: int(uci.get('pulzr', 'mqtt', 'port') || '8883'),
            topicPrefix: uci.get('pulzr', 'mqtt', 'topic_prefix'),
            username: uci.get('pulzr', 'mqtt', 'username'),
            // What the forwarder was actually pointed at, not the setting:
            // the setting is on by default and does nothing without an SD
            // card, and pulzr-lora-config decides by this same file.
            buffered: length(readfile('/var/run/pulzr/lora/mosquitto.conf') ?? '') > 0,
        },
        location: {
            latitude: uci.get('pulzr', 'location', 'latitude'),
            longitude: uci.get('pulzr', 'location', 'longitude'),
            altitude: uci.get('pulzr', 'location', 'altitude'),
            source: uci.get('pulzr', 'location', 'source'),
        },
        forwarders: list,
    };
};

status = function() {
    const uci = cursor();
    const stats = runJson('/usr/sbin/pulzr-forwarder-stats 2>/dev/null');
    const running = run('/etc/init.d/pulzr-packet-forwarder running >/dev/null 2>&1 && echo yes');
    const buffer = runJson('/usr/sbin/pulzr-lora-buffer status 2>/dev/null');

    return {
        gatewayEui: uci.get('pulzr', 'identity', 'gateway_eui'),
        region: uci.get('pulzr', 'lorawan', 'region'),
        concentrator: {
            status: uci.get('pulzr', 'concentrator', 'status') || 'unknown',
            slots: int(uci.get('pulzr', 'concentrator', 'slots') || '1'),
            present: int(uci.get('pulzr', 'concentrator', 'present') || '0'),
            channels: int(uci.get('pulzr', 'concentrator', 'channels') || '0'),
        },
        forwarder: {
            running: running == 'yes',
            // Received and forwarded are never summed. They answer different
            // questions with different fixes — see pulzr-forwarder-stats.
            received: stats ? stats.rx_received : null,
            forwarded: stats ? stats.rx_forwarded : null,
            transmitted: stats ? stats.tx_emitted : null,
            crcOkPercent: stats ? stats.crc_ok_percent : null,
            lastUplink: stats ? stats.last_uplink : null,
        },
        bridge: {
            // Buffered, the forwarder's own connection is to loopback and is
            // up whenever the local broker is, so the broker's bridge is what
            // says whether uplinks reach the LNS. Otherwise the forwarder's
            // connect and connection-error callbacks (pulzr-lora-config).
            connected: buffer && buffer.bridgeUp != null
                ? buffer.bridgeUp
                : run('cat /var/run/pulzr/lora/slot0.mqtt 2>/dev/null') == 'connected',
            broker: uci.get('pulzr', 'mqtt', 'host'),
        },
        // Whether uplinks may use the metered link, and whether they are
        // getting out right now. Distinct from bridge.connected: a gateway
        // confined to wired with wired down is deliberately not sending, and
        // that reads very differently from a broker it cannot reach.
        backhaul: runJson('/usr/sbin/pulzr-lora-route status 2>/dev/null'),
        // What happens to uplinks that cannot be sent: held, or dropped. It
        // belongs next to backhaul because it is what decides whether
        // backhaul.sending == false is a delay or a hole in the data.
        buffer: buffer,
    };
};

// Whether uplinks may fail over to cellular, and what happens to them when
// they cannot go. Per gateway: whether a metered uplink is worth it is a
// property of the site, not of the board.
setBackhaul = function(req, session) {
    if (req.allowCellular == null && req.buffer == null)
        return { error: 'Nothing to change.' };

    const uci = cursor();
    if (req.allowCellular != null)
        uci.set('pulzr', 'lorawan', 'allow_cellular', req.allowCellular ? '1' : '0');
    if (req.buffer != null)
        uci.set('pulzr', 'lorawan', 'buffer', req.buffer ? '1' : '0');
    uci.commit('pulzr');

    // Applied now rather than at the next ifup, so the setting takes effect
    // while whoever changed it is still looking at the page.
    run('/usr/sbin/pulzr-lora-route apply');

    // Buffering changes where the forwarder publishes, which is rendered
    // config — so it needs a restart, where allow_cellular does not. Costs a
    // few seconds of uplinks, which is why it is not done unconditionally.
    if (req.buffer != null)
        run('/etc/init.d/pulzr-packet-forwarder restart >/dev/null 2>&1 &');

    return {
        ok: true,
        backhaul: runJson('/usr/sbin/pulzr-lora-route status 2>/dev/null'),
        buffer: runJson('/usr/sbin/pulzr-lora-buffer status 2>/dev/null'),
    };
};

restart = function() {
    run('/etc/init.d/pulzr-packet-forwarder restart >/dev/null 2>&1 &');
    return { ok: true, message: 'Packet forwarder restarting.' };
};

// ── module exports ──────────────────────────────────────────────────────────
//
// A returned object, not `export` statements. uhttpd's ucode plugin compiles
// its handler in TEMPLATE mode and loads anything else through loadfile(),
// neither of which is module mode — `export` is a syntax error there. See the
// header of api/index.uc for the full contract.
return { concentrator, detect, detectGps, forwarders, gps, restart, setBackhaul, setConcentrator, setGpsSource, setSlot, status, supported, syncGps };
