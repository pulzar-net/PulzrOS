import { useQuery } from '@tanstack/react-query';
import type { Hardware } from '@pulzr/ui';

/**
 * How this board is drawn: its case, connectors and photo, from the
 * hardware.json build.sh puts beside the console (boards/<maker>/<folder>/).
 * A static file, not the API: it is the image's, not the gateway's state.
 * Null on an image built without one, and the pictures fall back to a
 * drawing.
 */
export function useHardware(): Hardware | null {
  const q = useQuery({
    queryKey: ['hardware'],
    queryFn: async () => {
      const res = await fetch('/hardware/hardware.json', { credentials: 'same-origin' });
      if (!res.ok) return null;
      const h = (await res.json()) as Hardware & { photo?: { file?: string } | null };
      if (h.photo?.file) h.photo = { ...h.photo, src: `/hardware/${h.photo.file}` } as Hardware['photo'];
      return h as Hardware;
    },
    staleTime: Infinity,
    retry: false,
  });
  return q.data ?? null;
}
