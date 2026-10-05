import { useEffect, useState } from 'react';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { MapPin, RotateCw } from 'lucide-react';
import { api } from '@/services/api';
import type { GnssSource, GpsStatus } from '@/types';
import Section from '@/components/ui/Section';
import Badge from '@/components/ui/Badge';
import Fact, { FactList } from '@/components/Fact';
import Notice from '@/components/ui/Notice';
import Button from '@/components/ui/Button';
import { SelectField, TextField } from '@/components/ui/Field';
import Spinner from '@/components/ui/Spinner';
import ErrorState from '@/components/ErrorState';
import styles from './Pages.module.css';

const BAUDS = [4800, 9600, 19200, 38400, 57600, 115200];

/** A source plus, for a concentrator, which one — as one value for the list. */
type Choice = 'auto' | 'modem' | 'device' | `concentrator:${number}`;

/**
 * The gateway's own position: where it comes from, what it is now, and what
 * the network server is told.
 *
 * Not the same thing as a forwarder's GNSS. A forwarder given the receiver uses
 * it for GPS time and PPS as well as position; the system position is just
 * where the gateway is, and a cellular modem or a separate puck can supply that
 * without any forwarder holding a receiver at all.
 */
export default function Gnss() {
  const queryClient = useQueryClient();
  const gps = useQuery({
    queryKey: ['gnss'],
    queryFn: () => api.get<GpsStatus>('/gnss'),
    // A cold fix takes a minute or two, and somebody on a roof is watching
    // this to know when to stop waiting.
    refetchInterval: (query) => (query.state.data?.fix ? 60_000 : 10_000),
  });

  const refresh = () => {
    queryClient.invalidateQueries({ queryKey: ['gnss'] });
    queryClient.invalidateQueries({ queryKey: ['forwarders'] });
  };
  const sync = useMutation({ mutationFn: () => api.post('/gnss/sync'), onSuccess: refresh });
  const detect = useMutation({ mutationFn: () => api.post('/gnss/detect'), onSuccess: refresh });

  if (gps.isLoading) return <Spinner label="Reading GNSS" />;
  if (gps.isError) return <ErrorState error={gps.error} onRetry={gps.refetch} />;

  const state = gps.data!;
  const reference = state.reference;
  const recorded = Boolean(reference?.latitude && reference?.longitude);

  return (
    <div className="fade-in">
      <Section
        actions={
          <>
            <Button loading={detect.isPending} onClick={() => detect.mutate()}>
              <RotateCw size={14} strokeWidth={2} />
              Re-detect
            </Button>
            <Button
              variant="primary"
              disabled={!state.fix}
              loading={sync.isPending}
              onClick={() => sync.mutate()}
            >
              <MapPin size={14} strokeWidth={2} />
              Record position
            </Button>
          </>
        }
      >
        {!state.fix && state.reason && <Notice tone="info">{state.reason}</Notice>}
        {sync.isError && <Notice tone="error">{(sync.error as Error).message}</Notice>}

        <FactList>
          <Fact
            label="Fix"
            value={
              state.fix ? (
                <Badge tone="success">Fix</Badge>
              ) : (
                <Badge tone={state.present ? 'warning' : 'neutral'}>
                  {state.present ? 'No fix' : 'No receiver'}
                </Badge>
              )
            }
          />
          {state.fix && (
            <Fact label="Position" value={`${state.latitude}, ${state.longitude}`} mono />
          )}
          {state.fix && state.altitude != null && (
            <Fact label="Altitude" value={`${state.altitude} m`} />
          )}
          {state.satellites ? <Fact label="Satellites" value={state.satellites} /> : null}
          <Fact
            label="Reported position"
            value={recorded ? `${reference!.latitude}, ${reference!.longitude}` : null}
            mono
          />
          <Fact
            label="Recorded from"
            value={
              recorded
                ? `${reference!.source ?? 'unknown'}${reference!.fixedAt ? ` · ${reference!.fixedAt}` : ''}`
                : null
            }
          />
        </FactList>
      </Section>

      <SourcePicker state={state} onApplied={refresh} />
    </div>
  );
}

function SourcePicker({ state, onApplied }: { state: GpsStatus; onApplied: () => void }) {
  const config = state.config;
  const current: Choice =
    config.source === 'concentrator' ? `concentrator:${config.slot}` : config.source;

  const [choice, setChoice] = useState<Choice>(current);
  const [device, setDevice] = useState(config.device);
  const [baud, setBaud] = useState(String(config.baud));

  useEffect(() => {
    setChoice(current);
    setDevice(config.device);
    setBaud(String(config.baud));
  }, [current, config.device, config.baud]);

  const apply = useMutation({
    mutationFn: () => {
      const [source, slot] = choice.split(':') as [GnssSource, string?];
      return api.post('/gnss/source', {
        source,
        slot: slot != null ? Number(slot) : undefined,
        device: source === 'device' ? device.trim() : undefined,
        baud: source === 'device' ? Number(baud) : undefined,
      });
    },
    onSuccess: onApplied,
  });

  const options: { value: Choice; label: string; detail?: string; disabled?: boolean }[] = [
    {
      value: 'auto',
      label: 'Automatic',
    },
    {
      value: 'modem',
      label: 'Cellular modem',
      detail: state.options.modem ? undefined : 'No GNSS',
      disabled: !state.options.modem,
    },
    ...state.options.slots.map((slot) => ({
      value: `concentrator:${slot.index}` as Choice,
      label: `Concentrator ${slot.index + 1}`,
      detail: slot.status === 'present' ? undefined : slot.status,
      disabled: slot.status !== 'present',
    })),
    {
      value: 'device',
      label: 'Separate receiver',
    },
  ];

  return (
    <Section title="Source">
      <div className={styles.choices} role="radiogroup">
        {options.map((option) => (
          <label
            key={option.value}
            className={`${styles.choice} ${choice === option.value ? styles.chosen : ''} ${
              option.disabled ? styles.unavailable : ''
            }`}
          >
            <input
              type="radio"
              name="gnss-source"
              value={option.value}
              checked={choice === option.value}
              disabled={option.disabled}
              onChange={() => setChoice(option.value)}
            />
            <span>
              <span className={styles.choiceLabel}>{option.label}</span>
              {option.detail && <span className={styles.choiceDetail}>{option.detail}</span>}
            </span>
          </label>
        ))}
      </div>

      {choice === 'device' && (
        <div className={styles.form}>
          <TextField
            label="Device"
            mono
            value={device}
            placeholder="/dev/ttyUSB0"
            onChange={(event) => setDevice(event.target.value)}
          />
          <SelectField
            label="Baud rate"
            value={baud}
            onChange={setBaud}
            options={BAUDS.map((rate) => ({ value: String(rate), label: String(rate) }))}
          />
        </div>
      )}

      {apply.isError && <Notice tone="error">{(apply.error as Error).message}</Notice>}
      {apply.isSuccess && (
        <Notice tone="success">Applied. The forwarders are restarting.</Notice>
      )}

      <div className={styles.actions}>
        <Button
          variant="primary"
          disabled={choice === current && (choice !== 'device' || (device === config.device && baud === String(config.baud)))}
          loading={apply.isPending}
          onClick={() => apply.mutate()}
        >
          Apply
        </Button>
      </div>
    </Section>
  );
}
