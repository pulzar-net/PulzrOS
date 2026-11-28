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
import type { RadiosStatus } from '@/pages/radios/model';
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
  /** Overview's one line: the columns below, joined. */
  detail: (string | null | undefined)[];
  /** What it is connected through: a wired link's speed, the WiFi network,
      the cellular carrier and technology. */
  link: string | null;
  /** WiFi's or the modem's signal. */
  signal: string | null;
  address: string | null;
  /** DHCP or static, on a wired uplink. */
  addressing: string | null;
  /** Its settings page. */
  to: string;
  /** The netifd interface: what a speed test of it alone names. */
  iface: string | null;
  /** Billed by the megabyte. */
  metered: boolean;
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
  /** The radios page's answer: a second radio's WiFi uplink (wwifi2) has its
      network, signal and address here, not in `access`. */
  radios?: RadiosStatus;
  /** False leaves cellular out: the add-on on a board with no modem plugged
      in (useCellular). */
  cellular?: boolean;
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

function pageFor(kind: Uplink['kind'], iface: string) {
  // The first WiFi uplink is the WiFi page's; a second radio's is joined and
  // removed on the Network page.
  if (kind === 'wifi') return iface === 'wwifi' ? '/backhaul/wifi' : '/network';
  if (kind === 'ethernet') return '/backhaul/ethernet';
  return '/backhaul/cellular';
}

const bare = (address: string | null | undefined) => address?.split('/')[0] ?? null;

type Facts = Pick<LinkRow, 'link' | 'signal' | 'address' | 'addressing'> & { model?: string | null };
const NO_FACTS: Facts = { link: null, signal: null, address: null, addressing: null };

/** What a modem says about itself. A HiLink dongle or a phone is usbwan and a
    ModemManager modem wwan, so each row takes only its own. */
function modemFacts(paths: BackhaulStatus | undefined, kind: Uplink['kind'], address: string | null): Facts {
  const modem = paths?.cellular.modem;
  if (!modem) return NO_FACTS;
  const usb = modem.kind === 'hilink' || modem.kind === 'tether';
  if (usb !== (kind === 'usb-cellular')) return NO_FACTS;
  return {
    model: modem.model ?? modemKind(modem.kind),
    link: [modem.network, modem.technology].filter(Boolean).join(' ') || null,
    signal: modem.rssi != null ? `${modem.rssi} dBm` : modem.quality != null ? `${modem.quality}%` : null,
    address,
    addressing: null,
  };
}

/** The port, or the VLAN on one, that pulzr-ports made this wired uplink. */
function wiredPort(ports: PortsStatus | undefined, iface: string) {
  for (const port of ports?.ports ?? []) {
    if (port.uplink?.iface === iface) return { port, uplink: port.uplink };
    for (const v of port.vlans) if (v.uplink?.iface === iface) return { port, uplink: v.uplink };
  }
  return null;
}

function wiredFacts(uplink: PortUplink | null | undefined, speed: number | null | undefined): Facts {
  return {
    link: linkSpeed(speed),
    signal: null,
    address: bare(uplink?.state.address),
    addressing: uplink ? (uplink.addressing.mode === 'static' ? 'Static' : 'DHCP') : null,
  };
}

function wifiFacts({ paths, access, radios }: LinkSources, iface = 'wwifi'): Facts {
  if (iface !== 'wwifi') {
    const u = radios?.uplinks.find((x) => x.iface === iface);
    const station = radios?.radios.flatMap((r) => r.interfaces).find((i) => i.id === u?.id);
    return { link: u?.ssid ?? null, signal: station?.signal != null ? `${station.signal} dBm` : null,
             address: u?.up ? bare(u.address) : null, addressing: null };
  }
  const wifi = access?.wifi;
  if (wifi?.configured) {
    return { link: wifi.ssid, signal: wifi.signal != null ? `${wifi.signal} dBm` : null,
             address: bare(wifi.address ?? paths?.wifi?.address), addressing: null };
  }
  return { ...NO_FACTS, address: paths?.wifi?.up ? bare(paths.wifi.address) : null };
}

function withFacts(f: Facts, metered: boolean) {
  const { model, ...facts } = f;
  return { ...facts, detail: [model, f.link, f.signal, f.address, f.addressing, metered ? 'metered' : null] };
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
  const withCellular = sources.cellular !== false;
  if (order) {
    const byIface = new Map(order.uplinks.map((u) => [u.iface, u]));
    const ordered = [
      ...order.order.map((iface) => byIface.get(iface)).filter((u): u is Uplink => !!u),
      ...order.uplinks.filter((u) => !order.order.includes(u.iface)),
    ].filter((u) => withCellular || (u.kind !== 'cellular' && u.kind !== 'usb-cellular'));
    return ordered.map((u) => {
      const active = order.active === u.iface;
      const [tone, state] = trackedState(u, active);
      let facts = NO_FACTS;
      if (u.kind === 'ethernet') {
        const wired = wiredPort(ports, u.iface);
        if (wired) facts = wiredFacts(wired.uplink, wired.port.link.up ? wired.port.link.speed : null);
        else if (u.device && u.device === paths?.wired.device) {
          facts = { ...NO_FACTS, link: linkSpeed(paths.wired.speed), address: bare(paths.wired.address) };
        }
      }
      if (u.kind === 'wifi') facts = wifiFacts(sources, u.iface);
      if (u.kind === 'cellular' || u.kind === 'usb-cellular') {
        facts = modemFacts(paths, u.kind, u.kind === 'cellular' && u.up ? bare(network?.cellular.address) : null);
      }
      return {
        ...withFacts(facts, u.metered),
        key: u.iface,
        name: uplinkName(u.iface, u.device),
        icon: KIND_ICONS[u.kind],
        device: u.device,
        active,
        tone,
        state,
        to: pageFor(u.kind, u.iface),
        iface: u.iface,
        metered: u.metered,
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
    ...withFacts(port
      ? wiredFacts(port.uplink, wired.speed)
      : {
          link: linkSpeed(wired.speed),
          signal: null,
          address: bare(wired.address),
          addressing: wired.proto === 'static' ? 'Static' : wired.proto === 'dhcp' ? 'DHCP' : null,
        }, false),
    to: '/backhaul/ethernet',
    iface: wired.iface ?? (wired.device ? 'wan' : null),
    metered: false,
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
      ...withFacts(wifiFacts(sources), false),
      to: '/backhaul/wifi',
      iface: 'wwifi',
      metered: false,
    });
  }
  if (features.has('cellular') && withCellular) {
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
      ...withFacts(modemFacts(paths, usb ? 'usb-cellular' : 'cellular',
                              cellular.up ? bare(network?.cellular.address) : null), true),
      to: '/backhaul/cellular',
      iface: modem ? (usb ? 'usbwan' : 'wwan') : null,
      metered: true,
    });
  }
  return rows;
}
