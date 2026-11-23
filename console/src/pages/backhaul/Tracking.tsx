import { useState } from 'react';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { Radar } from 'lucide-react';
import { api } from '@/services/api';
import type { UplinkIface, UplinksStatus } from '@/types';
import Section from '@/components/ui/Section';
import Button from '@/components/ui/Button';
import Notice from '@/components/ui/Notice';
import Segmented from '@/components/ui/Segmented';
import { TextField } from '@/components/ui/Field';
import Spinner from '@/components/ui/Spinner';
import ErrorState from '@/components/ErrorState';
import ApplyChangeNotice from '@/components/ApplyChangeNotice';
import { useApplyChange, type Pending } from '@/hooks/useApplyChange';
import { useCellular } from '@/hooks/useCellular';
import { uplinkName } from '@/lib/format';
import pages from '../Pages.module.css';
import styles from './Backhaul.module.css';

/**
 * Which uplinks are pinged and how, a page of its own under Backhaul (it was
 * a card under the connections). The WiFi's health is pulzr-wifi-uplink's
 * portal check, so it has no switch. Cellular is untracked until somebody
 * turns it on, because every ping is billed.
 */

const SWITCH = [
  { value: 'on', label: 'On' },
  { value: 'off', label: 'Off' },
] as const;

export default function Tracking() {
  const queryClient = useQueryClient();
  const change = useApplyChange();
  const cellular = useCellular();
  const status = useQuery({
    queryKey: ['uplinks'],
    queryFn: () => api.get<UplinksStatus>('/uplinks/status'),
    refetchInterval: 10_000,
  });
  const refresh = () => {
    queryClient.invalidateQueries({ queryKey: ['uplinks'] });
    queryClient.invalidateQueries({ queryKey: ['backhaul'] });
  };
  const track = useMutation({
    mutationFn: (body: { iface: UplinkIface; on: boolean }) =>
      api.post<{ pending?: Pending }>('/uplinks/track', body),
    onSuccess: (answer) => { change.watch(answer.pending); refresh(); },
  });

  if (status.isLoading) return <Spinner label="Reading the uplinks" />;
  if (status.isError) return <ErrorState error={status.error} onRetry={status.refetch} />;
  const s = status.data!;
  const uplinks = s.uplinks.filter((u) => cellular.shown || (u.kind !== 'cellular' && u.kind !== 'usb-cellular'));
  const busy = track.isPending || change.phase === 'confirming';

  return (
    <div className="fade-in">
      <ApplyChangeNotice change={change} />
      <Section title="Tracking" icon={Radar}>
        {track.isError && <Notice tone="error">{(track.error as Error).message}</Notice>}
        <div className={styles.switches}>
          {uplinks.map((u) => (
            <div key={u.iface} className={styles.switch}>
              <span>{uplinkName(u.iface, u.device)}</span>
              {u.iface === 'wwifi' ? (
                <span className={pages.dim}>Portal check</span>
              ) : (
                <Segmented
                  aria-label={`Tracking for ${uplinkName(u.iface, u.device)}`}
                  value={u.tracked ? 'on' : 'off'}
                  options={[...SWITCH]}
                  disabled={busy}
                  onChange={(next) => track.mutate({ iface: u.iface, on: next === 'on' })}
                />
              )}
            </div>
          ))}
        </div>
        <Settings tracking={s.tracking} onApplied={(pending) => { change.watch(pending); refresh(); }} />
      </Section>
    </div>
  );
}

function Settings({ tracking: t, onApplied }: { tracking: UplinksStatus['tracking']; onApplied: (p?: Pending) => void }) {
  const [ips, setIps] = useState(t.ips.join(', '));
  const [every, setEvery] = useState(String(t.interval));
  const [down, setDown] = useState(String(t.down));
  const [up, setUp] = useState(String(t.up));

  const apply = useMutation({
    mutationFn: () =>
      api.post<{ pending?: Pending }>('/uplinks/tracking', {
        ips: ips.split(',').map((ip) => ip.trim()).filter(Boolean),
        interval: Number(every),
        down: Number(down),
        up: Number(up),
      }),
    onSuccess: (answer) => onApplied(answer.pending),
  });

  return (
    <>
      <div className={pages.form}>
        <TextField label="Ping" mono value={ips} placeholder="1.1.1.1, 8.8.8.8"
                   onChange={(event) => setIps(event.target.value)} />
        <TextField label="Every (seconds)" inputMode="numeric" value={every}
                   onChange={(event) => setEvery(event.target.value)} />
        <TextField label="Down after (misses)" inputMode="numeric" value={down}
                   onChange={(event) => setDown(event.target.value)} />
        <TextField label="Back after (answers)" inputMode="numeric" value={up}
                   onChange={(event) => setUp(event.target.value)} />
      </div>
      {apply.isError && <Notice tone="error">{(apply.error as Error).message}</Notice>}
      <div className={pages.actions}>
        <Button variant="primary" loading={apply.isPending} onClick={() => apply.mutate()}>
          Apply
        </Button>
      </div>
    </>
  );
}
