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
  /** Where "Sign in with Parkeze" sends the browser. Adopted gateways only. */
  platform?: string;
  /** This gateway's EUI, for the same link. */
  deviceId?: string;
  /** Null when there is nothing worth saying. */
  note: string | null;
}

export interface RecoveryChallenge {
  challenge: {
    device: string;
    nonce: string;
    issued: number;
    expiresIn: number;
    /** The single string an operator transcribes into parkeze.net. */
    code: string;
  };
  hostname: string;
}

// ── system ──────────────────────────────────────────────────────────────────

/** A board's feature words; boards/common/board.conf lists what each means. */
export type Feature =
  | 'lorawan'
  | 'gnss'
  | 'bluetooth'
  | 'cellular'
  | 'wifi'
  | 'lan'
  | 'dns'
  | 'failover';

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

export interface Modem {
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
  /** The fixed console address on the shared ethernet port. */
  console: InterfaceStatus;
  /** The link-local address on the same port, for a laptop plugged straight
      in. Up independently of whether the uplink has a lease. */
  linkLocal: InterfaceStatus;
  wan: InterfaceStatus & {
    manageable: boolean;
    reason: string | null;
    enabled: boolean;
    mode: 'dhcp' | 'static';
    staticAddress: string | null;
    staticNetmask: string | null;
    staticGateway: string | null;
    dns: string[];
  };
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
  /** Where the position comes from. See parkeze-gps for each source. */
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

export interface IoStatus {
  leds: LedMapping[];
  /** Every LED the kernel exposes, so a wrong board mapping is fixable by
      looking rather than by guessing. */
  available: string[];
  button: { reset: string | null; holdSeconds: number };
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
  /** Whether parkeze.net already knows about this pending claim. When it does
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

/** The USB device port, on a board built with one; see parkeze-usb-gadget. */
export interface UsbPort {
  /** The gadget is built and attached to the controller. */
  present: boolean;
  /** A host has enumerated it: a laptop is on the other end. */
  connected: boolean;
  state: string;
  /** The mDNS name on the cable, parkeze.local. */
  name: string;
  /** The gateway's fixed address on the cable. */
  address: string;
}

export interface AccessStatus {
  ap: ApStatus;
  portal: { up: boolean; address?: string };
  port: EthernetPort;
  /** Null on a board with no USB device port. */
  usb: UsbPort | null;
  adopted: boolean;
  wifi:
    | { configured: false }
    | {
        configured: true;
        ssid: string;
        security: 'psk' | 'open' | 'eap';
        up: boolean;
        /** Whether it reaches the internet: `portal` wants a sign-in first,
            `offline` answers nothing. See parkeze-wifi-uplink. */
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

/** parkeze-stats' ring, averaged into at most 360 points. */
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
    wwan), and `tunnel` for a forward's traffic. */
export type LanTraffic = Record<string, { txBytes: number; rxBytes: number }>;

export interface LanClient {
  mac: string;
  ip: string | null;
  hostname: string | null;
  reserved: string | null;
  policy: 'parkeze' | 'internet';
  online: boolean;
  /** Unix seconds; DHCP contact, kept across reboots. */
  firstSeen: number | null;
  lastSeen: number | null;
  leaseExpires?: number;
  traffic: LanTraffic;
  /** The LAN port it is behind, from the bridge's forwarding table. */
  port?: string | null;
}

export interface LanLink {
  name: string;
  up: boolean;
  /** Mb/s; null with no link. */
  speed: number | null;
}

/** A tunnel forward net-api opened (lan-forward). Read here, never opened. */
export interface LanForward {
  port: number;
  ip: string;
  dport: number;
  expiresIn: number;
}

/** `parkeze-lan status`; see docs/lan.md. */
export interface LanStatus {
  configured: boolean;
  address?: string;
  ports?: string[];
  links?: LanLink[];
  clients?: LanClient[];
  forwards?: LanForward[];
}
