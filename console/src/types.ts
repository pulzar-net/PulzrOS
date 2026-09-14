/**
 * The shapes the ucode API returns.
 *
 * Hand-written rather than generated: the API is small, it is in this repo,
 * and a generator would be one more thing in the image pipeline. The rule is
 * that a change to a `lib/*.uc` return value changes this file in the same
 * commit — `npm run typecheck` in CI is what catches it when it does not.
 */

export type SessionKind = 'local' | 'sso' | 'recovery';

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
  note: string;
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

export interface SystemSummary {
  identity: {
    hostname: string | null;
    gatewayEui: string | null;
    serial: string | null;
    /** 'cpuinfo' | 'eth0' | 'random'. A random serial means this gateway will
        not recognise itself after a reflash, which the UI surfaces. */
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
  registration: string | null;
  network: string | null;
  technology: string | null;
  rssi: number | null;
  rsrp: number | null;
  snr: number | null;
}

export interface NetworkStatus {
  lan: InterfaceStatus;
  wan: InterfaceStatus & {
    /** Always false. Ethernet WAN is parkeze.net's to manage — see
        docs/backhaul.md. The reason travels with the payload so the UI cannot
        drift from the device's own policy. */
    manageable: boolean;
    reason: string;
    enabled: boolean;
  };
  cellular: InterfaceStatus & {
    manageable: boolean;
    enabled: boolean;
    apn: string | null;
    modem: Modem | null;
  };
}

export interface BackhaulStatus {
  wired: { up: boolean; device: string | null; gateway: string | null };
  tailscale: {
    wiredOnly: true;
    note: string;
    running: boolean;
    state: string;
    self: { hostname: string; addresses: string[]; online: boolean } | null;
  };
  cellular: { up: boolean; modem: Modem | null };
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
  status: 'present' | 'absent' | 'unsupported' | 'unknown';
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
      forwarder holds the serial port and this came from its last report. */
  source?: 'direct' | 'forwarder';
  /** What the gateway actually announces to the network server. */
  reference?: {
    latitude: string | null;
    longitude: string | null;
    altitude: string | null;
    source: string | null;
    fixedAt: string | null;
  };
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
  /** The human-readable code in the QR, e.g. "K7M2-QP4X-9RTB". */
  claimId: string;
  adoption: 'unadopted' | 'adopting' | 'adopted';
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

export interface LanGuard {
  serving: boolean;
  /** Why, in words. "another DHCP server answered" is the one that matters —
      it means the port is patched into a live network. */
  reason: string;
  mode: 'auto' | 'always' | 'never';
  carrier?: boolean;
  checkedAt?: number;
}

export interface AccessStatus {
  ap: ApStatus;
  portal: { up: boolean; address?: string };
  lan: LanGuard;
  adopted: boolean;
}

export interface WifiNetwork {
  ssid: string;
  signal: number;
  quality: number;
  encryption: 'psk' | 'open';
}
