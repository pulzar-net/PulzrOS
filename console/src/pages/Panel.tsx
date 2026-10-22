import { useMutation, useQuery } from '@tanstack/react-query';
import { Lightbulb } from 'lucide-react';
import { api } from '@/services/api';
import type { IoStatus } from '@/types';
import Section from '@/components/ui/Section';
import Badge from '@/components/ui/Badge';
import Fact, { FactList } from '@/components/Fact';
import Notice from '@/components/ui/Notice';
import Button from '@/components/ui/Button';
import Spinner from '@/components/ui/Spinner';
import ErrorState from '@/components/ErrorState';
import styles from './Pages.module.css';

/**
 * The front panel: what each light means, and what the button does.
 *
 * This page exists for two people. An installer standing at the gateway, who
 * needs to know what a blinking light is telling them and has no laptop — and
 * whoever is bringing up a new board, for whom the LED mapping is the single
 * most likely thing in a board file to be wrong. Hence the lamp test: it walks
 * every mapped LED so a wrong name is found in ten seconds rather than by
 * wondering why the cloud light never comes on.
 */

const BLINK_CODES: Array<{ led: string; state: string; means: string }> = [
  { led: 'Power', state: 'Solid', means: 'The gateway is up.' },
  { led: 'Status', state: 'Heartbeat', means: 'Healthy and adopted.' },
  { led: 'Status', state: 'Blink, 1/second', means: 'Wants attention: not adopted, or running at reduced channel count.' },
  { led: 'Status', state: 'Blink, fast', means: 'Fault: no concentrator responded at all.' },
  { led: 'Cloud', state: 'Solid', means: 'Reachable over the wired path (management tunnel).' },
  { led: 'Cloud', state: 'Blink, slow', means: 'Reachable over cellular only — working, but every byte is billed.' },
  { led: 'Cloud', state: 'Off', means: 'No management path at all.' },
  { led: 'Cellular', state: 'Solid', means: 'Modem attached.' },
  { led: 'Cellular', state: 'Blink', means: 'Modem attaching.' },
  { led: 'LoRa', state: 'Flash', means: 'One flash per uplink heard.' },
];

export default function Panel() {
  const io = useQuery({
    queryKey: ['io-status'],
    queryFn: () => api.get<IoStatus>('/io/status'),
  });

  const test = useMutation({
    mutationFn: () => api.post('/io/test'),
  });

  if (io.isLoading) return <Spinner label="Reading panel state" />;
  if (io.isError) return <ErrorState error={io.error} onRetry={io.refetch} />;

  const state = io.data!;
  const unmapped = state.leds.filter((led) => !led.present);

  return (
    <div className="fade-in">
      {test.isSuccess && (
        <Notice tone="success">
          Walking every mapped LED in turn. Watch the panel — anything that does
          not light is mapped to a name this board does not have.
        </Notice>
      )}

      <Section
        title="LEDs"
        actions={
          <Button loading={test.isPending} onClick={() => test.mutate()}>
            <Lightbulb size={14} strokeWidth={2} />
            Lamp test
          </Button>
        }
      >
        <FactList>
          {state.leds.map((led) => (
            <Fact
              key={led.logical}
              label={led.logical}
              value={
                led.present ? (
                  <span className="mono">{led.physical}</span>
                ) : (
                  <Badge tone="neutral">Not on this board</Badge>
                )
              }
            />
          ))}
        </FactList>

        {unmapped.length > 0 && state.available.length > 0 && (
          <>
            <div className={styles.divider} />
            <FactList>
              <Fact label="Unmapped" value={state.available.join(', ')} mono />
            </FactList>
          </>
        )}
      </Section>

      <Section title="Blink Codes">
        <FactList>
          {BLINK_CODES.map((code) => (
            <Fact
              key={`${code.led}-${code.state}`}
              label={`${code.led} · ${code.state}`}
              value={code.means}
            />
          ))}
        </FactList>
      </Section>

      <Section title="Reset Button">
        {state.button.reset ? (
          <FactList>
            <Fact label="Short press" value="Reports whether the gateway is manageable, on the cloud LED. Harmless." />
            <Fact
              label={`Held ${state.button.holdSeconds}s`}
              value="Factory reset: releases the gateway locally, wipes the overlay, and reboots."
            />
          </FactList>
        ) : (
          <Notice tone="info">
            This board has no reset button wired up. A factory reset has to be
            done from the System page or over SSH.
          </Notice>
        )}
      </Section>
    </div>
  );
}
