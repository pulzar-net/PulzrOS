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
let status, key, setAp, raiseAp, lowerAp, scan, joinWifi, forgetWifi;
let security, probeWifi, probeResult, wifiDetail;

let run = _m_util.run;; let runJson = _m_util.runJson;
let writefile = _m_fs.writefile;; let unlink = _m_fs.unlink;

const PROBE_REQ = '/tmp/parkeze-wifi-probe.req';
const PROBE_OUT = '/tmp/parkeze-wifi-probe.json';

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
    const ap = runJson('/usr/sbin/parkeze-ap status') || { capable: false };
    const portal = runJson('/usr/sbin/parkeze-portal status') || { up: false };

    // The ethernet port does not have a role to report. It holds every
    // address at once — a DHCP lease for the backhaul, the fixed console
    // address, and a link-local address for a directly-connected laptop — so
    // what the console shows is simply which of those are currently up.
    const lease = runJson('ubus call network.interface.wan status') || {};
    const wired = lease['ipv4-address'] && length(lease['ipv4-address'])
                  ? lease['ipv4-address'][0].address : null;

    return {
        ap: ap,
        portal: portal,
        port: {
            iface: uci.get('network', 'wan', 'device') || 'eth0',
            // Where to point a browser. Both always work; the link-local name
            // is the one to read out to somebody with a laptop and a cable,
            // because it needs nothing configured at either end.
            hostname: trim(readfile('/proc/sys/kernel/hostname') || 'parkeze'),
            console: uci.get('network', 'console', 'ipaddr'),
            linkLocal: uci.get('network', 'linklocal', 'ipaddr'),
            // The lease, if the cable reached a network with a DHCP server.
            // Absent is not an error: on a bench there is nothing to lease from
            // and the two static addresses carry the console regardless.
            uplink: wired,
            // Stated rather than implied. The gateway never serves DHCP on this
            // port — see 20-parkeze-network — and an installer who expects an
            // address from it should be told so plainly rather than left to
            // wonder why their laptop did not get one.
            servesDhcp: false,
        },
        adopted: uci.get('parkeze', 'adoption', 'state') == 'adopted',
        // The WiFi uplink, if one has been joined. Distinct from `ap` above:
        // that is the radio serving a setup network, this is the radio using
        // somebody else's. They share one chip and are rarely both wanted.
        wifi: (() => {
            const ssid = uci.get('wireless', 'parkeze_sta', 'ssid');
            if (!ssid) return { configured: false };
            const link = runJson('ubus call network.interface.wwifi status') || {};
            const addresses = link['ipv4-address'] || [];
            // Signal, from the station interface the radio actually created
            // for this section; its name is the driver's choice, not ours.
            let signal = null;
            const radios = runJson('ubus call network.wireless status') || {};
            for (let name in radios)
                for (let iface in (radios[name].interfaces || []))
                    if (iface.section == 'parkeze_sta' && iface.ifname) {
                        const info = runJson(sprintf('ubus call iwinfo info \'{"device":"%s"}\'', iface.ifname)) || {};
                        signal = info.signal ?? null;
                    }
            return {
                configured: true,
                ssid: ssid,
                // The kind, and nothing more: this endpoint is public, and
                // the username and pinned certificate are behind sign-in in
                // wifiDetail().
                security: security(uci.get('wireless', 'parkeze_sta', 'encryption')),
                up: link.up == true,
                address: length(addresses) ? addresses[0].address : null,
                signal: signal,
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
    if (uci.get('parkeze', 'adoption', 'state') != 'adopted')
        return { open: true, key: null,
                 note: 'This gateway is not adopted, so its setup network is '
                     + 'open. It becomes password-protected on adoption.' };

    const value = run('/usr/sbin/parkeze-ap key');
    if (!value) return { error: 'No AP key has been generated yet.' };
    return { open: false, key: value };
};

setAp = function(req) {
    const uci = cursor();

    if (req.enabled != null) {
        uci.set('parkeze', 'ap', 'enabled', req.enabled ? '1' : '0');
        // Turning the master switch off takes down anything already up, rather
        // than leaving a radio broadcasting until the next watchdog tick.
        if (!req.enabled) run('/usr/sbin/parkeze-ap down >/dev/null 2>&1');
    }

    if (req.fallback != null)
        uci.set('parkeze', 'ap', 'fallback', req.fallback ? '1' : '0');

    if (req.fallbackAfter != null) {
        const seconds = int(req.fallbackAfter);
        // A floor of five minutes. Below that a gateway on a flaky SIM spends
        // its life raising and dropping a radio, which is both useless and the
        // kind of thing that shows up as interference in someone's site survey.
        if (seconds < 300 || seconds > 86400)
            return { error: 'Fallback delay must be between 5 minutes and a day.' };
        uci.set('parkeze', 'ap', 'fallback_after', sprintf('%d', seconds));
    }

    if (req.window != null) {
        const seconds = int(req.window);
        // 0 means "until told otherwise", which is legitimate for a bench unit
        // and a bad idea on a pole — the UI says so rather than forbidding it.
        if (seconds != 0 && (seconds < 300 || seconds > 86400))
            return { error: 'The window must be 0, or between 5 minutes and a day.' };
        uci.set('parkeze', 'ap', 'window', sprintf('%d', seconds));
    }

    uci.commit('parkeze');
    return { ok: true, status: status() };
};

// Raise the AP now, from an authenticated session.
//
// Marked manual, so the watchdog does not helpfully take it down again the
// moment it notices the backhaul is fine — somebody asked for this.
raiseAp = function(req) {
    const window = req.window != null ? int(req.window) : 1800;
    run(sprintf('mkdir -p /var/run/parkeze/ap; echo 1 > /var/run/parkeze/ap/manual'));
    const output = run(sprintf('/usr/sbin/parkeze-ap up %d 2>&1', window));
    if (output == null) return { error: 'Could not raise the access point.' };
    return { ok: true, status: status() };
};

lowerAp = function() {
    run('rm -f /var/run/parkeze/ap/manual');
    run('/usr/sbin/parkeze-ap down >/dev/null 2>&1');
    return { ok: true, status: status() };
};

// ── joining a WiFi network ──────────────────────────────────────────────────

// Networks in range, for the portal's picker.
//
// Behind authentication like everything else that writes — but this only
// reads, and it reads the *air*, not the gateway. Still gated, because a survey
// of every SSID at a customer site is site intelligence we should not hand to
// somebody who has merely associated to an open AP.
scan = function() {
    const radio = run("uci -q show wireless | sed -n 's/^wireless\\.\\([^.]*\\)=wifi-device$/\\1/p' | head -n1");
    if (!radio) return { capable: false, networks: [] };

    // The phy, not an interface on it. A radio with no interface up — which is
    // every radio until the AP is raised or a network joined, since OpenWrt
    // ships them disabled — has no wlan0 to scan from, and this used to report
    // that as the radio being busy with an AP that was not even on. iwinfo
    // scans a bare phy by bringing up a temporary interface of its own.
    const phy = run('ls /sys/class/ieee80211 2>/dev/null | head -n1');
    const raw = phy ? runJson(sprintf('ubus call iwinfo scan \'{"device":"%s"}\'', phy)) : null;
    if (!raw) return { capable: true, networks: [],
                       error: 'The scan returned nothing.' };

    const seen = {};
    const networks = [];
    for (let entry in (raw.results || [])) {
        if (!entry.ssid || seen[entry.ssid]) continue;
        seen[entry.ssid] = true;
        networks[length(networks)] = {
            ssid: entry.ssid,
            signal: entry.signal,
            quality: entry.quality,
            encryption: security(entry.encryption),
        };
    }
    return { capable: true, networks: networks };
};

joinWifi = function(req) {
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
        // calling itself by this name — see parkeze-wifi-probe.
        if (type(eap.certHash) != 'string' || !match(eap.certHash, /^[0-9a-f]{64}$/))
            return { error: "Check the network's certificate first." };
    }

    // An open network as a gateway's uplink carries our MQTT traffic and our
    // management plane over something anybody can read and inject into. Allowed
    // only when explicitly acknowledged, so it cannot happen by accident.
    if (!eap && !req.key && !req.allowOpen)
        return { error: 'That network has no password. If it is genuinely open, '
                      + 'confirm it explicitly — an open uplink carries this '
                      + "gateway's traffic in the clear." };

    if (!eap && req.key && (length(req.key) < 8 || length(req.key) > 63))
        return { error: 'A WPA passphrase is 8 to 63 characters.' };

    const uci = cursor();
    const radio = run("uci -q show wireless | sed -n 's/^wireless\\.\\([^.]*\\)=wifi-device$/\\1/p' | head -n1");
    if (!radio) return { error: 'This board has no WiFi radio.' };

    uci.set('wireless', 'parkeze_sta', 'wifi-iface');
    uci.set('wireless', 'parkeze_sta', 'device', radio);
    uci.set('wireless', 'parkeze_sta', 'mode', 'sta');
    uci.set('wireless', 'parkeze_sta', 'network', 'wwifi');
    uci.set('wireless', 'parkeze_sta', 'ssid', ssid);
    // One section, reused for whichever kind of network this is, so the
    // options of the other kind are cleared rather than left to confuse it.
    for (let option in ['key', 'eap_type', 'auth', 'identity',
                        'anonymous_identity', 'password', 'ca_cert'])
        uci.delete('wireless', 'parkeze_sta', option);
    if (eap) {
        // 'wpa2' is WPA2-Enterprise to netifd; it also joins the WPA3
        // networks that still accept WPA2 clients, which is all of eduroam.
        uci.set('wireless', 'parkeze_sta', 'encryption', 'wpa2');
        uci.set('wireless', 'parkeze_sta', 'eap_type', eap.method);
        uci.set('wireless', 'parkeze_sta', 'auth', eap.phase2 || 'MSCHAPV2');
        uci.set('wireless', 'parkeze_sta', 'identity', eap.identity);
        if (eap.anonymousIdentity)
            uci.set('wireless', 'parkeze_sta', 'anonymous_identity', eap.anonymousIdentity);
        uci.set('wireless', 'parkeze_sta', 'password', eap.password);
        // The server certificate itself, by hash: only that server gets the
        // password. When it is renewed the gateway stops connecting, and the
        // console shows the new certificate to be checked — the same thing a
        // phone asks, with somebody to look at it.
        uci.set('wireless', 'parkeze_sta', 'ca_cert', 'hash://server/sha256/' + eap.certHash);
        uci.set('parkeze', 'wifi', 'wifi');
        uci.set('parkeze', 'wifi', 'cert_hash', eap.certHash);
        uci.set('parkeze', 'wifi', 'cert_subject', substr(eap.certSubject || '', 0, 256));
        uci.commit('parkeze');
    } else {
        uci.set('wireless', 'parkeze_sta', 'encryption', req.key ? 'psk2' : 'none');
        if (req.key) uci.set('wireless', 'parkeze_sta', 'key', req.key);
        uci.delete('parkeze', 'wifi');
        uci.commit('parkeze');
    }
    uci.set('wireless', 'parkeze_sta', 'disabled', '0');
    // The radio as well as the interface. Stock OpenWrt ships the radio
    // disabled and only the setup AP ever turned it on, so a join on a gateway
    // whose AP had never been raised configured a network on a radio that was
    // off, and never came up.
    uci.set('wireless', radio, 'disabled', '0');

    // Its own interface in the wan zone, with a metric between wired and
    // cellular: better than paying for data, worse than a cable.
    uci.set('network', 'wwifi', 'interface');
    uci.set('network', 'wwifi', 'proto', 'dhcp');
    uci.set('network', 'wwifi', 'metric', '15');

    // Into the wan zone with the wired uplink, which it was not before.
    // An interface in no zone falls to fw4's default chains — safe, because
    // 20-parkeze-network sets those to DROP, but it also means none of the
    // zone's rules apply to it and nothing says why. The far side is somebody
    // else's network exactly as the ethernet case is, so it belongs in the
    // same zone and gets the same answer: nothing reachable inbound.
    const zone = uci.get('firewall', 'wan', 'network') || '';
    if (index(zone, 'wwifi') < 0)
        uci.set('firewall', 'wan', 'network', trim(zone + ' wwifi'));

    uci.commit('wireless');
    uci.commit('network');
    uci.commit('firewall');

    // Applied in the background: bringing the radio down takes the caller's own
    // connection with it if they are on the setup AP, and the reply has to get
    // out first.
    // The tunnel is re-homed too. WiFi is an egress it may use — the reason
    // it stays off cellular is the bill, and there is none here — but nothing
    // would have told it that until the next ifup of something else.
    run('(sleep 2; wifi reload; /sbin/ifup wwifi; /etc/init.d/firewall reload; '
        + '/usr/sbin/parkeze-wireguard-route apply) >/dev/null 2>&1 &');

    return { ok: true,
             message: 'Joining ' + ssid + '. If you are connected to the setup '
                    + 'network, it will drop while the radio switches over.' };
};

// Leave the network, and take the configuration with it.
//
// The way back from a joined network that does not work. Without it the only
// way off a WiFi uplink whose password has changed is a serial cable, which
// on a roof is the same as a truck.
forgetWifi = function() {
    const uci = cursor();
    const ssid = uci.get('wireless', 'parkeze_sta', 'ssid');
    if (!ssid) return { ok: true, message: 'No WiFi network is configured.' };

    uci.delete('wireless', 'parkeze_sta');
    uci.delete('network', 'wwifi');
    uci.delete('parkeze', 'wifi');
    uci.commit('parkeze');
    const zone = uci.get('firewall', 'wan', 'network') || '';
    uci.set('firewall', 'wan', 'network',
            trim(replace(zone, /\s*wwifi\s*/, ' ')));
    uci.commit('wireless');
    uci.commit('network');
    uci.commit('firewall');

    // Backgrounded for the same reason as joining: if the caller is on the
    // setup AP, reloading the radio takes their connection with it, and the
    // reply has to leave first.
    run('(sleep 2; wifi reload; /etc/init.d/firewall reload; '
        + '/usr/sbin/parkeze-wireguard-route apply) >/dev/null 2>&1 &');

    return { ok: true, message: 'Left ' + ssid + '.' };
};

// Which certificate an enterprise network's RADIUS server presents.
//
// Started here, run by parkeze-wifi-probe in the background, read back with
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
    run('/usr/sbin/parkeze-wifi-probe >/dev/null 2>&1 &');
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
    if (!ssid) return { configured: false };
    return {
        configured: true,
        ssid: ssid,
        security: security(uci.get('wireless', 'parkeze_sta', 'encryption')),
        method: uci.get('wireless', 'parkeze_sta', 'eap_type'),
        phase2: uci.get('wireless', 'parkeze_sta', 'auth'),
        identity: uci.get('wireless', 'parkeze_sta', 'identity'),
        anonymousIdentity: uci.get('wireless', 'parkeze_sta', 'anonymous_identity'),
        certSubject: uci.get('parkeze', 'wifi', 'cert_subject'),
        certHash: uci.get('parkeze', 'wifi', 'cert_hash'),
    };
};

// ── module exports ──────────────────────────────────────────────────────────
//
// A returned object, not `export` statements. uhttpd's ucode plugin compiles
// its handler in TEMPLATE mode and loads anything else through loadfile(),
// neither of which is module mode — `export` is a syntax error there. See the
// header of api/index.uc for the full contract.
return { forgetWifi, joinWifi, key, lowerAp, probeResult, probeWifi, raiseAp, scan,
         setAp, status, wifiDetail };
