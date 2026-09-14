import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { MapPin, Satellite } from 'lucide-react';
import { api } from '@/services/api';
import type { GpsStatus } from '@/types';
import Card from './ui/Card';
import Badge from './ui/Badge';
import Fact, { FactList } from './Fact';
import Notice from './ui/Notice';
import Button from './ui/Button';
import Spinner from './ui/Spinner';
import styles from '@/pages/Pages.module.css';

/**
 * GNSS: where the gateway thinks it is, and what it tells the network server.
 *
 * Those are two different things and the card shows both, because they come
 * apart in a way that is otherwise invisible. A gateway reports its
 * *reference* position — captured once at install — whether or not the
 * receiver has a fix on any given boot. So a unit whose antenna was knocked
 * loose in March keeps announcing March's coordinates quite happily, and the
 * only way to notice is to see the live fix missing next to it.
 */
export default function GpsCard() {
  const queryClient = useQueryClient();

  const gps = useQuery({
    queryKey: ['gps'],
    queryFn: () => api.get<GpsStatus>('/lorawan/gps'),
    // A receiver acquiring its first fix takes a minute or two from cold, and
    // somebody on a roof is watching this to know when to stop waiting.
    refetchInterval: (query) => (query.state.data?.fix ? 60_000 : 10_000),
  });

  const sync = useMutation({
    mutationFn: () => api.post('/lorawan/gps/sync'),
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ['gps'] }),
  });

  const detect = useMutation({
    mutationFn: () => api.post('/lorawan/gps/detect'),
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ['gps'] }),
  });

  if (gps.isLoading) {
    return (
      <Card title="GNSS" icon={Satellite}>
        <Spinner label="Reading the receiver" />
      </Card>
    );
  }

  const state = gps.data;
  const reference = state?.reference;
  const hasReference = Boolean(reference?.latitude && reference?.longitude);

  // The failure worth calling out: announcing a position while blind.
  const staleReference = hasReference && state?.present && !state.fix;

  return (
    <Card
      title="GNSS"
      icon={Satellite}
      note={
        state?.fix ? (
          <Badge tone="success">{state.satellites ?? 0} satellites</Badge>
        ) : state?.present ? (
          <Badge tone="warning">No fix</Badge>
        ) : (
          <Badge tone="neutral">No receiver</Badge>
        )
      }
      actions={
        <Button loading={detect.isPending} onClick={() => detect.mutate()}>
          Re-detect
        </Button>
      }
    >
      {!state?.present && (
        <Notice tone="info">
          No GNSS receiver was found. That is normal for a gateway without one —
          it will report the reference position below instead. On a Pi with an
          SPI concentrator HAT the receiver is usually on the serial port; check
          it is not being claimed by a UART concentrator.
        </Notice>
      )}

      {state?.present && !state.fix && state.reason && (
        <Notice tone="warning">{state.reason}</Notice>
      )}

      {staleReference && (
        <Notice tone="warning">
          This gateway is announcing its recorded position but the receiver has
          no fix right now. If the antenna has been disturbed, the announced
          coordinates will keep looking correct while being wrong.
        </Notice>
      )}

      <FactList>
        <Fact
          label="Live fix"
          value={
            state?.fix
              ? `${state.latitude?.toFixed(6)}, ${state.longitude?.toFixed(6)}`
              : null
          }
          mono
        />
        <Fact
          label="Altitude"
          value={state?.fix && state.altitude != null ? `${state.altitude} m` : null}
        />
        <Fact
          label="Read via"
          value={
            state?.source === 'forwarder'
              ? 'the packet forwarder, which holds the receiver'
              : state?.source === 'direct'
                ? 'a direct read'
                : null
          }
        />
        <Fact label="Device" value={state?.device} mono />
      </FactList>

      <div className={styles.divider} />

      <p className={styles.note}>
        The <strong>reported</strong> position is what this gateway announces to
        the network server. It is captured once at install so a gateway keeps
        reporting correctly on a boot with no sky view.
      </p>

      <FactList>
        <Fact
          label="Reported"
          value={hasReference ? `${reference!.latitude}, ${reference!.longitude}` : null}
          mono
        />
        <Fact
          label="Source"
          value={
            reference?.source === 'gnss'
              ? `Captured from GNSS${
                  reference.fixedAt
                    ? ` on ${new Date(reference.fixedAt).toLocaleDateString()}`
                    : ''
                }`
              : hasReference
                ? 'Set manually'
                : null
          }
        />
      </FactList>

      {sync.isError && <Notice tone="error">{(sync.error as Error).message}</Notice>}
      {sync.isSuccess && <Notice tone="success">Position recorded.</Notice>}

      <div className={styles.actions}>
        <Button
          variant="primary"
          disabled={!state?.fix}
          loading={sync.isPending}
          onClick={() => sync.mutate()}
          title={
            state?.fix
              ? undefined
              : 'Needs a live fix — there is nothing to record without one.'
          }
        >
          <MapPin size={14} strokeWidth={2} />
          Use this position
        </Button>
      </div>
    </Card>
  );
}
