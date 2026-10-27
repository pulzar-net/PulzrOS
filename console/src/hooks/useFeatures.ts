import { useQuery } from '@tanstack/react-query';
import { api } from '@/services/api';
import type { Feature } from '@/types';

/**
 * What this board was built with (PARKEZE_FEATURES; docs/features.md).
 *
 * Fixed for the life of the image, so asked once. Until it answers nothing
 * gated is shown, rather than a sidebar that grows and then shrinks. If it
 * cannot answer at all, everything is shown: the API refuses a feature the
 * board lacks anyway, and a console with pages missing for no reason is worse
 * than one whose extra page says so.
 */
export function useFeatures() {
  const query = useQuery({
    queryKey: ['features'],
    queryFn: () => api.get<{ features: Feature[] }>('/system/features'),
    staleTime: Infinity,
    retry: 2,
  });
  const list = query.data?.features;
  return {
    loading: query.isLoading,
    has: (feature?: Feature) =>
      !feature || (list ? list.includes(feature) : query.isError),
  };
}
