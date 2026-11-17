/**
 * Which organization a MAC address belongs to, from pulzar-net/oui: the
 * IEEE's registries as small static files on GitHub Pages, rebuilt weekly.
 *
 * A lookup fetches the file for the MAC's first four hex digits, and the one
 * for its first seven when that base is split into 36-bit assignments, and
 * takes the longest prefix that matches. React Query keeps each file, so a
 * table of devices fetches each one once, and nothing but those leading
 * digits leaves the browser. Nothing of ours is on the path.
 *
 * On a gateway the browser's requests go out through the gateway, so a lookup
 * runs only while the uplink carrying traffic is known and not metered
 * (`/uplinks/status`): never over cellular, and nothing is kept on the
 * gateway itself.
 */
import { useQuery } from '@tanstack/react-query';

const BASE = 'https://pulzar-net.github.io/oui/v1/';
const DAY = 24 * 60 * 60 * 1000;

interface Shard {
  prefixes: Record<string, string>;
  split?: string[];
}

export type Vendor = { name: string } | { private: true } | null;

function hexOf(mac: string | null | undefined): string | null {
  const h = (mac ?? '').replace(/[^0-9a-fA-F]/g, '').toUpperCase();
  return h.length === 12 ? h : null;
}

/** Locally administered: phones and laptops randomize their address, and
 * such an address has no vendor to find. */
function isPrivate(h: string): boolean {
  return (parseInt(h.slice(0, 2), 16) & 0x02) !== 0;
}

async function shard(key: string): Promise<Shard | null> {
  const r = await fetch(`${BASE}${key}.json`);
  if (r.status === 404) return null;
  if (!r.ok) throw new Error(`oui ${key}: ${r.status}`);
  return r.json();
}

const fileQuery = (key: string | null, enabled = true) => ({
  queryKey: ['oui', key],
  queryFn: () => shard(key as string),
  enabled: key !== null && enabled,
  staleTime: DAY,
  gcTime: DAY,
  retry: 1,
});

export function useVendor(mac: string | null | undefined, allowed = true): Vendor | undefined {
  const h = hexOf(mac);
  const priv = h !== null && isPrivate(h);
  const first = useQuery(fileQuery(h && !priv ? h.slice(0, 4) : null, allowed));
  const needsSlice = !!h && Array.isArray(first.data?.split) && first.data.split.includes(h.slice(0, 6));
  const slice = useQuery(fileQuery(h ? h.slice(0, 7) : null, needsSlice));
  if (!h) return null;
  if (priv) return { private: true };
  if (!allowed) return undefined;
  if (first.isLoading || (needsSlice && slice.isLoading)) return undefined;
  // Read defensively: a lookup must never break the page it sits on.
  const name = slice.data?.prefixes?.[h.slice(0, 9)]
    ?? first.data?.prefixes?.[h.slice(0, 7)]
    ?? first.data?.prefixes?.[h.slice(0, 6)];
  return typeof name === 'string' ? { name } : null;
}
