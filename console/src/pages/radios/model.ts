/**
 * The radios page's data, as lib/radios.uc answers GET /api/radios, and the
 * few rules the page applies before asking the gateway: which channels a
 * width can use, what to call a band, what the gateway is doing as a whole.
 * The gateway checks all of it again; this is so a choice that cannot work is
 * not offered.
 */

export type Band = '2g' | '5g' | '6g' | '60g';
export type ApSecurity = 'psk2' | 'sae-mixed' | 'sae' | 'none';

export interface RadioClient {
  mac: string;
  signal: number | null;
  inactive: number | null;
  rx: number | null;
  tx: number | null;
}

export interface RadioInterface {
  id: string;
  /** uplink: the WiFi uplink's station; ap: an access point; client: a
      station somebody made by hand. */
  role: 'uplink' | 'ap' | 'client' | 'mesh' | 'monitor' | 'adhoc' | 'other';
  /** Who may change it: the uplink's join flow, pulzr-ap's setup network,
      this page (an AP made here; `radios` a second WiFi uplink), or nobody
      here. */
  owner: 'uplink' | 'setup' | 'console' | 'radios' | 'other';
  mode: string;
  ssid: string | null;
  meshId: string | null;
  security: string;
  networks: { id: string; label: string }[];
  hidden: boolean;
  isolate: boolean;
  enabled: boolean;
  ifname: string | null;
  up: boolean;
  clients: RadioClient[] | null;
  signal: number | null;
  bssid: string | null;
  channel: number | null;
}

export interface RadioChannel {
  channel: number;
  mhz: number;
  maxDbm: number | null;
  dfs: boolean;
}

export interface Radio {
  id: string;
  phy: string | null;
  present: boolean;
  band: Band;
  hardware: string | null;
  standards: string[] | null;
  enabled: boolean;
  up: boolean;
  channel: { configured: 'auto' | number; current: number | null; mhz: number | null };
  width: { configured: number; htmode: string | null };
  txpower: { configured: number | null; current: number | null; max: number | null };
  country: string | null;
  sharedChannel: boolean;
  capabilities: {
    known: boolean;
    modes: string[];
    channels: RadioChannel[];
    widths: number[];
    family: string;
    room: { ap: boolean; uplink: boolean; known: boolean };
  };
  interfaces: RadioInterface[];
}

/**
 * A second radio's station proven before it takes the traffic (handover() in
 * lib/radios.uc): joining while the other WiFi uplink carries it, done once
 * it reached the internet and moved ahead in the order, failed when it did
 * not in time and was removed again.
 */
export interface Handover {
  iface: string;
  radio: string;
  ssid: string;
  from: string;
  fromRadio: string;
  state: 'joining' | 'done' | 'failed';
  startedAt: number;
  endedAt?: number;
  /** Why it failed, from pulzr-wifi-uplink's answer. */
  reason?: string;
  /** Why it failed, from wpa_supplicant, when it never associated. */
  failure?: { code: string; detail?: string | null; at: string };
}

export interface RadiosStatus {
  radios: Radio[];
  country: string | null;
  sae: boolean;
  networks: { id: string; label: string; address: string | null }[];
  route: { via: 'wifi' | 'ethernet' | 'cellular' | 'usb-cellular' | 'other' | null; iface: string | null };
  hostname: string | null;
  /** The radio the WiFi page's uplink is on, when one is configured. */
  uplink: string | null;
  /** Every WiFi uplink, the WiFi page's first. */
  uplinks: { id: string; iface: string; radio: string; ssid: string; up: boolean; address: string | null }[];
  handover: Handover | null;
}

/** Whether this interface is the station a handover is waiting on. */
export function joiningIface(status: RadiosStatus, iface: RadioInterface): boolean {
  const h = status.handover;
  return h?.state === 'joining' && iface.networks.some((n) => n.id === h.iface);
}

export const BAND_NAMES: Record<Band, string> = { '2g': '2.4 GHz', '5g': '5 GHz', '6g': '6 GHz', '60g': '60 GHz' };

export const SECURITY_LABELS: Record<ApSecurity, string> = {
  psk2: 'WPA2',
  'sae-mixed': 'WPA2/WPA3',
  sae: 'WPA3',
  none: 'Open',
};

export function securityLabel(value: string): string {
  if (value in SECURITY_LABELS) return SECURITY_LABELS[value as ApSecurity];
  if (value.startsWith('psk')) return 'WPA2';
  if (value.startsWith('sae')) return 'WPA3';
  if (value.startsWith('wpa')) return '802.1X';
  return value === 'none' ? 'Open' : value;
}

/** "Radio 1", in the order UCI has them. The section name is for logs. */
export function radioName(radios: Radio[], id: string) {
  const i = radios.findIndex((r) => r.id === id);
  return i < 0 ? id : `Radio ${i + 1}`;
}

/** The channel a radio is on, or will be on: live when it is up. */
export function channelText(radio: Radio): string {
  if (radio.channel.current != null) return `${radio.channel.current}`;
  return radio.channel.configured === 'auto' ? 'Auto' : `${radio.channel.configured}`;
}

/**
 * Whether a channel can carry a width on this radio, as the gateway decides
 * it (channelOk in lib/radios.uc): every 20 MHz channel a wider one covers is
 * open. 5 GHz blocks start at 36 below 149 and at 149 above it; 6 GHz numbers
 * from 1; 2.4 GHz at 40 takes the channel four above or below.
 */
export function channelFits(radio: Radio, channel: number, width: number): boolean {
  const open = new Set(radio.capabilities.channels.map((c) => c.channel));
  if (!open.has(channel)) return false;
  if (width <= 20) return true;
  if (radio.band === '2g') return width === 40 && (open.has(channel + 4) || open.has(channel - 4));
  const base = radio.band === '6g' ? 1 : channel >= 149 ? 149 : 36;
  const n = width / 20;
  if ((channel - base) % 4) return false;
  const start = base + Math.floor((channel - base) / 4 / n) * n * 4;
  for (let i = 0; i < n; i++) if (!open.has(start + i * 4)) return false;
  return true;
}

/** What the gateway is, by what runs on its radios. */
export function gatewayMode(status: RadiosStatus): { label: string; repeater: boolean } {
  const live = status.radios.flatMap((r) => (r.enabled ? r.interfaces.filter((i) => i.enabled) : []));
  const uplink = live.some((i) => i.role === 'uplink');
  const aps = live.some((i) => i.role === 'ap');
  if (uplink && aps) return { label: 'Repeater', repeater: true };
  if (aps) return { label: 'Access point', repeater: false };
  if (uplink) return { label: 'WiFi client', repeater: false };
  return { label: 'Radios idle', repeater: false };
}

export const ROLE_NAMES: Record<RadioInterface['role'], string> = {
  uplink: 'Uplink',
  ap: 'Access point',
  client: 'Client',
  mesh: 'Mesh',
  monitor: 'Monitor',
  adhoc: 'Ad hoc',
  other: 'Other',
};
