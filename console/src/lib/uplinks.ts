import { EthernetPort, Signal, Wifi } from 'lucide-react';
import type { LucideIcon } from 'lucide-react';
import type {
  AccessStatus,
  BackhaulStatus,
  Feature,
  NetworkStatus,
  PortUplink,
  PortsStatus,
  Uplink,
  UplinksStatus,
} from '@/types';
import type { Tone } from '@/components/ui/Badge';
import { modemKind, portLabel, uplinkName } from '@/lib/format';

/**
 * Every backhaul connection as one row each, for Overview's Uplinks card and
 * the Backhaul page. One function rather than one per page: the two showed
 * the same uplink in different words before it moved here.
 *
 * With failover, rows are pulzr-uplinks' list in the site's order with its
 * tracking verdict on each. Without it, the gateway's fixed paths, which have
 * no order to set: Ethernet, then WiFi, then cellular.
 */

export interface LinkRow {
  /** The uplink's interface with failover (what /uplinks/order takes); a
      fixed path's name without. */
  key: string;
  name: string;
  icon: LucideIcon;
  device: string | null;
  /** Carrying traffic now. */
  active: boolean;
  tone: Tone;
  state: string;
  detail: (string | null | undefined)[];
  /** Its settings page. */
  to: string;
  /** pulzr-uplinks' entry, with failover. */
  uplink?: Uplink;
}

/** What a page has fetched. Each source adds detail and none is required:
    Overview passes the two it polls, the Backhaul page all of them. */
export interface LinkSources {
  paths?: BackhaulStatus;
  order?: UplinksStatus;
  ports?: PortsStatus;
  access?: AccessStatus;
  network?: NetworkStatus;
}

const KIND_ICONS: Record<Uplink['kind'], LucideIcon> = {
  ethernet: EthernetPort,
  wifi: Wifi,
  cellular: Signal,
  'usb-cellular': Signal,
};

export function linkSpeed(mbps: number | null | undefined) {
  if (!mbps) return null;
  return mbps >= 1000 ? `${mbps / 1000} Gb/s` : `${mbps} Mb/s`;
}

function pageFor(kind: Uplink['kind']) {
  if (kind === 'wifi') return '/backhaul/wifi';
  if (kind === 'ethernet') return '/backhaul/ethernet';
  return '/backhaul/cellular';
}

const bare = (address: string | null | undefined) => address?.split('/')[0] ?? null;

/** What a modem says about itself. A HiLink dongle or a phone is usbwan and a
    ModemManager modem wwan, so each row takes only its own. */
function modemDetail(paths: BackhaulStatus | undefined, kind: Uplink['kind']) {
  const modem = paths?.cellular.modem;
  if (!modem) return [];
  const usb = modem.kind === 'hilink' || modem.kind === 'tether';
  if (usb !== (kind === 'usb-cellular')) return [];
  const signal = modem.rssi != null ? `${modem.rssi} dBm` : modem.quality != null ? `${modem.quality}%` : null;
  return [modem.model ?? modemKind(modem.kind), signal, modem.network, modem.technology];
}

/** The port, or the VLAN on one, that pulzr-ports made this wired uplink. */
function wiredPort(ports: PortsStatus | undefined, iface: string) {
  for (const port of ports?.ports ?? []) {
    if (port.uplink?.iface === iface) return { port, uplink: port.uplink };
    for (const v of port.vlans) if (v.uplink?.iface === iface) return { port, uplink: v.uplink };
  }
  return null;
}

function wiredDetail(uplink: PortUplink | null | undefined, speed: number | null | undefined) {
  return [
    linkSpeed(speed),
    bare(uplink?.state.address),
    uplink ? (uplink.addressing.mode === 'static' ? 'static' : 'DHCP') : null,
  ];
}

function wifiDetail({ paths, access }: LinkSources) {
  const wifi = access?.wifi;
  if (wifi?.configured) {
    return [wifi.ssid, wifi.signal != null ? `${wifi.signal} dBm` : null, bare(wifi.address ?? paths?.wifi?.address)];
  }
  return [paths?.wifi?.up ? bare(paths.wifi.address) : null];
}

export function trackedState(u: Uplink, active: boolean): [Tone, string] {
  if (!u.up || u.state === 'down') return ['neutral', 'Down'];
  switch (u.state) {
    case 'online': return ['success', 'Online'];
    case 'offline': return ['error', 'No internet'];
    case 'portal': return ['warning', 'Sign-in page'];
    case 'unchecked': return [active ? 'success' : 'neutral', active ? 'Up' : 'Checking'];
    default: return ['success', 'Up'];
  }
}

export function uplinkRows(
  sources: LinkSources,
  features: { has: (feature?: Feature) => boolean },
): LinkRow[] {
  const { paths, order, ports, network } = sources;
  if (order) {
    const byIface = new Map(order.uplinks.map((u) => [u.iface, u]));
    const ordered = [
      ...order.order.map((iface) => byIface.get(iface)).filter((u): u is Uplink => !!u),
      ...order.uplinks.filter((u) => !order.order.includes(u.iface)),
    ];
    return ordered.map((u) => {
      const active = order.active === u.iface;
      const [tone, state] = trackedState(u, active);
      let detail: (string | null | undefined)[] = [];
      if (u.kind === 'ethernet') {
        const wired = wiredPort(ports, u.iface);
        if (wired) detail = wiredDetail(wired.uplink, wired.port.link.up ? wired.port.link.speed : null);
        else if (u.device && u.device === paths?.wired.device) {
          detail = [linkSpeed(paths.wired.speed), bare(paths.wired.address)];
        }
      }
      if (u.kind === 'wifi') detail = wifiDetail(sources);
      if (u.kind === 'cellular' || u.kind === 'usb-cellular') {
        detail = [...modemDetail(paths, u.kind), u.kind === 'cellular' && u.up ? bare(network?.cellular.address) : null];
      }
      if (u.metered) detail.push('metered');
      return {
        key: u.iface,
        name: uplinkName(u.iface, u.device),
        icon: KIND_ICONS[u.kind],
        device: u.device,
        active,
        tone,
        state,
        detail,
        to: pageFor(u.kind),
        uplink: u,
      };
    });
  }

  if (!paths) return [];
  const rows: LinkRow[] = [];
  const { wired, wifi, cellular } = paths;
  const carrying = wired.up ? 'wired' : wifi?.up ? 'wifi' : cellular.up ? 'cellular' : null;
  const port = wired.iface ? wiredPort(ports, wired.iface) : null;
  rows.push({
    key: 'wired',
    name: wired.device ? portLabel(wired.device) : 'Ethernet',
    icon: EthernetPort,
    device: wired.device,
    active: carrying === 'wired',
    tone: wired.up ? 'success' : 'neutral',
    state: wired.up ? 'Up' : 'Down',
    detail: port
      ? wiredDetail(port.uplink, wired.speed)
      : [
          linkSpeed(wired.speed),
          bare(wired.address),
          wired.proto === 'static' ? 'static' : wired.proto === 'dhcp' ? 'DHCP' : null,
        ],
    to: '/backhaul/ethernet',
  });
  if (features.has('wifi') && wifi) {
    rows.push({
      key: 'wifi',
      name: 'WiFi',
      icon: Wifi,
      device: wifi.device,
      active: carrying === 'wifi',
      tone: wifi.up ? 'success' : 'neutral',
      state: wifi.up ? 'Up' : 'Down',
      detail: wifiDetail(sources),
      to: '/backhaul/wifi',
    });
  }
  if (features.has('cellular')) {
    const modem = cellular.modem;
    const usb = modem?.kind === 'hilink' || modem?.kind === 'tether';
    rows.push({
      key: 'cellular',
      name: 'Cellular',
      icon: Signal,
      device: cellular.device ?? null,
      active: carrying === 'cellular',
      tone: cellular.up ? 'success' : 'neutral',
      state: !modem ? 'No modem' : cellular.up ? 'Up' : 'Standby',
      detail: [
        ...modemDetail(paths, usb ? 'usb-cellular' : 'cellular'),
        cellular.up ? bare(network?.cellular.address) : null,
        'metered',
      ],
      to: '/backhaul/cellular',
    });
  }
  return rows;
}
