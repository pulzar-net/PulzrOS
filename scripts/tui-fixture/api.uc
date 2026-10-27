// Canned gateway state, for running the terminal UI off-device with
// scripts/run-tui.sh. It stands in for tui/api.uc: the same shape, every
// value made up. Password `wrong` fails sign-in and `initial` forces a
// password change; applying any adoption bundle adopts.
let adopted = false, asks = 0;
const ok = (extra) => { const r = { ok: true }; for (let k in (extra ?? {})) r[k] = extra[k]; return r; };
const points = [];
for (let i = 0; i < 180; i++) push(points, { t: 1791930000 + i * 20, cpu: 8 + (i * 7 % 23), mem: 61000000 + (i * 97 % 40) * 100000,
    memTotal: 126000000, load: 0.3 + (i % 11) / 10.0, net: { eth0: [ 1200 + (i * 53 % 900), 400 + (i * 31 % 300) ], wwan0: [ 50, 20 ] } });
const sessionFor = (subject, kind, ttl, must) => ({ token: '0000000000000000000000000000000000000000000000000000000000000000',
    subject, kind, expires: time() + ttl, csrf: 'c', mustChangePassword: must });
return {
    auth: {
        loginMethods: () => adopted ? { local: false, sso: true, recovery: true, state: 'adopted', note: null }
                                    : { local: true, sso: false, recovery: false, state: 'unadopted', note: null },
        loginLocal: (u, p, addr) => p == 'wrong' ? { error: 'Incorrect username or password.', status: 401 }
                                                 : { session: sessionFor(u, 'local', 3600, p == 'initial') },
        recoveryChallenge: () => ({ challenge: { code: 'a84041ffff1234ab.9f3c2b1a8e7d6c5b4a39281f.1789330979', expiresIn: 600 }, hostname: 'parkeze-1234ab' }),
        recoveryVerify: (sig, addr) => sig == 'bad' ? { error: 'That signature does not verify.' } : { session: sessionFor('recovery', 'recovery', 1800) },
        // Approved on the third ask, as if somebody took a moment to find
        // their phone.
        terminalStart: () => { asks = 0; return { code: 'K7M2-QP4X', url: 'https://net.parkeze.com/gateway-access#signin=K7M2-QP4X', expiresIn: 600, interval: 3 }; },
        terminalCollect: (code, addr) => ++asks < 3 ? { pending: true } : { session: sessionFor('ops@parkeze.com', 'sso', 3600) },
        readSession: (t) => ({ ok: true }),
        destroySession: (t) => null,
        audit: () => null,
    },
    system: {
        summary: () => ({ identity: { hostname: 'parkeze-1234ab', gatewayEui: 'a84041ffff1234ab', serial: '10000000d3a1234ab', serialSource: 'cpuinfo', board: 'rpi4', boardName: 'Raspberry Pi 4' },
            firmware: { version: '0.2.1', build: '202610131200', commit: '190239c', openwrt: 'OpenWrt 24.10.0 r28427-6df0e3d02a', kernel: '6.6.73' },
            adoption: { state: adopted ? 'adopted' : 'unadopted', org: adopted ? 'Example Parking' : null },
            health: { uptime: 273845, temperature: 51.6 } }),
        stats: () => ({ uptime: 273845, cpu: { model: 'BCM2711', core: 'Cortex-A72', cores: 4, processes: 112, running: 2, total: 1, idle: 1, load: [0.3, 0.4, 0.5] },
            memory: { total: 126000000 }, storage: [ { mount: '/rom', label: 'Firmware', total: 104857600, used: 104857600 }, { mount: '/overlay', label: 'Configuration', total: 3000000000, used: 1200000 }, { mount: '/tmp', label: 'Temporary', total: 63000000, used: 54000000 } ],
            temperatures: [ { name: 'cpu-thermal', celsius: 51.6 } ], power: [], interfaces: [],
            processes: [ { pid: 1201, name: 'chirpstack-conc', rss: 9437184 }, { pid: 980, name: 'ModemManager', rss: 7340032 }, { pid: 1, name: 'procd', rss: 3145728 }, { pid: 640, name: 'uhttpd', rss: 2097152 }, { pid: 700, name: 'dnsmasq', rss: 1048576 } ] }),
        history: (q) => ({ interval: 20, points }),
        processes: () => ({ total: time() * 400, processes: [ { pid: 1, name: 'procd', command: '/sbin/procd', state: 'S', ticks: time() % 97, threads: 1, rss: 3145728 },
            { pid: 1201, name: 'chirpstack-conc', command: '/usr/bin/chirpstack-concentratord-sx1302 -c /var/etc/concentratord.toml', state: 'S', ticks: time() * 3, threads: 4, rss: 9437184 },
            { pid: 2, name: 'kthreadd', command: '', state: 'S', ticks: 0, threads: 1, rss: 0 } ] }),
        logs: (q) => ({ lines: [ 'Tue Oct 13 12:00:01 2026 daemon.info procd: Instance parkeze-packet-forwarder::concentratord0 s in a crash loop',
            'Tue Oct 13 12:00:03 2026 daemon.err mqtt-forwarder[1301]: connection error: Network unreachable',
            'Tue Oct 13 12:00:05 2026 kern.warn kernel: [  12.345] usb 1-1.3: device descriptor read/64, error -71',
            'Tue Oct 13 12:00:07 2026 daemon.notice netifd: Interface \'wan\' is now up',
            'Tue Oct 13 12:00:09 2026 user.info parkeze-claim: registered claim K7M2-QP4X-9RTB' ] }),
        reboot: () => ok(),
    },
    network: {
        status: () => ({ console: { address: '192.168.61.1/24' }, linkLocal: { address: '169.254.61.1/16' },
            wan: { up: true, address: '10.20.0.57/24', gateway: '10.20.0.1', mode: 'dhcp', staticNetmask: null, dns: [] },
            cellular: { up: false, enabled: true, apn: 'iot.1nce.net', address: null, modem: { kind: 'qmi', model: 'EG25-G', network: '1NCE', technology: 'lte', rssi: -71 } } }),
        backhaul: () => ({ wired: { up: true, device: 'eth0', gateway: '10.20.0.1' },
            tunnel: { state: 'up', address: '10.99.4.17', endpoint: 'hub.parkeze.com:51820', lastHandshake: 42 },
            cellular: { up: false, modem: { kind: 'qmi', rssi: -71 } } }),
    },
    lorawan: {
        status: () => ({ concentrator: { status: 'present', slots: 1, present: 1, channels: 8 },
            backhaul: { sending: true, wiredUp: true, wifiUp: false, allowCellular: true }, buffer: { enabled: false } }),
        concentrator: () => ({ configurable: true, region: 'US915', supported: [ { id: 'sx1302_spi', name: 'SX1302 (SPI)', detectable: true }, { id: 'sx1302_uart', name: 'SX1302 (UART)', detectable: false } ] }),
        forwarders: () => ({ region: 'US915', mqtt: { host: 'mqtt.parkeze.com', port: 8883, topicPrefix: 'us915', username: 'gw-a84041ffff1234ab', buffered: false },
            location: { latitude: '43.1566', longitude: '-77.6088', source: 'gps' },
            forwarders: [ { index: 0, running: true, forwarding: true, gatewayId: 'a84041ffff1234ab', mqtt: 'connected',
                slot: { index: 0, status: 'present', bus: 'spi', device: '/dev/spidev0.0', resetGpio: '17', detected: 'sx1302_spi', active: 'sx1302_spi', override: null, mismatch: false, channels: 8, profile: { chip: 'SX1302', channels: 8, known_as: [ 'RAK2287', 'WM1302' ] } },
                stats: { received: 18234, forwarded: 18230, transmitted: 211, crcOkPercent: 97, lastUplink: '12s ago' }, gnss: { attached: false } } ] }),
        gps: () => ({ present: true, fix: false, reason: 'Waiting for a fix.', reference: { latitude: '43.1566', longitude: '-77.6088', source: 'gps', fixedAt: '2026-10-01' },
            config: { source: 'auto', slot: 0, device: '', baud: 9600 }, options: { modem: true, slots: [ { index: 0, status: 'present' } ] } }),
    },
    claim: {
        isAdopted: () => adopted,
        reclaiming: () => false,
        status: () => ({ claimId: 'K7M2-QP4X-9RTB', adoption: adopted ? 'adopted' : 'unadopted', registered: true, online: true, url: 'https://net.parkeze.com/c/K7M2', org: null }),
        adoptionCheckResult: () => ({ checking: false, checked: true, adopted: true }),
    },
    io: { status: () => ({ leds: [ { logical: 'power', physical: 'PWR', present: true }, { logical: 'status', physical: 'ACT', present: true }, { logical: 'lora', physical: null, present: false } ], available: [ 'PWR', 'ACT', 'mmc0' ], button: { reset: null, holdSeconds: 10 } }) },
    access: {
        status: () => ({ ap: { capable: true, up: false, enabled: false, secured: false, ssid: 'Parkeze-1234AB', clients: 0 },
            port: { hostname: 'parkeze-1234ab', console: '192.168.61.1', uplink: '10.20.0.57' },
            usb: { present: true, connected: true, name: 'parkeze.local', address: '192.168.63.1', serial: '/dev/ttyGS0' },
            wifi: { configured: true, ssid: 'Site-Ops', security: 'psk', up: true, uplink: 'portal', address: '10.30.1.8', signal: -58, mac: 'a8:40:41:1c:22:9e' } }),
        wifiDetail: () => ({ configured: true, saved: [ { ssid: 'Site-Ops', security: 'psk', active: true }, { ssid: 'eduroam', security: 'eap', active: false } ] }),
        scan: () => ({ capable: true, networks: [ { ssid: 'Site-Ops', signal: -58, quality: 52, encryption: 'psk' }, { ssid: 'eduroam', signal: -70, quality: 40, encryption: 'eap' }, { ssid: 'Guest', signal: -80, quality: 30, encryption: 'open' } ] }),
        key: () => ({ key: 'kq7-WT2m-pX9z' }),
        probeResult: () => ({ state: 'done', ssid: 'eduroam', chain: [ { depth: 0, subject: '/CN=radius.example.edu', hash: 'a1b2c3d4e5f6' }, { depth: 1, subject: '/CN=Example CA' } ] }),
    },
    bluetooth: { status: () => ({ state: 'off', enabled: false, running: false, rebootRequired: false, oui: '', minRssi: -100, heard: null }) },
    actions: {
        reboot: () => ok(), setUart: () => ok(), openShell: () => ok(), setPassword: (r) => length(r.password) < 12 ? { error: 'Use at least 12 characters.' } : ok(),
        installFirmware: (r) => ({ error: sprintf('%s is not a file.', r.path) }),
        setBluetooth: () => ok(), setCellular: () => ok(), setEthernet: (r) => r.mode == 'static' && !length(r.address) ? { error: 'The address is not a valid IPv4 address.' } : ok(),
        claimPoll: () => ({ claimId: 'K7M2-QP4X-9RTB', adoption: 'unadopted', registered: true, online: true }),
        claimApply: () => { adopted = true; return ok(); }, checkAdoption: () => ok({ checking: true }),
        setAp: () => ok(), raiseAp: () => ok(), lowerAp: () => ok(), forgetWifi: () => ok({ message: 'Forgot.' }),
        joinWifi: (r) => ok({ message: sprintf('Joining %s.', r.ssid) }), probeWifi: () => ok(),
        ioTest: () => ok(), setConcentrator: () => ok(), setSlot: () => ok(), detect: () => ok(), setBackhaul: () => ok(),
        restart: () => ok(), setGpsSource: () => ok(), detectGps: () => ok(), syncGps: () => ({ error: 'No fix yet.' }),
    },
};
