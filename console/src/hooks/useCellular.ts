import { useQuery } from '@tanstack/react-query';
import { api } from '@/services/api';
import type { AddonStatus, BackhaulStatus } from '@/types';
import { useFeatures } from '@/hooks/useFeatures';

/**
 * Whether cellular belongs on screen: its Backhaul row and sidebar entry,
 * its Tracking switch, Overview's row.
 *
 * Cellular is the pulzr-cellular add-on. Built into a board with a soldered
 * modem (the RAKs), it shows from first boot whether or not the modem
 * answers, because a missing soldered modem is a fault somebody has to see.
 * Installed as an add-on (a Pi, the GL-SFT1200, a RAK7391), it shows only
 * while a modem is plugged in: an empty USB port is not a dead uplink.
 */
export function useCellular() {
  const features = useFeatures();
  const installed = features.has('cellular');
  const addons = useQuery({
    queryKey: ['system-addons'],
    queryFn: () => api.get<AddonStatus>('/system/addons'),
    enabled: installed,
    staleTime: 60_000,
  });
  const backhaul = useQuery({
    queryKey: ['backhaul'],
    queryFn: () => api.get<BackhaulStatus>('/network/backhaul'),
    enabled: installed,
    staleTime: 15_000,
  });
  const builtIn = addons.data?.items?.['pulzr-cellular']?.builtIn === true;
  const present = Boolean(backhaul.data?.cellular.modem);
  return { installed, shown: installed && (builtIn || present) };
}
