// The WiFi radios: what each one is, what runs on it, and what may be changed.
//
// A radio is a UCI wifi-device; what runs on it is its wifi-ifaces. Three
// kinds belong to somebody already and keep their owner:
//
//   pulzr_sta       the WiFi uplink, access.uc's (the join flow, saved
//                   networks, roaming, the captive portal). Joined onto a
//                   radio here, written by access.joinWifi.
//   pulzr_sta2      a second WiFi uplink, on another radio, onto the same
//                   network or another one (interface wwifi2). This page's:
//                   joined and removed here, written by access.joinWifi with
//                   its own slot. No roaming and no portal sign-in.
//   pulzr_setup_ap  the setup AP, pulzr-ap's. Read here, never written.
//   pulzr_ap_<n>    access points made here: an SSID onto a LAN-side network.
//
// Anything else on a radio was put there by hand, or is OpenWrt's stock open
// AP that 60-pulzr-ap deletes. It is shown for what it is and not offered for
// editing; the next join or setup AP removes it anyway.
//
// ── WHAT THE HARDWARE ALLOWS ───────────────────────────────────────────────
//
// From `iw phy <phy> info`, not from a table of chips: the channels the
// regulatory domain leaves open on this unit, the widths the radio does, and
// its interface combinations. The combinations are what decide a repeater. A
// MediaTek radio takes a station and several APs at once; a Pi 3's takes one
// station and one AP, on one channel; some take a station or an AP, never
// both. A change the kernel would refuse is refused here instead, with the
// reason, rather than written and left for hostapd to fail on quietly.
//
// `#channels <= 1` with a station and an AP on one radio means the AP is on
// whatever channel the upstream network is on: the station decides, and a
// channel set on that radio is ignored while it is joined. The status says so
// (sharedChannel) and the console shows the channel as following the uplink.
//
// ── CHANGING THE UPLINK'S RADIO, WITHOUT A GAP ─────────────────────────────
//
// Moving the uplink to another radio used to rewrite pulzr_sta's device.
// The old radio let go of the network at the reload, and for the ten seconds
// the new one took to associate and get a lease the gateway had no uplink:
// the tunnel moved to none and back. So a join on a radio with no station,
// while another radio's station is up, is a second station instead
// (pulzr_sta2), and the old one carries the traffic while it joins:
//
//   1. the new station is written beside the old one, held behind every
//      uplink (access.applyNetwork), and only its radio restarts
//   2. pulzr-wifi-uplink proves it reaches the internet, from its own
//      device (35-pulzr-wifi-uplink, and handover() asks again)
//   3. handover() puts it where the old one is in the uplink order, which
//      moves the default route, and pulzr-uplinks re-homes the tunnel and
//      LoRa with one route replace each, the old radio still associated
//   4. the old station stays, behind it, as the next uplink to fail over to
//
// When step 2 does not come within HANDOVER_WAIT, the new station is removed
// again and the record says why, for the console. Nothing about the old one
// was ever changed. Two slots, so at most two WiFi uplinks: one per radio on
// every board this runs on.
//
// ── APPLYING ───────────────────────────────────────────────────────────────
//
// Every setter here can take the caller's own connection with it: a channel
// change drops every client of that radio for a moment, and the uplink moved
// to the wrong radio is the tunnel gone. The API arms pulzr-apply's window
// around each one (apply.guard), as for the other network setters, so a
// change that cuts the console off is undone on its own. Writes are committed
// and the radios reloaded in the background, two seconds on, so the answer
// reaches the browser before the radio it may be on goes down.

let _m_fs = require('fs');
let readfile = _m_fs.readfile;
let _m_uci = require('uci');
let cursor = _m_uci.cursor;
let _m_util = loadfile('/usr/share/pulzr/console/lib/util.uc', { raw_mode: true })();
let access = loadfile('/usr/share/pulzr/console/lib/access.uc', { raw_mode: true })();
let wififail = loadfile('/usr/share/pulzr/console/lib/wififail.uc', { raw_mode: true })();

// ucode does not hoist function declarations; see util.uc.
let parsePhy, fits, bandOf, phyOf, radioInfo, widthsOf, familyOf, channelOk, maxDbm;
let iftypeOf, roleOf, networksOf, attachable, interfaceView, counts, room, defaultRoute;
let status, setRadio, setAp, removeAp, joinUplink, apFromRequest, checkAp, writeAp, reload, newApName;
let devices, ifaces, saeCapable, cached;
let slotOn, slotFor, configured, removeUplink, handover, readHandover, writeHandover, handoverWhy, scan;

let run = _m_util.run;; let runJson = _m_util.runJson;

const NAME = /^[A-Za-z0-9_]{1,32}$/;
const IFNAME = /^[A-Za-z0-9._-]{1,32}$/;
const AP_PREFIX = 'pulzr_ap_';
const MAX_APS = 8;

// The WiFi uplinks' stations, first the WiFi page's. See the header.
const SLOTS = [
    { section: 'pulzr_sta', iface: 'wwifi' },
    { section: 'pulzr_sta2', iface: 'wwifi2' },
];
// The latest handover, for the console. tmpfs: a reboot ends one anyway.
const HANDOVER = '/var/run/pulzr/wifi-handover.json';
const HANDOVER_RUN = '/usr/share/pulzr/console/wifi-handover.uc';
// Association, a lease, and pulzr-wifi-uplink's three tries at 2, 10 and 30
// seconds after ifup, with room for a slow DHCP server. A network that has
// not answered by then is not one to move the tunnel onto.
const HANDOVER_WAIT = 120;

// Networks an access point made here may serve, and what the console calls
// them. Only the LAN side: an AP on the setup network is pulzr-ap's, and one
// bridged onto an uplink would hand that uplink's far side to anybody in
// range. The port VLANs that serve devices are members of br-devlan already
// (pulzr-ports), so devlan is every one of them.
const ATTACH = { devlan: 'LAN' };

// What a network is called where an interface is shown, attachable or not.
const LABELS = { devlan: 'LAN', setup: 'Setup network', wwifi: 'Uplink', wwifi2: 'Uplink', lan: 'LAN' };

// iw's names for the interface types UCI's modes become.
const IFTYPE = { sta: 'managed', ap: 'AP', mesh: 'mesh point', adhoc: 'IBSS', monitor: 'monitor' };

// What an AP's security is called to UCI, and whether it takes a passphrase.
const SECURITY = {
    'psk2': { key: true, sae: false },
    'sae-mixed': { key: true, sae: true },
    'sae': { key: true, sae: true },
    'none': { key: false, sae: false },
};

// ── iw ──────────────────────────────────────────────────────────────────────

// `iw phy <phy> info`, as {modes, bands, combinations}. Bands are keyed 2g,
// 5g, 6g, 60g as UCI's `band` is. Tabs mark the depth: iw prints a section at
// one, its fields at two and their detail at three.
//
// Both frequency forms are read: iw 6.x prints "2412.0 MHz", older ones
// "2412 MHz". A field this does not know is skipped, so a newer iw that adds
// one changes nothing.
parsePhy = function(text) {
    const out = { modes: [], bands: {}, combinations: [] };
    const BANDS = { '1': '2g', '2': '5g', '3': '60g', '4': '6g' };
    let section = null, band = null, field = null, combo = null;
    for (let raw in split(text ?? '', '\n')) {
        const depth = length(match(raw, /^\t*/)[0]);
        const line = trim(raw);
        if (!length(line)) continue;
        if (depth <= 1) {
            field = null;
            const b = match(line, /^Band ([0-9]+):$/);
            if (b) {
                section = 'band';
                band = { channels: [], ht40: false, vht: false, vht160: false, he: false, he40: false,
                         he80: false, he160: false, eht: false, eht320: false };
                out.bands[BANDS[b[1]] ?? ('band' + b[1])] = band;
            }
            else if (line == 'Supported interface modes:') section = 'modes';
            else if (line == 'valid interface combinations:') section = 'combinations';
            else section = null;
            continue;
        }
        if (section == 'modes') {
            const m = match(line, /^\* (.+)$/);
            if (m) push(out.modes, m[1]);
        }
        else if (section == 'combinations') {
            if (substr(line, 0, 2) == '* ') { combo = substr(line, 2); push(out.combinations, combo); }
            else if (length(out.combinations)) out.combinations[length(out.combinations) - 1] += ' ' + line;
        }
        else if (section == 'band') {
            if (depth == 2) {
                if (match(line, /^Capabilities: /)) field = 'ht';
                else if (match(line, /^VHT Capabilities/)) { field = 'vht'; band.vht = true; }
                else if (match(line, /^HE Iftypes: /)) { field = 'he'; band.he = true; }
                else if (match(line, /^EHT Iftypes: /)) { field = 'eht'; band.eht = true; }
                else if (line == 'Frequencies:') field = 'freq';
                else field = null;
                continue;
            }
            if (field == 'ht' && index(line, 'HT20/HT40') >= 0) band.ht40 = true;
            else if (field == 'vht' && match(line, /^Supported Channel Width: .*160/)) band.vht160 = true;
            else if (field == 'he') {
                if (match(line, /HE40\/2\.4GHz|HE40\/HE80\/5GHz/)) band.he40 = true;
                if (match(line, /HE40\/HE80\/5GHz/)) band.he80 = true;
                if (match(line, /HE160\/5GHz/)) band.he160 = true;
            }
            else if (field == 'eht' && match(line, /320MHz/)) band.eht320 = true;
            else if (field == 'freq') {
                const f = match(line, /^\* ([0-9]+)(\.[0-9]+)? MHz \[([0-9]+)\](.*)$/);
                if (!f) continue;
                const rest = f[4];
                const dbm = match(rest, /\(([0-9]+)(\.[0-9]+)? dBm\)/);
                push(band.channels, {
                    channel: int(f[3]), mhz: int(f[1]),
                    maxDbm: dbm ? int(dbm[1]) : null,
                    disabled: index(rest, 'disabled') >= 0,
                    noIr: index(rest, 'no IR') >= 0,
                    dfs: index(rest, 'radar') >= 0,
                });
            }
        }
    }
    // Each combination as limits on groups of types, a total and a channel
    // count: "#{ managed } <= 1, #{ AP, mesh point } <= 8, total <= 9,
    // #channels <= 1".
    out.combinations = map(out.combinations, (c) => {
        const limits = map(match(c, /#\{ ([^}]*) \} <= ([0-9]+)/g) ?? [], (l) => ({
            types: map(split(l[1], ','), (t) => trim(t)), max: int(l[2]),
        }));
        const total = match(c, /total <= ([0-9]+)/);
        const channels = match(c, /#channels <= ([0-9]+)/);
        return { limits, total: total ? int(total[1]) : 1, channels: channels ? int(channels[1]) : 1 };
    });
    return out;
};

// Whether interfaces in these numbers, by iw type, can run on the phy at
// once: {ok, channels} for the first combination that holds them, or {ok:
// false}. One interface needs no combination. A driver that lists none takes
// one interface at a time. Monitor is left out: mac80211 treats it as a
// software type that no combination counts.
fits = function(phy, wanted) {
    let total = 0;
    for (let t in keys(wanted)) {
        if (t == 'monitor' || !wanted[t]) continue;
        if (!(t in phy.modes)) return { ok: false, reason: sprintf('This radio cannot run %s.', t == 'AP' ? 'an access point' : (t == 'managed' ? 'a station' : t)) };
        total += wanted[t];
    }
    if (total <= 1) return { ok: true, channels: 1 };
    for (let c in phy.combinations) {
        if (total > c.total) continue;
        let ok = true;
        for (let t in keys(wanted)) {
            if (t == 'monitor' || !wanted[t]) continue;
            let limit = null;
            for (let l in c.limits) if (t in l.types) { limit = l; break; }
            if (!limit) { ok = false; break; }
            let used = 0;
            for (let u in limit.types) used += wanted[u] ?? 0;
            if (used > limit.max) { ok = false; break; }
        }
        if (ok) return { ok: true, channels: c.channels };
    }
    return { ok: false, reason: 'This radio cannot run that many interfaces at once.' };
};

// ── reading a radio ─────────────────────────────────────────────────────────

devices = function(uci) {
    const out = [];
    uci.foreach('wireless', 'wifi-device', (s) => { if (match(s['.name'], NAME)) push(out, s); });
    return out;
};

ifaces = function(uci) {
    const out = [];
    uci.foreach('wireless', 'wifi-iface', (s) => { if (match(s['.name'], NAME)) push(out, s); });
    return out;
};

// The phy a radio is, by its device path: netifd's own way of tying the two.
// /sys/class/ieee80211/phy0/device resolves to /sys/devices/<path>. iwinfo's
// answer is used first when the radio is up and has one.
phyOf = function(dev, hint) {
    if (hint && match(hint, IFNAME)) return hint;
    const phys = _m_fs.lsdir('/sys/class/ieee80211') ?? [];
    if (dev.path)
        for (let phy in phys) {
            const real = _m_fs.realpath(sprintf('/sys/class/ieee80211/%s/device', phy)) ?? '';
            if (length(real) >= length(dev.path) && substr(real, -length(dev.path)) == dev.path) return phy;
        }
    return null;
};

// What `iw phy` and iwinfo say about a phy, read once a request.
cached = {};
radioInfo = function(name, phyHint) {
    const key = name + '/' + (phyHint ?? '');
    if (cached[key]) return cached[key];
    const info = match(name, IFNAME) ? (runJson(sprintf("ubus call iwinfo info '{\"device\":\"%s\"}'", name)) ?? {}) : {};
    const phy = phyHint ?? info.phy;
    const caps = phy && match(phy, IFNAME) ? parsePhy(run(sprintf('iw phy %s info 2>/dev/null', phy))) : null;
    return cached[key] = { info, phy, caps };
};

// The band a radio is on: UCI's `band`, else the one band its phy has, else
// what its channel says.
bandOf = function(dev, caps) {
    if (dev.band in ['2g', '5g', '6g', '60g']) return dev.band;
    const bands = keys(caps?.bands ?? {});
    if (length(bands) == 1) return bands[0];
    if (dev.hwmode == '11a') return '5g';
    const ch = int(dev.channel ?? 0);
    return ch > 14 ? '5g' : '2g';
};

// The htmode prefix this radio's band does widest: EHT, HE, VHT, HT, or
// NOHT for a radio with no 802.11n at all.
familyOf = function(band, b) {
    if (!b) return 'HT';
    if (b.eht) return 'EHT';
    if (b.he) return 'HE';
    if (b.vht && band != '2g') return 'VHT';
    if (b.ht40 || length(b.channels)) return band == '60g' ? 'NOHT' : 'HT';
    return 'NOHT';
};

// The widths, in MHz, this radio does on its band.
widthsOf = function(band, b) {
    if (!b) return [20];
    const out = [20];
    if (band == '2g') {
        if (b.ht40 || b.he40) push(out, 40);
        return out;
    }
    if (b.ht40 || b.he40 || b.he) push(out, 40);
    if (b.vht || b.he80 || (band == '6g' && b.he)) push(out, 80);
    if (b.vht160 || b.he160) push(out, 160);
    if (band == '6g' && b.eht320) push(out, 320);
    return out;
};

// Whether a channel can be used at a width: every 20 MHz channel the wider
// one covers is open on this unit. On 5 GHz the blocks start at 36 below
// 149 and at 149 above it; 6 GHz numbers from 1. 2.4 GHz at 40 takes the
// channel four above or below, whichever is open, as hostapd does.
channelOk = function(band, b, channel, width) {
    const open = {};
    for (let c in (b?.channels ?? [])) if (!c.disabled) open[c.channel] = true;
    if (!open[channel]) return false;
    if (width <= 20) return true;
    if (band == '2g') return width == 40 && (open[channel + 4] || open[channel - 4]);
    const base = band == '6g' ? 1 : (channel >= 149 ? 149 : 36);
    const n = width / 20;
    if ((channel - base) % 4) return false;
    const start = base + int(((channel - base) / 4) / n) * n * 4;
    for (let i = 0; i < n; i++) if (!open[start + i * 4]) return false;
    return true;
};

// The highest power any open channel allows, in dBm.
maxDbm = function(b) {
    let max = null;
    for (let c in (b?.channels ?? []))
        if (!c.disabled && c.maxDbm != null && (max == null || c.maxDbm > max)) max = c.maxDbm;
    return max;
};

// ── what runs on a radio ────────────────────────────────────────────────────

iftypeOf = (s) => IFTYPE[s.mode ?? 'ap'] ?? s.mode;

// Who owns an interface, which is what may be done with it here.
roleOf = function(s) {
    if (s['.name'] == 'pulzr_sta') return { role: 'uplink', owner: 'uplink' };
    if (s['.name'] == 'pulzr_sta2') return { role: 'uplink', owner: 'radios' };
    if (s['.name'] == 'pulzr_setup_ap') return { role: 'ap', owner: 'setup' };
    const mode = s.mode ?? 'ap';
    const role = { ap: 'ap', sta: 'client', mesh: 'mesh', monitor: 'monitor', adhoc: 'adhoc' }[mode] ?? 'other';
    if (mode == 'ap' && substr(s['.name'], 0, length(AP_PREFIX)) == AP_PREFIX) return { role, owner: 'console' };
    return { role, owner: 'other' };
};

networksOf = function(s) {
    const n = s.network;
    if (n == null) return [];
    return type(n) == 'array' ? n : filter(split(n, ' '), (x) => length(x));
};

// The networks an AP may be put on, on this gateway.
attachable = function(uci) {
    const out = [];
    for (let id in keys(ATTACH))
        if (uci.get('network', id) == 'interface')
            push(out, { id, label: ATTACH[id], address: uci.get('network', id, 'ipaddr') ?? null });
    return out;
};

// How many interfaces of each iw type `list` holds on `radio`, leaving out
// `skip` (the one being replaced) and anything disabled.
counts = function(list, radio, skip) {
    const out = {};
    for (let s in list) {
        if (s.device != radio || s['.name'] == skip || s.disabled == '1') continue;
        const t = iftypeOf(s);
        out[t] = (out[t] ?? 0) + 1;
    }
    return out;
};

// Whether one more AP, or the uplink's station, fits beside what is there.
// A join onto a radio replaces the station already on it.
room = function(caps, list, radio) {
    if (!caps) return { ap: true, uplink: true, known: false };
    let mine = null;
    for (let s in list) if (s.device == radio && (s['.name'] == SLOTS[0].section || s['.name'] == SLOTS[1].section)) mine = s['.name'];
    const now = counts(list, radio, mine);
    const withAp = { ...counts(list, radio, null) };
    withAp.AP = (withAp.AP ?? 0) + 1;
    const withSta = { ...now };
    withSta.managed = (withSta.managed ?? 0) + 1;
    return { ap: fits(caps, withAp).ok, uplink: fits(caps, withSta).ok, known: true };
};

// One interface as the console shows it: its configuration and, when it is
// up, what it is doing (clients of an AP, the network a station is on).
interfaceView = function(s, live) {
    const who = roleOf(s);
    const nets = networksOf(s);
    const out = {
        id: s['.name'], role: who.role, owner: who.owner, mode: s.mode ?? 'ap',
        ssid: s.ssid ?? null, meshId: s.mesh_id ?? null,
        security: s.encryption ?? 'none',
        networks: map(nets, (n) => ({ id: n, label: LABELS[n] ?? n })),
        hidden: s.hidden == '1', isolate: s.isolate == '1', enabled: s.disabled != '1',
        ifname: live?.ifname ?? null, up: !!live?.ifname,
        clients: null, signal: null, bssid: null, channel: null,
    };
    if (!out.up || !match(out.ifname, IFNAME)) return out;
    if (who.role == 'ap' || who.role == 'mesh') {
        const list = runJson(sprintf("ubus call iwinfo assoclist '{\"device\":\"%s\"}'", out.ifname));
        out.clients = map(list?.results ?? [], (c) => ({
            mac: c.mac, signal: c.signal ?? null, inactive: c.inactive ?? null,
            rx: c.rx?.rate ?? null, tx: c.tx?.rate ?? null,
        }));
    }
    else if (who.role == 'uplink' || who.role == 'client') {
        const info = runJson(sprintf("ubus call iwinfo info '{\"device\":\"%s\"}'", out.ifname)) ?? {};
        out.signal = info.signal ?? null;
        out.bssid = info.bssid && info.bssid != '00:00:00:00:00:00' ? info.bssid : null;
        out.channel = info.channel ?? null;
        out.ssid = s.ssid ?? info.ssid ?? null;
    }
    return out;
};

// Which uplink carries the default route now, and what kind it is: the
// diagram's first hop.
defaultRoute = function() {
    const dump = runJson('ubus call network.interface dump') ?? {};
    let best = null;
    for (let i in (dump.interface ?? [])) {
        if (!i.up) continue;
        for (let r in (i.route ?? []))
            if (r.target == '0.0.0.0' && r.mask == 0 && (!best || (r.metric ?? 0) < best.metric))
                best = { iface: i.interface, metric: r.metric ?? 0 };
    }
    if (!best) return { via: null, iface: null };
    const n = best.iface;
    const via = (n == 'wwifi' || n == 'wwifi2') ? 'wifi' : (n == 'wwan' ? 'cellular' : (n == 'usbwan' ? 'usb-cellular'
              : (match(n, /^wan(_|$)/) ? 'ethernet' : 'other')));
    return { via, iface: n };
};

saeCapable = function() {
    return run('hostapd -vsae >/dev/null 2>&1 && echo yes') == 'yes';
};

status = function() {
    const uci = cursor();
    const live = runJson('ubus call network.wireless status') ?? {};
    const list = ifaces(uci);
    let country = null;
    const radios = map(devices(uci), (dev) => {
        const name = dev['.name'];
        const state = live[name] ?? {};
        const byId = {};
        for (let i in (state.interfaces ?? [])) if (i.section) byId[i.section] = i;
        // An interface's own ifname tells iwinfo which phy it is on; the
        // radio's name works when nothing is up on it.
        let probe = name;
        for (let i in (state.interfaces ?? [])) if (i.ifname && match(i.ifname, IFNAME)) { probe = i.ifname; break; }
        const ri = radioInfo(probe, null);
        const phy = phyOf(dev, ri.phy);
        const caps = ri.phy == phy ? ri.caps : radioInfo(name, phy).caps;
        const band = bandOf(dev, caps);
        const b = caps?.bands?.[band];
        const views = map(filter(list, (s) => s.device == name), (s) => interfaceView(s, byId[s['.name']]));
        const roomFor = room(caps, list, name);
        const live1 = ri.info ?? {};
        country ??= dev.country ?? live1.country ?? null;
        const hasSta = length(filter(views, (v) => v.mode == 'sta' && v.enabled)) > 0;
        const hasAp = length(filter(views, (v) => v.mode == 'ap' && v.enabled)) > 0;
        const together = caps ? fits(caps, counts(list, name, null)) : { ok: true, channels: 1 };
        const htmode = dev.htmode ?? null;
        const cw = htmode ? match(htmode, /([0-9]+)$/) : null;
        return {
            id: name, phy, present: phy != null, band,
            hardware: live1.hardware?.name ?? null,
            standards: live1.hwmodes ?? null,
            enabled: dev.disabled != '1',
            up: !!state.up,
            channel: {
                configured: (dev.channel == null || dev.channel == 'auto') ? 'auto' : int(dev.channel),
                current: live1.channel ?? null, mhz: live1.frequency ?? null,
            },
            width: { configured: cw ? int(cw[1]) : 20, htmode },
            txpower: { configured: dev.txpower != null ? int(dev.txpower) : null,
                       current: live1.txpower ?? null, max: maxDbm(b) },
            country: dev.country ?? live1.country ?? null,
            // A station and an AP on a radio that does one channel: the AP is
            // on the upstream network's.
            sharedChannel: hasSta && hasAp && together.channels <= 1,
            capabilities: {
                known: caps != null,
                modes: caps?.modes ?? [],
                channels: map(filter(b?.channels ?? [], (c) => !c.disabled),
                              (c) => ({ channel: c.channel, mhz: c.mhz, maxDbm: c.maxDbm, dfs: c.dfs })),
                widths: widthsOf(band, b),
                family: familyOf(band, b),
                combinations: caps?.combinations ?? [],
                room: roomFor,
            },
            interfaces: views,
        };
    });
    return {
        radios,
        country,
        sae: saeCapable(),
        networks: attachable(uci),
        route: defaultRoute(),
        hostname: trim(readfile('/proc/sys/kernel/hostname') ?? '') || null,
        uplink: uci.get('wireless', 'pulzr_sta', 'ssid') ? uci.get('wireless', 'pulzr_sta', 'device') : null,
        // Every WiFi uplink, the WiFi page's first, with its address: the
        // Backhaul rows show the second one's from here (the WiFi page's
        // status knows only the first).
        uplinks: map(filter(SLOTS, (sl) => configured(uci, sl)), (sl) => {
            const link = runJson(sprintf('ubus call network.interface.%s status', sl.iface)) ?? {};
            return {
                id: sl.section, iface: sl.iface,
                radio: uci.get('wireless', sl.section, 'device'), ssid: uci.get('wireless', sl.section, 'ssid'),
                up: !!link.up, address: link['ipv4-address']?.[0]?.address ?? null,
            };
        }),
        handover: readHandover(),
    };
};

// ── changing a radio ────────────────────────────────────────────────────────

// Commit and reload in the background; see the header.
reload = function(uci) {
    uci.commit('wireless');
    run('(sleep 2; wifi reload) >/dev/null 2>&1 &');
};

// A radio's channel, width, power, and on/off; the country for every radio,
// because Linux has one regulatory domain however many radios it is given.
setRadio = function(req) {
    const uci = cursor();
    const name = req?.radio;
    if (type(name) != 'string' || !match(name, NAME) || uci.get('wireless', name) != 'wifi-device')
        return { error: 'No such radio.' };
    const dev = uci.get_all('wireless', name);
    const phy = phyOf(dev, radioInfo(name, null).phy);
    const caps = phy ? radioInfo(name, phy).caps : null;
    const band = bandOf(dev, caps);
    const b = caps?.bands?.[band];

    let width = req.width != null ? int(req.width) : null;
    if (width != null && !(width in widthsOf(band, b)))
        return { error: sprintf('This radio does not do %d MHz on this band.', width) };

    let channel = null;
    if (req.channel != null) {
        if (req.channel == 'auto') channel = 'auto';
        else {
            channel = int(req.channel);
            const was = match(dev.htmode ?? '', /([0-9]+)$/);
            const w = width ?? (was ? int(was[1]) : 20);
            if (caps && !channelOk(band, b, channel, 20))
                return { error: sprintf('Channel %d is not open on this radio here.', channel) };
            if (caps && !channelOk(band, b, channel, w))
                return { error: sprintf('Channel %d cannot carry %d MHz here.', channel, w) };
        }
    }

    let power = null;
    if (req.txpower != null && req.txpower != 'max') {
        power = int(req.txpower);
        const max = maxDbm(b) ?? 30;
        if (power < 1 || power > max) return { error: sprintf('Power is 1 to %d dBm on this radio.', max) };
    }

    let country = null;
    if (req.country != null) {
        if (type(req.country) != 'string' || !match(req.country, /^([A-Z]{2}|00)$/))
            return { error: 'A country is its two-letter code.' };
        country = req.country;
    }

    if (channel != null) uci.set('wireless', name, 'channel', channel == 'auto' ? 'auto' : sprintf('%d', channel));
    if (width != null) {
        const family = familyOf(band, b);
        if (family == 'NOHT') uci.delete('wireless', name, 'htmode');
        else uci.set('wireless', name, 'htmode', sprintf('%s%d', family, width));
    }
    if (req.txpower == 'max') uci.delete('wireless', name, 'txpower');
    else if (power != null) uci.set('wireless', name, 'txpower', sprintf('%d', power));
    if (country != null) for (let d in devices(uci)) uci.set('wireless', d['.name'], 'country', country);
    if (req.enabled != null) uci.set('wireless', name, 'disabled', req.enabled ? '0' : '1');
    reload(uci);
    return { ok: true };
};

// The AP a request describes, checked: {name, radio, ssid, ...} or {error}.
apFromRequest = function(uci, req, sae) {
    const existing = req.id != null ? req.id : null;
    if (existing != null) {
        if (type(existing) != 'string' || substr(existing, 0, length(AP_PREFIX)) != AP_PREFIX
                || !match(existing, NAME) || uci.get('wireless', existing) != 'wifi-iface')
            return { error: 'That access point is not one made here.' };
    }
    const old = existing ? uci.get_all('wireless', existing) : {};
    const radio = req.radio ?? old.device;
    if (type(radio) != 'string' || !match(radio, NAME) || uci.get('wireless', radio) != 'wifi-device')
        return { error: 'No such radio.' };

    const ssid = req.ssid ?? old.ssid;
    if (type(ssid) != 'string' || !length(ssid) || length(ssid) > 32)
        return { error: 'A network name is 1 to 32 bytes.' };

    const security = req.security ?? old.encryption ?? 'psk2';
    const kind = SECURITY[security];
    if (!kind) return { error: 'Security is WPA2, WPA2/WPA3, WPA3 or open.' };
    if (kind.sae && !sae) return { error: 'This gateway has no WPA3 support.' };
    // A passphrase left blank keeps the one this AP has: the console never
    // sees it again after it is set.
    let key = req.key != null && req.key != '' ? req.key : (kind.key ? old.key : null);
    if (kind.key) {
        if (type(key) != 'string' || length(key) < 8 || length(key) > 63)
            return { error: 'A passphrase is 8 to 63 characters.' };
    }
    else {
        key = null;
        // An open AP onto the LAN is the LAN handed to anybody in range: the
        // PLC, the cameras, the console. Only when said in so many words.
        if (!req.allowOpen && old.encryption != 'none')
            return { error: 'An open access point puts the LAN in reach of anybody nearby. Confirm it explicitly.' };
    }

    const network = req.network ?? networksOf(old)[0];
    let found = false;
    for (let n in attachable(uci)) if (n.id == network) found = true;
    if (!found) return { error: 'Choose a network for the access point.' };

    return {
        name: existing, radio, ssid, security, key, network,
        hidden: req.hidden != null ? !!req.hidden : old.hidden == '1',
        isolate: req.isolate != null ? !!req.isolate : old.isolate == '1',
        enabled: req.enabled != null ? !!req.enabled : old.disabled != '1',
    };
};

newApName = function(uci) {
    for (let i = 0; i < 64; i++) {
        const name = AP_PREFIX + i;
        if (uci.get('wireless', name) == null) return name;
    }
    return null;
};

// Whether an AP that apFromRequest passed fits beside what is on its radio,
// with `extra` interfaces planned there too (the uplink's station, in a
// repeater): null, or why not.
checkAp = function(uci, ap, extra) {
    const list = ifaces(uci);
    let mine = 0;
    for (let s in list) if (substr(s['.name'], 0, length(AP_PREFIX)) == AP_PREFIX && s['.name'] != ap.name) mine++;
    if (!ap.name && mine >= MAX_APS) return { error: sprintf('At most %d access points.', MAX_APS) };
    if (!ap.name && !newApName(uci)) return { error: 'No room for another access point.' };
    if (!ap.enabled) return null;
    const dev = uci.get_all('wireless', ap.radio);
    const caps = radioInfo(ap.radio, phyOf(dev, radioInfo(ap.radio, null).phy)).caps;
    if (!caps) return null;
    const wanted = counts(list, ap.radio, ap.name);
    for (let t in keys(extra ?? {})) wanted[t] = extra[t];
    wanted.AP = (wanted.AP ?? 0) + 1;
    const ok = fits(caps, wanted);
    return ok.ok ? null : { error: ok.reason };
};

// Writes an AP that checkAp passed. Does not commit.
writeAp = function(uci, ap) {
    const name = ap.name ?? newApName(uci);
    uci.set('wireless', name, 'wifi-iface');
    uci.set('wireless', name, 'device', ap.radio);
    uci.set('wireless', name, 'mode', 'ap');
    uci.set('wireless', name, 'network', ap.network);
    uci.set('wireless', name, 'ssid', ap.ssid);
    uci.set('wireless', name, 'encryption', ap.security);
    if (ap.key) uci.set('wireless', name, 'key', ap.key);
    else uci.delete('wireless', name, 'key');
    for (let opt in ['hidden', 'isolate'])
        if (ap[opt]) uci.set('wireless', name, opt, '1');
        else uci.delete('wireless', name, opt);
    uci.set('wireless', name, 'disabled', ap.enabled ? '0' : '1');
    // An AP on a radio that is off is an AP nobody sees, which is what a
    // stock radio is until something turns it on.
    if (ap.enabled) uci.set('wireless', ap.radio, 'disabled', '0');
    return { ok: true, id: name };
};

// `replace`: access point mode on a radio that carries a WiFi uplink. The
// station goes in the same change the AP comes in, so one undo brings the
// uplink back. As two changes the first, taking the uplink away, could be
// the last thing that reached the gateway, and the AP would never be asked
// for.
setAp = function(req) {
    const uci = cursor();
    const ap = apFromRequest(uci, req ?? {}, saeCapable());
    if (ap.error) return ap;
    const station = req?.replace && !ap.name ? slotOn(uci, ap.radio) : null;
    // Off this cursor only, so the fit is counted without it; nothing is
    // committed from it.
    if (station) uci.delete('wireless', station.section);
    const refused = checkAp(uci, ap, null);
    if (refused) return refused;
    if (!station) {
        const written = writeAp(uci, ap);
        reload(uci);
        return written;
    }
    // As removeUplink: last in the order first, then a cursor read after
    // pulzr-uplinks has written the metrics.
    access.demote(station.iface);
    const after = cursor();
    access.removeStation(after, station);
    const written = writeAp(after, ap);
    after.commit('wireless');
    after.commit('network');
    after.commit('firewall');
    _m_fs.unlink(station.iface == SLOTS[0].iface ? '/var/run/pulzr/wifi-uplink.json'
                 : sprintf('/var/run/pulzr/wifi-uplink-%s.json', station.iface));
    if (readHandover()?.iface == station.iface) _m_fs.unlink(HANDOVER);
    run('(sleep 2; wifi reload; /etc/init.d/firewall reload; /usr/sbin/pulzr-uplinks apply; '
        + '/usr/sbin/pulzr-wireguard-route apply) >/dev/null 2>&1 &');
    return written;
};

removeAp = function(req) {
    const uci = cursor();
    const id = req?.id;
    if (type(id) != 'string' || substr(id, 0, length(AP_PREFIX)) != AP_PREFIX || !match(id, NAME)
            || uci.get('wireless', id) != 'wifi-iface')
        return { error: 'That access point is not one made here.' };
    uci.delete('wireless', id);
    reload(uci);
    return { ok: true };
};

// ── the WiFi uplinks ────────────────────────────────────────────────────────

configured = (uci, slot) => !!uci.get('wireless', slot.section, 'ssid');

// The slot whose station is on `radio`, or null.
slotOn = function(uci, radio) {
    for (let sl in SLOTS)
        if (configured(uci, sl) && uci.get('wireless', sl.section, 'device') == radio) return sl;
    return null;
};

// Where a join onto `radio` goes: the station already there, else the first
// free slot. Null when both are on other radios.
slotFor = function(uci, radio) {
    const on = slotOn(uci, radio);
    if (on) return on;
    for (let sl in SLOTS) if (!configured(uci, sl)) return sl;
    return null;
};

readHandover = function() {
    try { return json(readfile(HANDOVER) ?? 'null'); } catch (e) { return null; }
};

writeHandover = function(h) {
    _m_fs.mkdir('/var/run/pulzr');
    _m_fs.writefile(HANDOVER + '.tmp', sprintf('%J', h));
    _m_fs.rename(HANDOVER + '.tmp', HANDOVER);
};

// The uplink on a chosen radio, and in a repeater an AP with it, as one
// change. Everything is checked first, the AP's fit beside the station
// included, so a refusal changes nothing. Then the join (access.joinWifi:
// saved networks, the portal and roaming all as from the WiFi page), then
// the AP, committed before the join's reload two seconds on brings both up.
// Onto a radio with no station while another radio has one, the join is a
// second station and a handover (see the header): {ssid, saved: true, radio}
// for the network the uplink is on now, or any network the wizard joins.
joinUplink = function(req) {
    const uci = cursor();
    const radio = req?.radio;
    if (type(radio) != 'string' || !match(radio, NAME) || uci.get('wireless', radio) != 'wifi-device')
        return { error: 'No such radio.' };
    const dev = uci.get_all('wireless', radio);
    const caps = radioInfo(radio, phyOf(dev, radioInfo(radio, null).phy)).caps;
    const slot = slotFor(uci, radio);
    if (!slot) return { error: 'Both WiFi uplinks are in use. Remove one first.' };
    // The other WiFi uplink, which carries the traffic while this one joins.
    let keep = null;
    for (let sl in SLOTS) if (sl.section != slot.section && configured(uci, sl)) keep = sl;

    let ap = null;
    if (req.ap != null) {
        if (type(req.ap) != 'object') return { error: 'The access point is a set of fields.' };
        ap = apFromRequest(uci, req.ap, saeCapable());
        if (ap.error) return ap;
        const refused = checkAp(uci, ap, ap.radio == radio ? { managed: 1 } : null);
        if (refused) return ap.radio == radio
            ? { error: 'This radio cannot be the uplink and an access point at once. Use two radios.' } : refused;
    }

    if (caps) {
        const wanted = counts(ifaces(uci), radio, slot.section);
        wanted.managed = (wanted.managed ?? 0) + 1;
        if (ap && ap.radio == radio && ap.enabled) wanted.AP = (wanted.AP ?? 0) + 1;
        const ok = fits(caps, wanted);
        if (!ok.ok) return ok.reason ? { error: ok.reason } : { error: 'This radio cannot be the uplink.' };
    }

    const join = { ...req, radio };
    delete join.ap;
    const joined = access.joinWifi(join, slot);
    if (joined.error) return joined;
    if (keep) {
        writeHandover({ iface: slot.iface, radio, ssid: cursor().get('wireless', slot.section, 'ssid'),
                        from: keep.iface, fromRadio: uci.get('wireless', keep.section, 'device'),
                        state: 'joining', startedAt: time() });
        // After the join's reload, two seconds on, so the station it waits
        // for exists.
        run(sprintf('(sleep 4; ucode %s %s) >/dev/null 2>&1 &', HANDOVER_RUN, slot.iface));
    }
    if (!ap) return joined;
    // A cursor of its own: joinWifi committed through another, and this one
    // was read before that.
    const after = cursor();
    const written = writeAp(after, ap);
    after.commit('wireless');
    return { ...joined, ap: written.id };
};

// Why a station that was given HANDOVER_WAIT did not take over: wpa_supplicant's
// failure when it never associated (lib/wififail.uc, its lines only), else
// pulzr-wifi-uplink's answer in access.uplinkReason's words.
handoverWhy = function(slot, link, verdict) {
    if (!link.up) {
        let ifname = null;
        const live = runJson('ubus call network.wireless status') ?? {};
        for (let r in keys(live))
            for (let i in (live[r].interfaces ?? []))
                if (i.section == slot.section && i.ifname && match(i.ifname, IFNAME)) ifname = i.ifname;
        const log = ifname ? run(sprintf("logread | grep 'wpa_supplicant' | grep -F '%s:' | tail -n 200", ifname)) : null;
        const failure = log ? wififail.last(log) : null;
        return failure ? { failure } : { reason: 'Not connected.' };
    }
    if (verdict?.state == 'portal') return { reason: 'Sign-in page.' };
    const why = verdict?.state ? access.uplinkReason(verdict) : null;
    return { reason: why ? uc(substr(why, 0, 1)) + substr(why, 1) : 'No internet.' };
};

// Run by wifi-handover.uc, in the background, for the station joinUplink just
// wrote: wait for it to be up and open, then put it first among the WiFi
// uplinks; or give up, remove it, and say why. See the header.
handover = function(iface) {
    let h = readHandover();
    if (h?.iface != iface || h.state != 'joining') return h;
    let slot = null;
    for (let sl in SLOTS) if (sl.iface == iface) slot = sl;
    let asked = 0;
    while (true) {
        // Undone under it, by the rollback window or by hand: nothing to do.
        if (cursor().get('wireless', slot.section, 'ssid') != h.ssid) {
            _m_fs.unlink(HANDOVER);
            return null;
        }
        const link = runJson(sprintf('ubus call network.interface.%s status', iface)) ?? {};
        let verdict = runJson(sprintf('/usr/sbin/pulzr-wifi-uplink status %s', iface)) ?? {};
        if (link.up && verdict.state == 'open' && verdict.ssid == h.ssid) break;
        // The hotplug asks three times after ifup and then leaves it to the
        // minute's sweep. Asked here as well, so a slow first lease is not
        // judged on an answer from before it.
        if (link.up && time() - asked >= 15 && time() - (verdict.checkedAt ?? 0) >= 15) {
            asked = time();
            run(sprintf('/usr/sbin/pulzr-wifi-uplink check %s >/dev/null 2>&1', iface));
            continue;
        }
        if (time() - h.startedAt >= HANDOVER_WAIT) {
            writeHandover({ ...h, state: 'failed', endedAt: time(), ...handoverWhy(slot, link, verdict) });
            // The second station only. The WiFi page's own (a first station
            // joined while the second carries) stays, as a join there does,
            // and that page says why it is down.
            if (slot.section != SLOTS[0].section) {
                const uci = cursor();
                access.removeStation(uci, slot);
                uci.commit('wireless');
                uci.commit('network');
                uci.commit('firewall');
                run('(wifi reload; /etc/init.d/firewall reload) >/dev/null 2>&1');
            }
            return readHandover();
        }
        sleep(3000);
    }

    // Where the old one is in the order, so a cable ahead of both stays
    // ahead, and the old one right behind it. pulzr-uplinks moves the
    // metrics, then the tunnel and LoRa (its hooks).
    const st = runJson('/usr/sbin/pulzr-uplinks status') ?? {};
    const order = filter(st.order ?? [], (n) => n != iface && match(n, /^[A-Za-z0-9_]{1,15}$/));
    if (length(order)) {
        let at = index(order, h.from);
        splice(order, at < 0 ? 0 : at, 0, iface);
        run(sprintf('/usr/sbin/pulzr-uplinks order %s >/dev/null 2>&1', join(' ', order)));
    }
    writeHandover({ ...h, state: 'done', endedAt: time() });
    return readHandover();
};

// The second station off its radio. The WiFi page's own is forgotten there.
// It goes last in the order first, so the traffic is on the other uplink
// before this one lets go.
removeUplink = function(req) {
    const uci = cursor();
    const radio = req?.radio;
    if (type(radio) != 'string' || !match(radio, NAME)) return { error: 'No such radio.' };
    const slot = slotOn(uci, radio);
    if (!slot) return { error: 'No uplink on this radio.' };
    if (slot.section == SLOTS[0].section) return { error: 'Forget this network on the WiFi page.' };
    access.demote(slot.iface);
    const after = cursor();
    access.removeStation(after, slot);
    after.commit('wireless');
    after.commit('network');
    after.commit('firewall');
    _m_fs.unlink(sprintf('/var/run/pulzr/wifi-uplink-%s.json', slot.iface));
    if (readHandover()?.iface == slot.iface) _m_fs.unlink(HANDOVER);
    run('(sleep 2; wifi reload; /etc/init.d/firewall reload; /usr/sbin/pulzr-uplinks apply; '
        + '/usr/sbin/pulzr-wireguard-route apply) >/dev/null 2>&1 &');
    return { ok: true };
};

// The networks one radio hears (?radio=radio1), as access.scan answers. The
// uplink onto the 5 GHz radio offers the network the 2.4 GHz one is on only
// when the 5 GHz radio hears it: a site whose 5 GHz network has its own name
// would otherwise be joined to a network that radio can never reach, and the
// handover would spend two minutes finding that out.
scan = function(query) {
    const m = match(query ?? '', /(^|&)radio=([A-Za-z0-9_]{1,32})(&|$)/);
    const uci = cursor();
    if (!m || uci.get('wireless', m[2]) != 'wifi-device') return { capable: false, networks: [], error: 'No such radio.' };
    const phy = phyOf(uci.get_all('wireless', m[2]), radioInfo(m[2], null).phy);
    if (!phy) return { capable: true, networks: [], error: 'The radio is not detected.' };
    return access.scan(phy);
};

// ── module exports ──────────────────────────────────────────────────────────
//
// A returned object, not `export` statements; see the header of
// api/index.uc.
return { channelOk, fits, handover, joinUplink, parsePhy, removeAp, removeUplink, scan, setAp, setRadio, status, widthsOf };
