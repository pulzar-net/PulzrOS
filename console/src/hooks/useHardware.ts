import { useQuery } from '@tanstack/react-query';
import type { Hardware } from '@pulzr/ui';
import { api } from '@/services/api';
import type { SystemSummary } from '@/types';

/** PulzrOS's board pictures, hosted with its docs. */
const HOSTED = 'https://oss.pulzr.net/PulzrOS/boards';

/**
 * How this board is drawn: its case, connectors and photo, from the
 * hardware.json build.sh puts beside the console (boards/<maker>/<folder>/).
 *
 * The photo itself is the hosted copy, loaded by the browser from the web:
 * a console opened through Pulzr Cloud would otherwise pull it through the
 * gateway's tunnel, over a cellular plan, every time. The copy in the image
 * is the fallback, for a laptop on the gateway's LAN with no internet. Null
 * on an image built without a hardware.json, and the picture is a drawing.
 */
export function useHardware(): Hardware | null {
  // The same query the Overview makes: its identity names the board.
  const summary = useQuery({
    queryKey: ['system-summary'],
    queryFn: () => api.get<SystemSummary>('/system/summary'),
  });
  const board = summary.data?.identity.board;
  const q = useQuery({
    queryKey: ['hardware'],
    queryFn: async () => {
      const res = await fetch('/hardware/hardware.json', { credentials: 'same-origin' });
      return res.ok ? ((await res.json()) as Hardware & { photo?: (Hardware['photo'] & { file?: string }) | null }) : null;
    },
    staleTime: Infinity,
    retry: false,
  });
  const h = q.data;
  if (!h) return null;
  if (!h.photo?.file) return h;
  const { file, ...credit } = h.photo;
  const local = `/hardware/${file}`;
  return { ...h, photo: { ...credit, src: board ? `${HOSTED}/${board}.webp` : local, fallback: board ? local : undefined } };
}
