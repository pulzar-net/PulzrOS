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
