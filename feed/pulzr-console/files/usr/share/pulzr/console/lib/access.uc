// The setup AP, the captive portal, and how to reach this gateway locally.
//
// ── THE AUTHORISATION RULE FOR THIS WHOLE MODULE ───────────────────────────
//
// Everything here is reachable from the setup AP, which on an unadopted
// gateway is an OPEN radio. So the rule is:
//
//   read      what a stranger in range may see. Deliberately thin: whether an
//             AP is up, whether DHCP is being served, and nothing that
//             identifies a customer or a credential.
//   write     never permitted from an unauthenticated session. The API router
//             enforces that; nothing here is in the PUBLIC table.
//
// On an adopted gateway the AP is WPA2 anyway, so a caller has already proved
// something. The read/write split still holds, because defence that depends on
// one control holding is not defence.

let _m_fs = require('fs');
let readfile = _m_fs.readfile;
let _m_uci = require('uci');
let cursor = _m_uci.cursor;
let _m_util = loadfile('/usr/share/pulzr/console/lib/util.uc', { raw_mode: true })();
let signin = loadfile('/usr/share/pulzr/console/lib/signin.uc', { raw_mode: true })();
let wififail = loadfile('/usr/share/pulzr/console/lib/wififail.uc', { raw_mode: true })();

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
let status, key, setAp, raiseAp, lowerAp, scan, joinWifi, forgetWifi;
let security, probeWifi, probeResult, wifiDetail, roam, roams, recordRoam, checkWifi;
let uplinkReason, roamReason;
let savedNetworks, findSaved, networkFromRequest, saveNetwork, applyNetwork,
    radioName, commitAndReload, demote, removeStation;

let run = _m_util.run;; let runJson = _m_util.runJson;
let writefile = _m_fs.writefile;; let unlink = _m_fs.unlink;; let mkdir = _m_fs.mkdir;

// The WiFi uplink this module looks after: the WiFi page's join, saved
// networks, roaming, the portal. A second radio's station (pulzr_sta2,
// wwifi2) is lib/radios.uc's, and joins through joinWifi with its own slot so
// it is written exactly as this one is.
const PRIMARY = { section: 'parkeze_sta', iface: 'wwifi' };

const PROBE_REQ = '/tmp/pulzr-wifi-probe.req';
const PROBE_OUT = '/tmp/pulzr-wifi-probe.json';

// What a network asks for, from iwinfo's scan entry or our own section.
// 'eap' is WPA-Enterprise — a username and password checked by a RADIUS
// server, eduroam being the one everybody meets.
security = function(encryption) {
    if (type(encryption) == 'string')
        return match(encryption, /^wpa[23]?([+-]|$)/) ? 'eap'
             : (encryption == 'none' || !length(encryption)) ? 'open' : 'psk';
    if (!encryption || !encryption.enabled) return 'open';
    for (let a in (encryption.authentication || []))
        if (a == '802.1x') return 'eap';
    return 'psk';
};

status = function() {
    const uci = cursor();
    const ap = runJson('/usr/sbin/pulzr-ap status') || { capable: false };
    // Where the console is from the AP. It hands out no DNS, so this is the
    // address to open, and the same on every gateway.
    ap.address = uci.get('network', 'setup', 'ipaddr') || null;

    // The ethernet port does not have a role to report. It holds every
    // address at once — a DHCP lease for the backhaul, the fixed console
    // address, and a link-local address for a directly-connected laptop — so
    // what the console shows is simply which of those are currently up.
    //
    // Which port that is, pulzr-ports decides: the board's uplink port
    // while it is an uplink, else the first port that is one. The lease is
    // the uplink's on that same port, untagged.
    const port = uci.get('network', 'console', 'device') || 'eth0';
    let uplinkIface = null;
    uci.foreach('network', 'interface', (s) => {
        if (!uplinkIface && match(s['.name'], /^wan(_[A-Za-z0-9_]+)?$/) && s.device == port)
            uplinkIface = s['.name'];
    });
    const lease = uplinkIface ? (runJson(sprintf('ubus call network.interface.%s status', uplinkIface)) || {}) : {};
    const wired = lease['ipv4-address'] && length(lease['ipv4-address'])
                  ? lease['ipv4-address'][0].address : null;

    return {
        ap: ap,
        port: {
            iface: port,
            // Off when no port is an uplink: a LAN port answers instead.
            enabled: uci.get('network', 'console', 'disabled') != '1',
            // Where to point a browser. Both always work; the link-local name
            // is the one to read out to somebody with a laptop and a cable,
            // because it needs nothing configured at either end.
            hostname: trim(readfile('/proc/sys/kernel/hostname') || 'pulzr'),
            console: uci.get('network', 'console', 'ipaddr'),
            linkLocal: uci.get('network', 'linklocal', 'ipaddr'),
            // The lease, if the cable reached a network with a DHCP server.
            // Absent is not an error: on a bench there is nothing to lease from
            // and the two static addresses carry the console regardless.
            uplink: wired,
            // Stated rather than implied. The gateway never serves DHCP on this
            // port — see 20-pulzr-network — and an installer who expects an
            // address from it should be told so plainly rather than left to
            // wonder why their laptop did not get one.
            servesDhcp: false,
        },
        // The USB device port, on a board built with one (pulzr-usb-gadget):
        // whether a laptop is on the other end, and where it reaches the
        // console. Null on a board without one. As thin as the rest of this:
        // an address that is the same on every gateway, and nothing else.
        usb: runJson('[ -x /usr/sbin/pulzr-usb-gadget ] && /usr/sbin/pulzr-usb-gadget status'),
        // The LAN ports' address, where a laptop on one finds the console.
        // Null on a board without them. The same on every gateway.
        lan: uci.get('network', 'devlan', 'ipaddr') || null,
        adopted: uci.get('pulzr', 'adoption', 'state') == 'adopted',
        // The WiFi uplink, if one has been joined. Distinct from `ap` above:
        // that is the radio serving a setup network, this is the radio using
        // somebody else's. They share one chip and are rarely both wanted.
        wifi: (() => {
            // Compat: the wireless section ids parkeze_sta and parkeze_ap are kept from ParkezeOS; a gateway
            // upgraded or rolled back keeps its saved WiFi only if both images agree on them.
            const ssid = uci.get('wireless', 'parkeze_sta', 'ssid');
            if (!ssid) return { configured: false };
            const link = runJson('ubus call network.interface.wwifi status') || {};
            const addresses = link['ipv4-address'] || [];
            // Signal and MAC, from the station interface the radio actually
            // created for this section; its name is the driver's choice, not
            // ours. The MAC is what a site's IT registers to let the gateway
            // past a portal for good.
            let signal = null, mac = null;
            const radios = runJson('ubus call network.wireless status') || {};
            for (let name in radios)
                for (let iface in (radios[name].interfaces || []))
                    if (iface.section == 'parkeze_sta' && iface.ifname) {
                        const info = runJson(sprintf('ubus call iwinfo info \'{"device":"%s"}\'', iface.ifname)) || {};
                        signal = info.signal ?? null;
                        mac = trim(readfile(sprintf('/sys/class/net/%s/address', iface.ifname)) || '') || null;
                    }
            return {
                configured: true,
                ssid: ssid,
                // The kind, and nothing more: this endpoint is public, and
                // the username and pinned certificate are behind sign-in in
                // wifiDetail().
                security: security(uci.get('wireless', 'parkeze_sta', 'encryption')),
                up: link.up == true,
                // Whether it reaches the internet or only a sign-in page — see
                // pulzr-wifi-uplink. The portal's address is behind sign-in,
                // in wifiDetail().
                uplink: signin.uplink().state,
                address: length(addresses) ? addresses[0].address : null,
                addresses: map(addresses, (a) => sprintf('%s/%d', a.address, a.mask)),
                signal: signal,
                mac: mac,
            };
        })(),
    };
};

// The AP passphrase.
//
// Behind authentication, and behind adoption: on an unadopted gateway the AP is
// open and there is no passphrase to show. Returning it to an authenticated
// session is the point — an operator on the console needs to be able to read it
// out to somebody standing at the device.
key = function() {
    const uci = cursor();
    if (uci.get('pulzr', 'adoption', 'state') != 'adopted')
        return { open: true, key: null,
                 note: 'This gateway is not adopted, so its setup network is '
                     + 'open. It becomes password-protected on adoption.' };

    const value = run('/usr/sbin/pulzr-ap key');
    if (!value) return { error: 'No AP key has been generated yet.' };
    return { open: false, key: value };
};

setAp = function(req) {
    const uci = cursor();

    if (req.enabled != null) {
        uci.set('pulzr', 'ap', 'enabled', req.enabled ? '1' : '0');
        // Turning the master switch off takes down anything already up, rather
        // than leaving a radio broadcasting until the next watchdog tick.
        if (!req.enabled) run('/usr/sbin/pulzr-ap down >/dev/null 2>&1');
    }

    if (req.fallback != null)
        uci.set('pulzr', 'ap', 'fallback', req.fallback ? '1' : '0');

    if (req.button != null)
        uci.set('pulzr', 'ap', 'button', req.button ? '1' : '0');

    if (req.fallbackAfter != null) {
        const seconds = int(req.fallbackAfter);
        // A floor of five minutes. Below that a gateway on a flaky SIM spends
        // its life raising and dropping a radio, which is both useless and the
        // kind of thing that shows up as interference in someone's site survey.
        if (seconds < 300 || seconds > 86400)
            return { error: 'Fallback delay must be between 5 minutes and a day.' };
        uci.set('pulzr', 'ap', 'fallback_after', sprintf('%d', seconds));
    }

    if (req.window != null) {
        const seconds = int(req.window);
        // 0 means "until told otherwise", which is legitimate for a bench unit
        // and a bad idea on a pole — the UI says so rather than forbidding it.
        if (seconds != 0 && (seconds < 300 || seconds > 86400))
            return { error: 'The window must be 0, or between 5 minutes and a day.' };
        uci.set('pulzr', 'ap', 'window', sprintf('%d', seconds));
    }

    uci.commit('pulzr');
    return { ok: true, status: status() };
};

// Raise the AP now, from an authenticated session.
//
// Marked manual, so the watchdog does not helpfully take it down again the
// moment it notices the backhaul is fine — somebody asked for this.
raiseAp = function(req) {
    const window = req.window != null ? int(req.window) : 1800;
    run(sprintf('mkdir -p /var/run/pulzr/ap; echo 1 > /var/run/pulzr/ap/manual'));
    const output = run(sprintf('/usr/sbin/pulzr-ap up %d 2>&1', window));
    if (output == null) return { error: 'Could not raise the access point.' };
    return { ok: true, status: status() };
};

lowerAp = function() {
    run('rm -f /var/run/pulzr/ap/manual');
    run('/usr/sbin/pulzr-ap down >/dev/null 2>&1');
    return { ok: true, status: status() };
};

// ── joining a WiFi network ──────────────────────────────────────────────────

// Networks in range, for the portal's picker.
//
// Behind authentication like everything else that writes — but this only
// reads, and it reads the *air*, not the gateway. Still gated, because a survey
// of every SSID at a customer site is site intelligence we should not hand to
// somebody who has merely associated to an open AP.
//
// `phy` scans that radio alone (radios.uc's scan): the radios page asking
// whether a network is heard on the 5 GHz radio, not on either.
scan = function(phy) {
    const radio = run("uci -q show wireless | sed -n 's/^wireless\\.\\([^.]*\\)=wifi-device$/\\1/p' | head -n1");
    if (!radio) return { capable: false, networks: [] };

    // Every radio, each through an interface it already has when it has one.
    //
    // The phy alone used to be scanned, the first one: iwinfo scans a bare
    // phy by bringing up a temporary interface of its own, which is what a
    // radio with nothing up (every radio until the AP is raised or a network
    // joined) needs. But on a radio already joined to a network that scan
    // came back empty, and on the Opal the first radio is the one joined, so
    // the wizard listed nothing while seventeen networks were in range; the
    // station interface on that radio scans fine. And the first radio only
    // ever saw one band: the Opal's second one is the 5 GHz one.
    const ifaceOf = {};
    for (let dev in (_m_fs.lsdir('/sys/class/net') ?? [])) {
        const phy = trim(readfile(sprintf('/sys/class/net/%s/phy80211/name', dev)) ?? '');
        if (length(phy) && !ifaceOf[phy]) ifaceOf[phy] = dev;
    }
    const best = {};
    let answered = false;
    for (let p in (_m_fs.lsdir('/sys/class/ieee80211') ?? [])) {
        if (phy != null && p != phy) continue;
        const device = ifaceOf[p] ?? p;
        if (!match(device, /^[A-Za-z0-9._-]{1,32}$/)) continue;
        const raw = runJson(sprintf('ubus call iwinfo scan \'{"device":"%s"}\'', device));
        if (!raw) continue;
        answered = true;
        for (let entry in (raw.results || [])) {
            if (!entry.ssid) continue;
            // One row a network, at its strongest: the same SSID on both
            // bands, or from several access points, is one choice.
            if (best[entry.ssid] && best[entry.ssid].signal >= entry.signal) continue;
            best[entry.ssid] = {
                ssid: entry.ssid,
                signal: entry.signal,
                quality: entry.quality,
                encryption: security(entry.encryption),
            };
        }
    }
    if (!answered) return { capable: true, networks: [],
                            error: 'The scan returned nothing.' };
    const networks = map(keys(best), (k) => best[k]);
    return { capable: true, networks: networks };
};

// ── saved networks ──────────────────────────────────────────────────────────
//
// Every network joined is remembered, the way a phone does: a `wifi_network`
// section in /etc/config/pulzr per SSID, holding what it takes to join
// again — the kind, the passphrase or the EAP credentials, and the pinned
// RADIUS certificate. /etc/config survives sysupgrade, so they do too.
//
// Two things use them. A technician can rejoin one from the list without
// typing a password they may not have with them. And roam() moves a gateway
// whose network has gone away onto another remembered network in range —
// a unit carried from one building to another comes back up on its own.

const SAVED = 'wifi_network';
const ROAM_AFTER = 180;     // seconds of a dead uplink before looking elsewhere
const ROAM_BACKOFF = 300;   // and not again for this long after a switch
const ROAM_STATE = '/var/run/pulzr-wifi-roam.json';
// The last few switches roam() made, for the console to say why the gateway
// is on the network it is on. In /var/run: a restart of pulzr-wifi-roam keeps
// it, a reboot does not, and it is never a write to flash.
const ROAM_LOG = '/var/run/pulzr/wifi-roams.json';
const ROAM_LOG_KEEP = 10;

savedNetworks = function(uci) {
    const found = [];
    uci.foreach('pulzr', SAVED, (s) => { push(found, s); });
    return found;
};

findSaved = function(uci, ssid) {
    for (let s in savedNetworks(uci))
        if (s.ssid == ssid) return s;
    return null;
};

// The request, as a network: {ssid, security, key | eap}. An error string
// when it cannot be joined as given.
networkFromRequest = function(req) {
    const ssid = req.ssid;
    if (!ssid || !length(ssid) || length(ssid) > 32)
        return { error: 'Give the network a name.' };

    const eap = type(req.eap) == 'object' ? req.eap : null;
    if (eap) {
        if (eap.method != 'peap' && eap.method != 'ttls')
            return { error: 'Choose PEAP or TTLS.' };
        const phase2 = eap.phase2 || 'MSCHAPV2';
        if (phase2 != 'MSCHAPV2' && !(eap.method == 'ttls' && phase2 == 'PAP'))
            return { error: 'That inner method is not supported.' };
        if (!eap.identity || length(eap.identity) > 128)
            return { error: 'Give the username.' };
        if (eap.anonymousIdentity && length(eap.anonymousIdentity) > 128)
            return { error: 'That outer identity is too long.' };
        if (!eap.password || length(eap.password) > 128)
            return { error: 'Give the password.' };
        // A pinned certificate is required, not offered. Without one the
        // gateway would hand this account's password to any access point
        // calling itself by this name — see pulzr-wifi-probe.
        if (type(eap.certHash) != 'string' || !match(eap.certHash, /^[0-9a-f]{64}$/))
            return { error: "Check the network's certificate first." };
        return { ssid, security: 'eap', eap_type: eap.method, auth: phase2,
                 identity: eap.identity, anonymous_identity: eap.anonymousIdentity || null,
                 password: eap.password, cert_hash: eap.certHash,
                 cert_subject: substr(eap.certSubject || '', 0, 256) };
    }

    // An open network as a gateway's uplink carries our MQTT traffic and our
    // management plane over something anybody can read and inject into.
    // Allowed only when explicitly acknowledged, so it cannot happen by
    // accident.
    if (!req.key && !req.allowOpen)
        return { error: 'That network has no password. If it is genuinely open, '
                      + 'confirm it explicitly — an open uplink carries this '
                      + "gateway's traffic in the clear." };
    if (req.key && (length(req.key) < 8 || length(req.key) > 63))
        return { error: 'A WPA passphrase is 8 to 63 characters.' };
    return { ssid, security: req.key ? 'psk' : 'open', key: req.key || null };
};

saveNetwork = function(uci, net) {
    const existing = findSaved(uci, net.ssid);
    const name = existing ? existing['.name'] : uci.add('pulzr', SAVED);
    for (let option in ['security', 'key', 'eap_type', 'auth', 'identity',
                        'anonymous_identity', 'password', 'cert_hash', 'cert_subject'])
        uci.delete('pulzr', name, option);
    for (let option in keys(net))
        if (net[option] != null) uci.set('pulzr', name, option, '' + net[option]);
    uci.set('pulzr', name, 'last_joined', '' + time());
};

// Point the station at `net`. Writes, does not commit or reload. `slot` is
// which station: this module's (the default), or radios.uc's second one.
applyNetwork = function(uci, radio, net, slot) {
    const sta = (slot ?? PRIMARY).section, wan = (slot ?? PRIMARY).iface;
    // Enabling the radio below also enables anything else on it, and OpenWrt
    // ships an open AP named "OpenWrt" on the LAN there. On a single-radio
    // chip it also drops this station every second. See 60-pulzr-ap.
    // The access points made on the WiFi page (pulzr_ap_*, lib/radios.uc)
    // are ours too.
    const foreign = [];
    uci.foreach('wireless', 'wifi-iface', (s) => {
        if (!match(s['.name'], /^(parkeze|pulzr)_/)) push(foreign, s['.name']);
    });
    for (let name in foreign) uci.delete('wireless', name);

    uci.set('wireless', sta, 'wifi-iface');
    uci.set('wireless', sta, 'device', radio);
    uci.set('wireless', sta, 'mode', 'sta');
    uci.set('wireless', sta, 'network', wan);
    uci.set('wireless', sta, 'ssid', net.ssid);
    // One section, reused for whichever kind of network this is, so the
    // options of the other kind are cleared rather than left to confuse it.
    for (let option in ['key', 'eap_type', 'auth', 'identity',
                        'anonymous_identity', 'password', 'ca_cert'])
        uci.delete('wireless', sta, option);
    if (net.security == 'eap') {
        // 'wpa2' is WPA2-Enterprise to netifd; it also joins the WPA3
        // networks that still accept WPA2 clients, which is all of eduroam.
        uci.set('wireless', sta, 'encryption', 'wpa2');
        uci.set('wireless', sta, 'eap_type', net.eap_type);
        uci.set('wireless', sta, 'auth', net.auth || 'MSCHAPV2');
        uci.set('wireless', sta, 'identity', net.identity);
        if (net.anonymous_identity)
            uci.set('wireless', sta, 'anonymous_identity', net.anonymous_identity);
        uci.set('wireless', sta, 'password', net.password);
        // The server certificate itself, by hash: only that server gets the
        // password. When it is renewed the gateway stops connecting, and the
        // console shows the new certificate to be checked — the same thing a
        // phone asks, with somebody to look at it.
        uci.set('wireless', sta, 'ca_cert', 'hash://server/sha256/' + net.cert_hash);
    } else {
        uci.set('wireless', sta, 'encryption', net.key ? 'psk2' : 'none');
        if (net.key) uci.set('wireless', sta, 'key', net.key);
    }
    uci.set('wireless', sta, 'disabled', '0');
    // The radio as well as the interface. Stock OpenWrt ships the radio
    // disabled and only the setup AP ever turned it on, so a join on a
    // gateway whose AP had never been raised configured a network on a radio
    // that was off, and never came up.
    uci.set('wireless', radio, 'disabled', '0');

    // Its own interface in the wan zone. Behind cellular until
    // pulzr-wifi-uplink has seen it reach the internet, which moves it to
    // 15, between wired and cellular: better than paying for data, worse than
    // a cable. A guest network has a lease long before it carries anything.
    //
    // A second radio's station starts behind everything instead, whatever
    // the order: it is joining beside a WiFi uplink that is carrying the
    // traffic, at a metric that may be worse than 30 (40 for the fourth in
    // the order), and must not take the default route before it is proven.
    // pulzr-uplinks sets its real metric on the first answer.
    uci.set('network', wan, 'interface');
    uci.set('network', wan, 'proto', 'dhcp');
    uci.set('network', wan, 'metric', wan == PRIMARY.iface ? '30' : '200');

    // Into the wan zone with the wired uplink. An interface in no zone falls
    // to fw4's default chains — safe, because 20-pulzr-network sets those to
    // DROP, but none of the zone's rules apply to it and nothing says why. The
    // far side is somebody else's network exactly as the ethernet case is, so
    // it gets the same answer: nothing reachable inbound.
    const zone = uci.get('firewall', 'wan', 'network') || '';
    if (!(wan in split(zone, ' ')))
        uci.set('firewall', 'wan', 'network', trim(zone + ' ' + wan));
};

// The radio the uplink is on: `wanted` when it is one (the radios page
// moving it), else the one it is on now, else the first. Not always the
// first: on a repeater the uplink may be the second radio, and a rejoin from
// the WiFi page or a roam must not move it back onto the AP's.
radioName = function(wanted) {
    const uci = cursor();
    if (wanted != null)
        return type(wanted) == 'string' && match(wanted, /^[A-Za-z0-9_]{1,32}$/)
            && uci.get('wireless', wanted) == 'wifi-device' ? wanted : null;
    const current = uci.get('wireless', 'parkeze_sta', 'device');
    if (current && uci.get('wireless', current) == 'wifi-device') return current;
    return run("uci -q show wireless | sed -n 's/^wireless\\.\\([^.]*\\)=wifi-device$/\\1/p' | head -n1");
};

// Commit and bring the station up in the background: bringing the radio down
// takes the caller's own connection with it if they are on the setup AP, and
// the reply has to get out first. The tunnel is re-homed too — WiFi is an
// egress it may use, and nothing else would tell it so until the next ifup.
//
// Only the slot's own interface is ifup'd. /sbin/ifup is a down and an up,
// and on the other WiFi uplink that would be the break this exists to avoid.
// `wifi reload` restarts only the radios whose configuration changed.
commitAndReload = function(uci, slot) {
    const wan = (slot ?? PRIMARY).iface;
    uci.commit('wireless');
    uci.commit('network');
    uci.commit('firewall');
    uci.commit('pulzr');
    run(sprintf('(sleep 2; wifi reload; /sbin/ifup %s; /etc/init.d/firewall reload; '
        + '/usr/sbin/pulzr-wireguard-route apply) >/dev/null 2>&1 &', wan));
    // pulzr-wifi-uplink's answer is about the network being left. Kept, it
    // was this one's until the next check, and roam() read a guest network's
    // portal as the verdict on the eduroam just joined in its place.
    unlink(wan == PRIMARY.iface ? '/var/run/pulzr/wifi-uplink.json' : sprintf('/var/run/pulzr/wifi-uplink-%s.json', wan));
};

// A station, its interface and its place in the wan zone. Writes, does not
// commit. The zone by word: a pattern for wwifi also matched inside wwifi2.
removeStation = function(uci, slot) {
    uci.delete('wireless', slot.section);
    uci.delete('network', slot.iface);
    const zone = uci.get('firewall', 'wan', 'network') || '';
    uci.set('firewall', 'wan', 'network',
            join(' ', filter(split(zone, ' '), (n) => length(n) && n != slot.iface)));
};

// Put a WiFi uplink last in the order before it goes, so the default route
// and the tunnel move to whatever is next while it is still associated,
// rather than after it has gone. pulzr-uplinks runs the tunnel's and LoRa's
// apply when the metrics change.
demote = function(wan) {
    const st = runJson('/usr/sbin/pulzr-uplinks status 2>/dev/null');
    const order = filter(st?.order ?? [], (n) => n != wan && match(n, /^[A-Za-z0-9_]{1,15}$/));
    if (length(order) && wan in (st?.order ?? []))
        run(sprintf('/usr/sbin/pulzr-uplinks order %s %s >/dev/null 2>&1', join(' ', order), wan));
};

// `slot` is for lib/radios.uc alone, never a request's: which station joins.
joinWifi = function(req, slot) {
    const uci = cursor();
    let net;
    if (req.saved) {
        // Rejoin from the list: everything but the name comes from what was
        // saved, so nobody has to know the password to put a gateway back.
        const saved = findSaved(uci, req.ssid);
        if (!saved) return { error: 'That network is not saved on this gateway.' };
        net = {};
        for (let k in keys(saved))
            if (substr(k, 0, 1) != '.' && k != 'last_joined') net[k] = saved[k];
    } else {
        net = networkFromRequest(req);
        if (net.error) return net;
    }

    const radio = radioName(req.radio);
    if (!radio) return { error: req.radio != null ? 'No such radio.' : 'This board has no WiFi radio.' };

    applyNetwork(uci, radio, net, slot);
    saveNetwork(uci, net);
    commitAndReload(uci, slot);
    // `iface`: what apply.guard watches to keep the change once it works.
    if (slot && slot.iface != PRIMARY.iface) return { ok: true, iface: slot.iface, message: 'Joining ' + net.ssid + '.' };
    // A join starts roam()'s clock again and holds it off as a switch does.
    // The clock used to carry on from the network before: a gateway that had
    // sat behind a guest portal for an hour was joined to eduroam, and the
    // next minute, before eduroam had finished coming up, roam() found three
    // minutes long gone and put it back on the guest network.
    writefile(ROAM_STATE, sprintf('%J', { roamedAt: time() }));

    return { ok: true, iface: PRIMARY.iface,
             message: 'Joining ' + net.ssid + '. If you are connected to the setup '
                    + 'network, it will drop while the radio switches over.' };
};

// Leave the network, and stop remembering it; or, with `keep`, only leave
// it (Disconnect), so joining it again is one click and no password.
//
// The way back from a joined network that does not work. Without it the only
// way off a WiFi uplink whose password has changed is a serial cable, which
// on a roof is the same as a truck. A kept network is not rejoined behind
// anybody's back: roam() does nothing without a station.
forgetWifi = function(req) {
    const uci = cursor();
    const active = uci.get('wireless', 'parkeze_sta', 'ssid');
    const ssid = (req && req.ssid) || active;
    if (!ssid) return { ok: true, message: 'No WiFi network is configured.' };

    const saved = findSaved(uci, ssid);
    if (saved && !req?.keep) uci.delete('pulzr', saved['.name']);
    uci.commit('pulzr');

    if (ssid != active) return { ok: true, message: 'Forgot ' + ssid + '.' };

    // Another radio's WiFi uplink, or anything else, takes over first.
    demote(PRIMARY.iface);
    removeStation(uci, PRIMARY);
    uci.commit('wireless');
    uci.commit('network');
    uci.commit('firewall');

    // Backgrounded for the same reason as joining.
    run('(sleep 2; wifi reload; /etc/init.d/firewall reload; '
        + '/usr/sbin/pulzr-wireguard-route apply) >/dev/null 2>&1 &');

    return { ok: true, message: 'Left ' + ssid + '.' };
};

// Move to another remembered network when this one has been gone a while.
//
// Gone means down, or up and not reaching the internet: behind a portal, or
// answering nothing (pulzr-wifi-uplink). Not while somebody is signing in to
// that portal, which a scan would take off the air under them.
//
// Called once a minute by pulzr-wifi-roam. Deliberately slow and
// conservative: three minutes of a dead uplink before scanning, a remembered
// network only (never a new one), the strongest of those in range, and not
// again for five minutes after a switch, so two weak networks at the edge of
// range do not get traded back and forth all afternoon. Never while the
// setup AP is up: a scan on a single radio takes it off the air, and the
// person on it is presumably fixing things already.
roam = function() {
    const uci = cursor();
    const active = uci.get('wireless', 'parkeze_sta', 'ssid');
    if (!active) return { action: 'none', reason: 'no wifi uplink' };
    if (uci.get('wireless', 'parkeze_ap')) return { action: 'none', reason: 'setup AP is up' };
    if (signin.active()) return { action: 'none', reason: 'signing in' };

    let state = {};
    try { state = json(readfile(ROAM_STATE) || '{}') || {}; } catch (e) { state = {}; }
    const now = time();
    const link = runJson('ubus call network.interface.wwifi status') || {};
    const uplink = signin.uplink();
    const reached = uplink.state;
    if (link.up && reached != 'portal' && reached != 'offline') {
        writefile(ROAM_STATE, sprintf('%J', { roamedAt: state.roamedAt }));
        return { action: 'none', reason: 'up' };
    }
    if (!state.downSince) {
        state.downSince = now;
        writefile(ROAM_STATE, sprintf('%J', state));
        return { action: 'none', reason: 'just went down' };
    }
    if (now - state.downSince < ROAM_AFTER) return { action: 'none', reason: 'waiting' };
    if (state.roamedAt && now - state.roamedAt < ROAM_BACKOFF)
        return { action: 'none', reason: 'backing off' };

    const others = {};
    for (let s in savedNetworks(uci))
        if (s.ssid != active) others[s.ssid] = s;
    if (!length(keys(others))) return { action: 'none', reason: 'nothing else saved' };

    const heard = scan().networks || [];
    let best = null;
    for (let n in heard)
        if (others[n.ssid] && (!best || n.quality > best.quality)) best = n;
    if (!best) return { action: 'none', reason: 'no saved network in range' };

    const saved = others[best.ssid];
    const net = {};
    for (let k in keys(saved))
        if (substr(k, 0, 1) != '.' && k != 'last_joined') net[k] = saved[k];
    const radio = radioName();
    if (!radio) return { action: 'none', reason: 'no radio' };
    // Why, as it stood when the decision was made: the check's failing step
    // while associated, wpa_supplicant's reason while not.
    let why;
    if (link.up) why = { state: reached, step: uplink.step, host: uplink.host, detail: uplink.detail };
    else {
        const failure = wififail.last();
        why = { state: 'down', step: failure?.code, detail: failure?.detail };
    }
    why.downFor = now - state.downSince;
    recordRoam({ at: now, from: active, to: best.ssid, why });

    applyNetwork(uci, radio, net);
    saveNetwork(uci, net);
    commitAndReload(uci);
    writefile(ROAM_STATE, sprintf('%J', { roamedAt: now }));
    return { action: 'switched', from: active, to: best.ssid, why };
};

// Why the uplink is not open, as the end of one sentence the console starts
// with the network's name: "eduroam: DNS 10.0.0.1 did not answer." Null when
// it is open, or when the badge already says it all (a portal's redirect).
// The steps are pulzr-wifi-uplink's.
uplinkReason = function(u) {
    const servers = join(', ', split(u.detail ?? '', ' '));
    switch (u.step) {
    case 'no_gateway':      return 'the lease has no gateway.';
    case 'no_dns':          return 'the lease has no DNS server.';
    case 'dns':             return sprintf('DNS %s did not answer.', servers);
    case 'dns_noaddress':   return sprintf('DNS %s has no address for %s.', servers, u.host);
    case 'connect':         return sprintf('%s at %s refused the connection.', u.host, u.detail);
    case 'connect_timeout': return sprintf('%s at %s did not answer.', u.host, u.detail);
    case 'http_timeout':    return sprintf('%s accepted the connection and sent nothing.', u.host);
    case 'http':            return sprintf('the request to %s failed (curl %s).', u.host, u.detail);
    case 'code':            return sprintf('%s answered %s.', u.host, u.detail);
    case 'dns_hijack':      return sprintf('DNS sends %s to %s.', u.host, u.detail);
    case 'tls':             return sprintf('%s has a certificate this gateway does not trust.', u.host);
    }
    return u.state == 'offline' ? 'no internet.' : null;
};

// Why roam() left a network, short, with how long it waited: "DNS did not
// answer for 3 min".
roamReason = function(why) {
    const short = {
        no_gateway: 'no gateway', no_dns: 'no DNS server', dns: 'DNS did not answer',
        dns_noaddress: 'DNS had no address', connect: 'connections refused',
        connect_timeout: 'no answer', http_timeout: 'no answer', http: 'no answer',
        code: 'unexpected answers', dns_hijack: 'a sign-in page', tls: 'a sign-in page',
        portal: 'a sign-in page',
    };
    const what = why?.state == 'down' ? 'not connected'
               : (short[why?.step] ?? (why?.state == 'portal' ? 'a sign-in page' : 'no internet'));
    const minutes = int(((why?.downFor ?? 0) + 30) / 60);
    return minutes > 0 ? sprintf('%s for %d min', what, minutes) : what;
};

roams = function() {
    try { return json(readfile(ROAM_LOG) || '[]') || []; } catch (e) { return []; }
};

recordRoam = function(entry) {
    const all = roams();
    push(all, entry);
    mkdir('/var/run/pulzr');
    writefile(ROAM_LOG + '.tmp', sprintf('%J', slice(all, -ROAM_LOG_KEEP)));
    _m_fs.rename(ROAM_LOG + '.tmp', ROAM_LOG);
};

// Ask pulzr-wifi-uplink again now rather than at the next minute: after
// signing in to a portal, somebody wants to see it open. In the background,
// because the check can take most of a minute on a network that answers
// nothing; the console polls for the answer.
checkWifi = function() {
    if (!cursor().get('wireless', 'parkeze_sta', 'ssid')) return { error: 'No WiFi network is joined.' };
    run('/usr/sbin/pulzr-wifi-uplink check >/dev/null 2>&1 &');
    return { ok: true };
};

// Which certificate an enterprise network's RADIUS server presents.
//
// Started here, run by pulzr-wifi-probe in the background, read back with
// probeResult(). The request goes through a file rather than the command
// line: an SSID and a username are anybody's text, and a file has nothing to
// quote. Only the outer identity is sent — the probe stops before phase 2, so
// there is no password to send.
probeWifi = function(req) {
    const ssid = req.ssid;
    if (!ssid || !length(ssid) || length(ssid) > 32)
        return { error: 'Give the network a name.' };
    const method = req.method == 'ttls' ? 'ttls' : 'peap';
    const outer = req.anonymousIdentity || req.identity;
    if (!outer || length(outer) > 128)
        return { error: 'Give the username.' };

    writefile(PROBE_OUT, sprintf('%J', { state: 'probing', ssid: ssid, chain: [] }));
    writefile(PROBE_REQ, sprintf('%J', { ssid: ssid, method: method, identity: outer }));
    run('/usr/sbin/pulzr-wifi-probe >/dev/null 2>&1 &');
    return { ok: true, state: 'probing' };
};

probeResult = function() {
    const raw = readfile(PROBE_OUT);
    if (!raw) return { state: 'none', chain: [] };
    try { return json(raw); } catch (e) { return { state: 'none', chain: [] }; }
};

// The joined network's credentials and pinned certificate — never the
// password. Behind sign-in, unlike status().
wifiDetail = function() {
    const uci = cursor();
    const ssid = uci.get('wireless', 'parkeze_sta', 'ssid');
    const saved = map(savedNetworks(uci), (n) => ({
        ssid: n.ssid,
        security: n.security,
        identity: n.identity,
        certSubject: n.cert_subject,
        certHash: n.cert_hash,
        lastJoined: n.last_joined ? int(n.last_joined) : null,
        active: n.ssid == ssid,
    }));
    if (!ssid) return { configured: false, saved };
    const current = findSaved(uci, ssid) || {};
    const reached = signin.uplink();
    const last = roams();
    return {
        configured: true,
        ssid: ssid,
        // Where the network's sign-in page is, while it has one.
        portal: reached.state == 'portal' ? reached.url : null,
        // pulzr-wifi-uplink's answer: the state, and for anything but open
        // the step that failed (see its header).
        uplink: { state: reached.state, step: reached.step, host: reached.host, detail: reached.detail,
                  reason: reached.state == 'open' ? null : uplinkReason(reached),
                  since: reached.since, checkedAt: reached.checkedAt },
        // The last switch roam() made, newest last in the log.
        roam: length(last) ? { ...last[length(last) - 1], reason: roamReason(last[length(last) - 1].why) } : null,
        // Why it is not connected, when wpa_supplicant said. The RADIUS
        // server's own words are in it, so it is here and not in status().
        failure: wififail.last(),
        security: security(uci.get('wireless', 'parkeze_sta', 'encryption')),
        method: uci.get('wireless', 'parkeze_sta', 'eap_type'),
        phase2: uci.get('wireless', 'parkeze_sta', 'auth'),
        identity: uci.get('wireless', 'parkeze_sta', 'identity'),
        anonymousIdentity: uci.get('wireless', 'parkeze_sta', 'anonymous_identity'),
        certSubject: current.cert_subject,
        certHash: current.cert_hash,
        saved,
    };
};

// ── module exports ──────────────────────────────────────────────────────────
//
// A returned object, not `export` statements. uhttpd's ucode plugin compiles
// its handler in TEMPLATE mode and loads anything else through loadfile(),
// neither of which is module mode — `export` is a syntax error there. See the
// header of api/index.uc for the full contract.
return { checkWifi, demote, forgetWifi, removeStation, joinWifi, key, lowerAp, probeResult, probeWifi, raiseAp, roam,
         roams, scan, setAp, status, uplinkReason, wifiDetail };
