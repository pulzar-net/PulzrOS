import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { Power, RotateCw } from 'lucide-react';
import { api } from '@/services/api';
import Section from '@/components/ui/Section';
import Fact, { FactList } from '@/components/Fact';
import Notice from '@/components/ui/Notice';
import Button from '@/components/ui/Button';
import Spinner from '@/components/ui/Spinner';
import ErrorState from '@/components/ErrorState';

interface BluetoothStatus {
  state: 'on' | 'off' | 'absent';
  enabled: boolean;
  running: boolean;
  rebootRequired: boolean;
  oui: string;
  minRssi: number;
  heard: { at: number; beacons: number } | null;
}

/**
 * Scanning for parking beacons beside the LoRaWAN radio (pulzr-ble), and the
 * switch for it. The same switch is on the gateway's page in Pulzar Cloud; both
 * write pulzr.ble.enabled, so whichever was used last is what holds.
 */
export default function Bluetooth() {
  const queryClient = useQueryClient();
  const status = useQuery({
    queryKey: ['bluetooth'],
    queryFn: () => api.get<BluetoothStatus>('/bluetooth/status'),
    refetchInterval: 10_000,
  });
  const set = useMutation({
    mutationFn: (enabled: boolean) => api.post('/bluetooth', { enabled }),
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ['bluetooth'] }),
  });
  const reboot = useMutation({ mutationFn: () => api.post('/system/reboot') });

  if (status.isLoading) return <Spinner label="Reading Bluetooth" />;
  if (status.isError) return <ErrorState error={status.error} onRetry={status.refetch} />;
  const bt = status.data!;

  if (bt.state === 'absent') {
    return <Notice tone="info">This gateway has no Bluetooth radio.</Notice>;
  }

  return (
    <div className="fade-in">
      <Section
        actions={
          <>
            {bt.rebootRequired && (
              <Button loading={reboot.isPending} onClick={() => reboot.mutate()}>
                <RotateCw size={14} strokeWidth={2} />
                Reboot
              </Button>
            )}
            <Button
              variant={bt.enabled ? undefined : 'primary'}
              loading={set.isPending}
              onClick={() => set.mutate(!bt.enabled)}
            >
              <Power size={14} strokeWidth={2} />
              {bt.enabled ? 'Turn off' : 'Turn on'}
            </Button>
          </>
        }
      >
        {bt.enabled && bt.rebootRequired && <Notice tone="warning">Bluetooth starts after a reboot.</Notice>}
        {bt.enabled && !bt.rebootRequired && !bt.running && (
          <Notice tone="error">Bluetooth is on but not scanning. The log says why.</Notice>
        )}
        {set.isError && <Notice tone="error">{(set.error as Error).message}</Notice>}
        <FactList>
          <Fact label="Scanning" value={!bt.enabled ? 'Off' : bt.running ? 'Yes' : 'No'} />
          <Fact label="Beacons heard" value={bt.enabled && bt.heard ? String(bt.heard.beacons) : null} />
          <Fact label="Sending" value={bt.oui ? bt.oui.split(' ').join(', ') : 'Every beacon'} mono />
          <Fact label="Weakest sent" value={`${bt.minRssi} dBm`} />
        </FactList>
      </Section>
    </div>
  );
}
