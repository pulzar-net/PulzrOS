/**
 * The shapes the ucode API returns.
 *
 * Hand-written rather than generated: the API is small, it is in this repo,
 * and a generator would be one more thing in the image pipeline. The rule is
 * that a change to a `lib/*.uc` return value changes this file in the same
 * commit — `npm run typecheck` in CI is what catches it when it does not.
 */

export type SessionKind = 'local' | 'sso' | 'recovery' | 'lan';

export interface Session {
  subject: string;
  kind: SessionKind;
  csrf: string;
  expiresIn?: number;
  mustChangePassword?: boolean;
}

export interface LoginMethods {
  local: boolean;
  sso: boolean;
  recovery: boolean;
  state: 'unadopted' | 'adopted';
  online?: boolean;
  /** Where "Sign in with Pulzar" sends the browser. Adopted gateways only. */
  platform?: string;
  /** This gateway's EUI, for the same link. */
  deviceId?: string;
  /** The address this request reached the gateway on. */
  address?: string;
  /** Null when there is nothing worth saying. */
  note: string | null;
}

export interface RecoveryChallenge {
  challenge: {
    device: string;
    nonce: string;
    issued: number;
    expiresIn: number;
    /** The single string an operator transcribes into Pulzar Cloud. */
    code: string;
  };
  hostname: string;
}

// ── system ──────────────────────────────────────────────────────────────────

/** A board's feature words; boards/common/board.conf lists what each means.
    `modbus` is an add-on's, present while pulzr-edge is installed. */
export type Feature =
  | 'lorawan'
  | 'gnss'
  | 'bluetooth'
  | 'cellular'
  | 'wifi'
  | 'lan'
  | 'dns'
  | 'failover'
  | 'speedtest'
  | 'modbus';

export interface SystemSummary {
  identity: {
    hostname: string | null;
    gatewayEui: string | null;
    serial: string | null;
    /** 'cpuinfo' | 'eth0' | 'random'. A random serial means this gateway will
        not recognize itself after a reflash, which the UI surfaces. */
    serialSource: string | null;
    board: string | null;
    boardName: string | null;
  };
  firmware: {
    version: string | null;
    build: string | null;
    commit: string | null;
    openwrt: string | null;
    kernel: string | null;
  };
  adoption: {
    state: string | null;
    org: string | null;
    since: string | null;
  };
  health: {
    uptime: number | null;
    loadavg: number[] | null;
    memory: { total?: number; free?: number; available?: number } | null;
    temperature: number | null;
  };
}

/** pulzr-addon's states; docs/src/content/docs/addons.md says what each means. */
export type AddonState =
  | 'installed'
  | 'downloading'
  | 'installing'
  | 'removing'
  | 'reverted'
  | 'failed'
  | 'pending-restore'
  | 'unavailable';

export interface AddonItem {
  state: AddonState;
  version: string | null;
  upstream: string | null;
  builtIn: boolean;
  health: 'ok' | 'idle' | 'failing' | null;
  since: string | null;
  error: string;
  title: string;
}

/** GET /api/system/addons. Read-only here: installs come from Pulzar Net. */
export interface AddonStatus {
  wanted: string[];
  deny: string[];
  items: Record<string, AddonItem>;
  tag: string;
  available: { name: string; title: string; caps: string[]; upstream: string | null; builtIn: boolean }[];
}

// ── network ─────────────────────────────────────────────────────────────────

export interface InterfaceStatus {
  configured: boolean;
  up?: boolean;
  available?: boolean;
  device?: string;
  proto?: string;
  address?: string | null;
  gateway?: string | null;
  uptime?: number;
}

/** How the cellular adapter reaches the gateway. qmi, mbim and at are modems
    ModemManager drives as wwan. hilink and tether are USB Ethernet devices on
    usbwan, with no SIM, operator or signal the gateway can read. */
export type ModemKind = 'qmi' | 'mbim' | 'at' | 'hilink' | 'tether';

export interface Modem {
  kind?: ModemKind;
  model?: string | null;
  imei?: string | null;
  registration: string | null;
  network: string | null;
  technology: string | null;
  /** ModemManager's 0-100 quality. Always available. */
  quality?: number | null;
  /** dBm figures, only once `mmcli --signal-setup` has run — reported when
      present rather than derived from the percentage. */
  rssi: number | null;
  rsrp: number | null;
  snr: number | null;
}

export interface NetworkStatus {
  /** The fixed console address, on the port pulzr-ports puts it on. */
  console: InterfaceStatus;
  /** The link-local address on the same port, for a laptop plugged straight
      in. Up independently of whether the uplink has a lease. */
  linkLocal: InterfaceStatus;
  cellular: InterfaceStatus & {
    manageable: boolean;
    enabled: boolean;
    apn: string | null;
    modem: Modem | null;
  };
}

export interface BackhaulStatus {
  wired: {
    up: boolean;
    /** The wired uplink the tunnel would take: wan, or wan_<device>. */
    iface?: string | null;
    device: string | null;
    gateway: string | null;
    address?: string | null;
    proto?: string | null;
    /** Mb/s; null with no link. */
    speed?: number | null;
  };
  wifi?: { up: boolean; device: string | null; address: string | null };
  tunnel: {
    wiredOnly: true;
    note: string;
    configured: boolean;
    /** The uplink the tunnel's packets leave on right now. */
    via: 'wired' | 'wifi' | 'cellular' | 'none';
    /** none: not enrolled yet. waiting: the hub has not answered recently. up: handshake in the last three minutes. */
    state: 'none' | 'waiting' | 'up';
    address: string | null;
    endpoint: string | null;
    /** Seconds since the last handshake, or null if there has never been one. */
    lastHandshake: number | null;
  };
  cellular: { up: boolean; device?: string | null; modem: Modem | null };
}

// ── lorawan ─────────────────────────────────────────────────────────────────

export interface ConcentratorProfile {
  name: string;
  chip: string;
  interface: 'spi' | 'usb' | 'uart';
  forwarder: string;
  antennas: number;
  channels: number;
  lbt: boolean;
  known_as?: string[];
  comment?: string;
}

export interface SupportedPart {
  id: string;
  name: string;
  chip: string;
  interface: 'spi' | 'usb' | 'uart';
  knownAs?: string[];
  /** False for UART parts, which cannot be probed — see sx130x_probe. */
  detectable: boolean;
}

/** One concentrator position. An 8-channel gateway has one; a RAK7289CV2 two. */
export interface Slot {
  index: number;
  bus: 'spi' | 'usb' | 'uart' | '';
  device: string;
  resetGpio: string;
  powerGpio: string;
  /** The operator's own reset line, if they typed one. Separate from
      resetGpio, which detection overwrites every run with whatever it
      actually probed with. */
  resetGpioOverride: string;
  status: 'present' | 'absent' | 'unfitted' | 'unsupported' | 'unknown';
  detected: string | null;
  override: string | null;
  active: string | null;
  profile: ConcentratorProfile | null;
  mismatch: boolean;
  channels: number;
}

export interface ConcentratorView {
  /** 'partial' means some slots answered and some did not — the gateway works
      at a reduced channel count, which nothing else makes obvious. */
  status: 'present' | 'partial' | 'absent' | 'unknown';
  slots: Slot[];
  slotCount: number;
  presentCount: number;
  channels: number;
  /** False on fixed-hardware boards, where the bus cannot change and an
      editable field is only ever a way to break a working gateway. */
  configurable: boolean;
  supported: SupportedPart[];
  region: string;
}

export interface LorawanStatus {
  gatewayEui: string | null;
  region: string | null;
  concentrator: {
    status: string;
    slots: number;
    present: number;
    channels: number;
  };
  forwarder: {
    running: boolean;
    received: number | null;
    forwarded: number | null;
    transmitted: number | null;
    crcOkPercent: number | null;
    lastUplink: string | null;
    /** Received, added up since boot. Absent on firmware from before it. */
    totalReceived?: number | null;
  };
  bridge: { connected: boolean; broker: string | null };
  /** Whether uplinks may use the metered link, and whether they are leaving
      the gateway right now. `sending: false` with `allowCellular: false` is a
      deliberate hold, not a fault — it reads very differently from a broker
      that cannot be reached. Null on a gateway whose firmware predates it. */
  backhaul: {
    allowCellular: boolean;
    wiredUp: boolean;
    /** Absent on firmware from before WiFi counted as a free link. */
    wifiUp?: boolean;
    sending: boolean;
    brokerPort: number;
  } | null;
  /** What happens to uplinks that cannot be sent: held, or dropped. */
  buffer: {
    enabled: boolean;
    running: boolean;
    /** Whether the broker's bridge to the LNS is connected; null when the
        broker is not running. */
    bridgeUp: boolean | null;
    /** Whether there is an SD card to keep the queue on. Without one the
        buffer does not run at all. */
    persistent: boolean;
    /** The loopback port the broker listens on. Not 1883: the mosquitto
        package's own service owns that one. */
    port: number;
    queuedBytes: number;
  } | null;
}

// ── gnss ────────────────────────────────────────────────────────────────────

export interface GpsStatus {
  present: boolean;
  fix: boolean;
  /** Why there is no fix, in words. A receiver with no sky view is the common
      case and is not the same failure as no receiver at all. */
  reason?: string;
  quality?: number;
  satellites?: number;
  latitude?: number;
  longitude?: number;
  altitude?: number;
  device?: string;
  /** 'direct' when read from the receiver, 'forwarder' when the packet
      forwarder holds the serial port and this came from its last report,
      'modem' when the cellular modem is the source. */
  source?: 'direct' | 'forwarder' | 'modem';
  /** What the gateway actually announces to the network server. */
  reference?: {
    latitude: string | null;
    longitude: string | null;
    altitude: string | null;
    source: string | null;
    fixedAt: string | null;
  };
  /** Where the position comes from. See pulzr-gps for each source. */
  config: {
    source: GnssSource;
    /** The concentrator the receiver is given to, for 'concentrator'. */
    slot: number;
    /** The receiver, for 'device'. */
    device: string;
    baud: number;
  };
  options: {
    modem: boolean;
    slots: { index: number; status: string }[];
  };
}

export type GnssSource = 'auto' | 'modem' | 'concentrator' | 'device';

// ── forwarders ──────────────────────────────────────────────────────────────

/** One concentrator slot's concentratord and MQTT forwarder. */
export interface Forwarder {
  index: number;
  slot: Slot;
  running: boolean;
  forwarding: boolean;
  gatewayId: string | null;
  /** The forwarder's own report: 'connected', 'error', or null before it has
      said anything. */
  mqtt: string | null;
  stats: {
    received: number;
    forwarded: number;
    transmitted: number;
    crcOkPercent: number;
    lastUplink: string | null;
  } | null;
  gnss: { attached: boolean; device: string | null };
}

export interface ForwardersView {
  region: string | null;
  mqtt: {
    host: string | null;
    port: number;
    topicPrefix: string | null;
    username: string | null;
    buffered: boolean;
  };
  location: {
    latitude: string | null;
    longitude: string | null;
    altitude: string | null;
    source: string | null;
  };
  forwarders: Forwarder[];
}

// ── io ──────────────────────────────────────────────────────────────────────

export interface LedMapping {
  logical: string;
  physical: string | null;
  present: boolean;
}

/** A physical light: one line of the board's PULZR_LEDS, or, on a board
    without that list, one entry of /sys/class/leds. */
export interface PanelLight {
  /** Its /sys/class/leds name, or rgb:<function> for one RGB light. */
  name: string;
  colour: 'green' | 'red' | 'orange' | 'amber' | 'yellow' | 'blue' | 'white' | 'rgb' | null;
  role: 'power' | 'status' | 'cloud' | 'lora' | 'ethernet' | 'wifi' | 'cellular' | 'bluetooth' | null;
  /** What the panel prints beside it; null from the kernel's list. */
  label: string | null;
  /** The kernel has it. False is a board file naming a light it does not. */
  present: boolean;
  /** Its trigger (heartbeat, netdev...), or on or off; null when missing. */
  state: string | null;
}

export interface IoStatus {
  leds: LedMapping[];
  /** Every LED the kernel exposes, so a wrong board mapping is fixable by
      looking rather than by guessing. */
  available: string[];
  /** The lights to show. `board` when the board lists its own, `kernel` when
      it does not. Absent on firmware from before the list. */
  panel?: { source: 'board' | 'kernel'; lights: PanelLight[] };
  button: { reset: string | null; holdSeconds: number };
}

/** GET /api/bluetooth/status. */
export interface BluetoothStatus {
  state: 'on' | 'off' | 'absent';
  enabled: boolean;
  running: boolean;
  rebootRequired: boolean;
  oui: string;
  minRssi: number;
  /** Seconds between a beacon's uplinks. */
  interval?: number;
}

// ── provisioning ────────────────────────────────────────────────────────────

export interface ClaimStatus {
  /** Where the management platform lives, read from the gateway's board.conf.
      The UI never spells out a hostname of its own — the deployment has moved
      once already and will again. */
  platform?: { url: string; host: string };
  /** The human-readable code in the QR, e.g. "K7M2-QP4X-9RTB". */
  claimId: string;
  /** 'reclaiming': adopted, but the claim was revoked (the gateway changed
      hands or was released) and claimId is the new one waiting to be adopted. */
  adoption: 'unadopted' | 'adopting' | 'adopted' | 'reclaiming';
  /** Whether Pulzar Cloud already knows about this pending claim. When it does
      the QR is a short URL; when it does not it carries the gateway's identity
      inline so a scan still works with no uplink. */
  registered: boolean;
  online: boolean;
  url: string;
  org: string | null;
  hostname: string | null;
  gatewayEui: string | null;
  board: string | null;
}

export interface ClaimQr {
  /** Rendered on the device by qrencode, so the browser ships no QR library. */
  svg: string;
  url: string;
}

// ── access: the setup AP, the portal, LAN DHCP ──────────────────────────────

export interface ApStatus {
  capable: boolean;
  reason?: string;
  enabled?: boolean;
  up?: boolean;
  ssid?: string;
  /** False means the AP is open — which only happens while the gateway is
      unadopted and therefore has no credentials to lose. */
  secured?: boolean;
  clients?: number;
  remainingSeconds?: number;
  fallback?: boolean;
  /** Whether four presses of the reset button may raise it. */
  button?: boolean;
  /** It is up because somebody pressed the button. */
  raisedByButton?: boolean;
  /** The console's address from the AP. */
  address?: string | null;
  fallbackAfter?: number;
}

/** The single ethernet port. It has no role — it holds every address at once. */
export interface EthernetPort {
  iface: string;
  /** mDNS name, so `https://<hostname>.local` reaches the console. */
  hostname: string;
  /** The fixed address, the one printed on the label. */
  console: string;
  /** Link-local, for a laptop plugged straight in with nothing configured. */
  linkLocal: string;
  /** The DHCP lease, when the cable reached a network that offers one. Null on
      a bench, which is not a fault — the two static addresses still carry the
      console. */
  uplink: string | null;
  /** Always false. Present so the UI can state it rather than leave an
      installer wondering why their laptop got no address. */
  servesDhcp: boolean;
}

/** The USB device port, on a board built with one; see pulzr-usb-gadget. */
export interface UsbPort {
  /** The gadget is built and attached to the controller. */
  present: boolean;
  /** A host has enumerated it: a laptop is on the other end. */
  connected: boolean;
  state: string;
  /** The mDNS name on the cable, pulzr.local. */
  name: string;
  /** The gateway's fixed address on the cable. */
  address: string;
}

export interface AccessStatus {
  ap: ApStatus;
  port: EthernetPort;
  /** Null on a board with no USB device port. */
  usb: UsbPort | null;
  /** The gateway's address on its LAN ports. Null on a board without them. */
  lan: string | null;
  adopted: boolean;
  wifi:
    | { configured: false }
    | {
        configured: true;
        ssid: string;
        security: 'psk' | 'open' | 'eap';
        up: boolean;
        /** Whether it reaches the internet: `portal` wants a sign-in first,
            `offline` answers nothing. See pulzr-wifi-uplink. */
        uplink: 'open' | 'portal' | 'offline' | 'unchecked';
        address: string | null;
        signal: number | null;
        mac: string | null;
      };
}

export interface WifiNetwork {
  ssid: string;
  signal: number;
  quality: number;
  /** eap is WPA-Enterprise: a username and password, eduroam among them. */
  encryption: 'psk' | 'open' | 'eap';
}

// ── resources ───────────────────────────────────────────────────────────────

export interface SystemStats {
  uptime: number;
  cpu: {
    model: string | null;
    core: string | null;
    cores: number;
    bogomips: number | null;
    /** Jiffies since boot, all states and idle. Usage is the change between
        two polls; one reading alone says nothing about now. */
    total: number;
    idle: number;
    load: [number, number, number];
    running: number;
    processes: number;
  };
  memory: {
    total: number;
    available: number;
    free: number;
    cached: number;
    buffers: number;
    shared: number;
    swapTotal: number;
    swapFree: number;
  };
  storage: {
    mount: string;
    label: string;
    device: string;
    total: number;
    used: number;
    available: number;
  }[];
  /** Empty on a board with no sensor Linux can see. */
  temperatures: { name: string; celsius: number }[];
  power: {
    name: string;
    type: string;
    online: number | null;
    capacity: number | null;
    volts: number | null;
  }[];
  interfaces: { name: string; state: string; rx: number | null; tx: number | null }[];
  processes: { pid: number; name: string; rss: number }[];
}

/** pulzr-stats' ring, averaged into at most 360 points. */
export interface SystemHistory {
  interval: number;
  points: {
    t: number;
    /** Percent, 0 to 100. */
    cpu: number;
    mem: number;
    memTotal: number;
    load: number;
    /** Bytes per second, [down, up], per interface. */
    net: Record<string, [number, number]>;
  }[];
}

export interface ProcessList {
  /** The machine's CPU ticks since boot, to turn two polls into percentages. */
  total: number;
  processes: {
    pid: number;
    name: string;
    command: string;
    state: string;
    ticks: number;
    threads: number;
    rss: number;
  }[];
}

// ── lan ─────────────────────────────────────────────────────────────────────

/** Bytes since boot, by the netifd interface that carried them (wan, wwifi,
    wwan, usbwan), and `tunnel` for a forward's traffic. */
export type LanTraffic = Record<string, { txBytes: number; rxBytes: number }>;

export interface LanClient {
  mac: string;
  ip: string | null;
  hostname: string | null;
  reserved: string | null;
  /** `parkeze` is the cloud's name for the Pulzar-only policy; it stays. */
  policy: 'parkeze' | 'internet';
  online: boolean;
  /** Unix seconds; DHCP contact, kept across reboots. */
  firstSeen: number | null;
  lastSeen: number | null;
  leaseExpires?: number;
  traffic: LanTraffic;
  /** The LAN port it is behind, from the bridge's forwarding table. */
  port?: string | null;
  /** Whether it may use cellular when that carries traffic. */
  cellular?: 'allow' | 'block';
  /** Ports refused on cellular while allowed: "tcp:554", "udp:5000-5010". */
  cellularBlock?: string[];
}

export interface LanLink {
  name: string;
  up: boolean;
  /** Mb/s; null with no link. */
  speed: number | null;
  duplex?: 'full' | 'half' | null;
  /** Every up and down since boot; 1 or 2 for a port that came up once. */
  carrierChanges?: number;
}

/** A tunnel forward the cloud opened (lan-forward). Read here, never opened. */
export interface LanForward {
  port: number;
  ip: string;
  dport: number;
  expiresIn: number;
}

/** `pulzr-lan status`; see docs/src/content/docs/lan.md. */
export interface LanStatus {
  configured: boolean;
  address?: string;
  ports?: string[];
  links?: LanLink[];
  clients?: LanClient[];
  forwards?: LanForward[];
  exposed?: LanExposed[];
  /** The wired and WiFi uplink addresses exposed ports answer on now. */
  exposedOn?: { uplink: string; address: string }[];
}

/** A port on the uplinks forwarded to a client for good (pulzr-lan expose). */
export interface LanExposed {
  proto: 'tcp' | 'udp';
  port: number;
  ip: string;
  dport: number;
}

// ── dns ─────────────────────────────────────────────────────────────────────

/** `pulzr-dns status`. */
export interface DnsStatus {
  upstream: {
    /** auto: the servers each uplink's lease or bearer handed out. */
    mode: 'auto' | 'custom';
    servers: string[];
  };
  hosts: { name: string; ip: string }[];
  rebind: {
    protection: boolean;
    /** Domains allowed to answer with a private address. */
    allowed: string[];
  };
  /** The customer's own name on Cloudflare, kept on this site's address. */
  ddns?: DdnsStatus;
}

export interface DdnsStatus {
  enabled: boolean;
  name?: string | null;
  zone?: string | null;
  /** The wired or WiFi uplink it follows: wan, wan_<device>, wwifi. */
  uplink?: string | null;
  tokenSet?: boolean;
  /** What Cloudflare was last told. */
  address?: string | null;
  /** Unix seconds of that update. */
  updated?: number | null;
  /** ddns-scripts' last error, while nothing is registered. */
  error?: string | null;
  uplinks: string[];
}

// ── uplinks ─────────────────────────────────────────────────────────────────

/** A netifd uplink interface: wwifi, wwan, usbwan, or a wired one,
    wan or wan_<device> (pulzr-ports). */
export type UplinkIface = string;

export interface Uplink {
  iface: UplinkIface;
  kind: 'ethernet' | 'wifi' | 'cellular' | 'usb-cellular';
  metered: boolean;
  up: boolean;
  device: string | null;
  tracked: boolean;
  /** down: netifd has no link. offline: tracking's pings went unanswered.
      portal: the WiFi answers with a sign-in page. */
  state: 'down' | 'online' | 'offline' | 'portal' | 'unchecked' | 'untracked';
  /** Unix seconds the tracked state last changed. */
  since: number | null;
  checkedAt: number | null;
  metric: number | null;
}

/** `pulzr-uplinks status`. */
export interface UplinksStatus {
  order: UplinkIface[];
  /** The uplink carrying traffic now. */
  active: UplinkIface | null;
  tracking: { ips: string[]; interval: number; down: number; up: number };
  uplinks: Uplink[];
}

// ── ports ───────────────────────────────────────────────────────────────────

export type PortRole = 'uplink' | 'devices' | 'none';

export interface Addressing {
  mode: 'dhcp' | 'static';
  address?: string | null;
  netmask?: string | null;
  gateway?: string | null;
  dns?: string[];
}

/** An uplink link as netifd has it now. */
export interface PortUplink {
  role: 'uplink';
  iface: string;
  addressing: Addressing;
  state: { up: boolean; address: string | null; gateway: string | null; dns?: string[] };
  /** The router at the end of it: its MAC from the ARP table, its maker as
      Pulzar Cloud named it on the last report. */
  router: { address: string; mac: string | null; maker: string | null } | null;
  /** The public side, for the uplink the last report left on. */
  internet: { address: string | null; provider: { name: string | null; asn: number | null } | null } | null;
}

/** What announced itself on a port, over LLDP or CDP (lldpd). */
export interface PortNeighbor {
  protocol: string | null;
  name: string | null;
  description: string | null;
  chassis: string | null;
  /** The chassis MAC's maker, as Pulzar Cloud named it. */
  maker?: string | null;
  managementAddress: string | null;
  capabilities: string[];
  port: string | null;
  portDescription: string | null;
}

export interface PortVlan {
  vid: number;
  role: Exclude<PortRole, 'none'>;
  addressing: Addressing;
  uplink: PortUplink | null;
}

export interface Port {
  name: string;
  /** What the case says: WAN, LAN 1, Ethernet. */
  label: string;
  /** The board's own uplink port. */
  primary: boolean;
  link: { present: boolean; up?: boolean; speed?: number | null; mac?: string | null };
  role: PortRole;
  addressing: Addressing;
  uplink: PortUplink | null;
  neighbors?: PortNeighbor[];
  vlans: PortVlan[];
}

/** `pulzr-ports status`. */
export interface PortsStatus {
  ports: Port[];
  /** The port the console's fixed addresses are on, or null. */
  console: string | null;
  consoleAddress: string | null;
  /** Whether this gateway has a LAN to put devices on. */
  devices: boolean;
  /** A change applied and not yet confirmed: undone at `until` (Unix s). */
  pending: { until: number; in: number; by: string | null; confirmableIn: number } | null;
  /** Seconds a change has to be confirmed in. */
  window: number;
  /** Seconds after a change before a confirm counts. */
  settle: number;
}

/** What `POST /ports` takes: the whole layout. */
export interface PortsLayout {
  ports: { name: string; role: PortRole; addressing: Addressing; vlans: { vid: number; role: Exclude<PortRole, 'none'>; addressing: Addressing }[] }[];
}

// ── speed tests ─────────────────────────────────────────────────────────────

/** One test: `direct` on one uplink to a LibreSpeed server, or `tunnel`,
    measured by Pulzar Cloud over WireGuard. */
export interface SpeedResult {
  at: number;
  test: 'direct' | 'tunnel';
  iface?: string | null;
  kind?: 'ethernet' | 'wifi';
  device?: string | null;
  /** The tunnel's path: wired or wifi. */
  via?: string;
  server?: string | null;
  /** Whether the LibreSpeed server was reached over HTTPS. */
  secure?: boolean;
  downloadMbps?: number;
  uploadMbps?: number;
  pingMs?: number;
  jitterMs?: number;
  bytesReceived?: number;
  bytesSent?: number;
  error?: string;
}

/** `pulzr-speedtest status`. */
export interface SpeedtestStatus {
  schedule: { every: 'off' | 'daily' | 'weekly'; at: string; duration: number };
  running: { startedAt: number } | null;
  /** The uplinks a run would test now. */
  uplinks: { iface: string; kind: string; device: string }[];
  history: SpeedResult[];
}
