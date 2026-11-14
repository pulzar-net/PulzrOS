/** Formatting helpers. Pure functions, no React. */

import type { ModemKind } from '@/types';

/** Seconds as a coarse human duration: "3d 4h", "12m". */
export function duration(seconds: number | null | undefined): string {
  if (seconds == null) return '—';
  const days = Math.floor(seconds / 86400);
  const hours = Math.floor((seconds % 86400) / 3600);
  const minutes = Math.floor((seconds % 3600) / 60);
  if (days) return `${days}d ${hours}h`;
  if (hours) return `${hours}h ${minutes}m`;
  if (minutes) return `${minutes}m`;
  return `${seconds}s`;
}

/** mm:ss, for a countdown somebody is watching. Hours once there are any: a
    LAN window runs up to a day, and "1440m 00s" is not a time anyone reads. */
export function countdown(seconds: number): string {
  const safe = Math.max(0, seconds);
  if (safe >= 3600) {
    return `${Math.floor(safe / 3600)}h ${String(Math.floor((safe % 3600) / 60)).padStart(2, '0')}m`;
  }
  return `${Math.floor(safe / 60)}m ${String(safe % 60).padStart(2, '0')}s`;
}

export function bytes(value: number | null | undefined): string {
  if (value == null) return '—';
  const units = ['B', 'KB', 'MB', 'GB'];
  let n = value;
  let i = 0;
  while (n >= 1024 && i < units.length - 1) {
    n /= 1024;
    i += 1;
  }
  return `${n.toFixed(i ? 1 : 0)} ${units[i]}`;
}

/** A count with its unit, or an em dash. Avoids "0" reading as "unknown". */
export function count(value: number | null | undefined): string {
  return value == null ? '—' : value.toLocaleString();
}

/**
 * Bytes charted in one unit, chosen from the largest value, so the axis lands
 * on round numbers of that unit — 0, 50, 100 MB — rather than on round
 * numbers of bytes, which read as 47.7 MB.
 */
export function inUnit(peak: number, suffix = '') {
  const units = ['B', 'KB', 'MB', 'GB'];
  let i = 0;
  while (peak >= 1024 * 10 && i < units.length - 1) {
    peak /= 1024;
    i += 1;
  }
  const divisor = 1024 ** i;
  return {
    scale: (v: number | null) => (v == null ? null : v / divisor),
    format: (v: number) => `${Number.isInteger(v) ? v : v.toFixed(1)} ${units[i]}${suffix}`,
  };
}

const MODEM_KINDS: Record<ModemKind, string> = {
  qmi: 'QMI modem',
  mbim: 'MBIM modem',
  at: 'AT modem',
  hilink: 'HiLink dongle',
  tether: 'Tethered phone',
};

/** The cellular adapter's kind as a technician would name it. */
export function modemKind(kind: ModemKind | null | undefined): string | null {
  return kind ? MODEM_KINDS[kind] : null;
}

/** What a technician reads on the case for a port or a VLAN on one, the way
    pulzr-ports labels them: lan1 is "LAN 1", wan.20 "WAN VLAN 20", a Pi's
    eth0 "Ethernet". */
export function portLabel(device: string | null | undefined): string {
  if (!device) return 'Ethernet';
  const [port, vid] = device.split('.');
  let name = port;
  const named = /^(wan|lan)(\d*)$/.exec(port);
  const eth = /^eth(\d+)$/.exec(port);
  if (named) name = named[1].toUpperCase() + (named[2] ? ` ${named[2]}` : '');
  else if (eth) name = Number(eth[1]) === 0 ? 'Ethernet' : `Ethernet ${Number(eth[1]) + 1}`;
  return vid ? `${name} VLAN ${vid}` : name;
}

/** A wired uplink: wan, or wan_<device> for another port or a VLAN. */
export function isWiredIface(iface: string | null | undefined): boolean {
  return iface === 'wan' || !!iface?.startsWith('wan_');
}

const UPLINK_NAMES: Record<string, string> = { wwifi: 'WiFi', wwan: 'Cellular', usbwan: 'USB cellular' };

/** An uplink by name, a wired one by its port: wan_lan1 is "LAN 1". */
export function uplinkName(iface: string, device?: string | null): string {
  if (UPLINK_NAMES[iface]) return UPLINK_NAMES[iface];
  if (device) return portLabel(device);
  if (iface === 'wan') return 'Ethernet';
  // wan_wan_20 back to wan.20, wan_lan1 to lan1.
  return portLabel(iface.replace(/^wan_/, '').replace(/_(\d+)$/, '.$1'));
}
