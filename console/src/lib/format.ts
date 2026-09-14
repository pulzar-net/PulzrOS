/** Formatting helpers. Pure functions, no React. */

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

/** mm:ss, for a countdown somebody is watching. */
export function countdown(seconds: number): string {
  const safe = Math.max(0, seconds);
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
 * RSSI to a five-step quality band, matching the --signal-* tokens.
 *
 * The thresholds are the conventional LTE ones. They are here rather than
 * inline so the coverage colours mean the same thing everywhere they appear.
 */
export function signalBand(
  rssi: number | null | undefined,
): 'none' | 'weak' | 'fair' | 'good' | 'strong' {
  if (rssi == null) return 'none';
  if (rssi < -100) return 'weak';
  if (rssi < -85) return 'fair';
  if (rssi < -70) return 'good';
  return 'strong';
}
