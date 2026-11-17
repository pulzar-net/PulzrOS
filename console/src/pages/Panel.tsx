import { useMutation, useQuery } from '@tanstack/react-query';
import { Lightbulb, RotateCcw, Sparkles } from 'lucide-react';
import { api } from '@/services/api';
import type { IoStatus, PanelLight } from '@/types';
import Section from '@/components/ui/Section';
import Badge from '@/components/ui/Badge';
import Fact, { FactList } from '@/components/Fact';
import Notice from '@/components/ui/Notice';
import Button from '@/components/ui/Button';
import Spinner from '@/components/ui/Spinner';
import ErrorState from '@/components/ErrorState';
import styles from './Panel.module.css';

/**
 * The front panel: what each light is, what it is doing, and what the button
 * does.
 *
 * This page exists for two people. An installer standing at the gateway, who
 * needs to know what a blinking light is telling them and has no laptop — and
 * whoever is bringing up a new board, for whom the LED mapping is the single
 * most likely thing in a board file to be wrong. Hence the lamp test: it walks
 * every mapped LED so a wrong name is found in ten seconds rather than by
 * wondering why the cloud light never comes on.
 *
 * The lights are the board's own list (PULZR_LEDS), so a board shows the
 * lights it has and no others. A board without one shows whatever the kernel
 * exposes, by sysfs name.
 */

/** pulzr-io's codes, by the logical light that shows them. */
const BLINK_CODES: Array<{ led: 'power' | 'status' | 'cloud' | 'cellular' | 'lora'; state: string; means: string }> = [
  { led: 'power', state: 'Solid', means: 'Up' },
  { led: 'status', state: 'Heartbeat', means: 'Healthy and adopted' },
  { led: 'status', state: 'Blink, 1/s', means: 'Not adopted, or running at a reduced channel count' },
  { led: 'status', state: 'Blink, fast', means: 'No concentrator responded' },
  { led: 'cloud', state: 'Solid', means: 'Reachable over the wired path' },
  { led: 'cloud', state: 'Blink, slow', means: 'Reachable over cellular only' },
  { led: 'cloud', state: 'Off', means: 'No management path' },
  { led: 'cellular', state: 'Solid', means: 'Modem attached' },
  { led: 'cellular', state: 'Blink', means: 'Modem attaching' },
  { led: 'lora', state: 'Flash', means: 'Uplinks heard since the last poll' },
];

const ROLE_NAMES: Record<NonNullable<PanelLight['role']>, string> = {
  power: 'Power',
  status: 'Status',
  cloud: 'Cloud',
  lora: 'LoRa',
  ethernet: 'Ethernet',
  wifi: 'WiFi',
  cellular: 'Cellular',
  bluetooth: 'Bluetooth',
};

const LOGICAL_NAMES: Record<string, string> = {
  power: 'Power', status: 'Status', cloud: 'Cloud', cellular: 'Cellular', lora: 'LoRa',
};

/** The kernel's trigger names, as what the light is doing. */
function stateName(state: string | null) {
  if (!state) return null;
  const [colour, trigger] = state.includes(' ') ? state.split(' ', 2) : [null, state];
  const word: Record<string, string> = {
    on: 'On', off: 'Off', heartbeat: 'Heartbeat', timer: 'Blinking', pattern: 'Breathing',
    oneshot: 'Flashes', netdev: 'Link', default_on: 'On',
  };
  const name = word[trigger] ?? (trigger.startsWith('phy') ? 'Radio' : trigger);
  return colour ? `${colour[0].toUpperCase()}${colour.slice(1)}, ${name.toLowerCase()}` : name;
}

export default function Panel() {
  const io = useQuery({
    queryKey: ['io-status'],
    queryFn: () => api.get<IoStatus>('/io/status'),
    refetchInterval: 5_000,
  });

  const test = useMutation({
    mutationFn: () => api.post('/io/test'),
  });

  if (io.isLoading) return <Spinner label="Reading panel state" />;
  if (io.isError) return <ErrorState error={io.error} onRetry={io.refetch} />;

  const state = io.data!;
  // Firmware from before the board's list: what the kernel has, from the
  // older fields.
  const panel = state.panel ?? {
    source: 'kernel' as const,
    lights: [...state.leds.filter((l) => l.present).map((l) => l.physical!), ...state.available].map(
      (name): PanelLight => ({ name, colour: null, role: null, label: null, present: true, state: null }),
    ),
  };
  const mapped = new Set(state.leds.filter((l) => l.present).map((l) => (l.logical === 'lora2' ? 'lora' : l.logical)));
  const codes = BLINK_CODES.filter((code) => mapped.has(code.led));

  return (
    <div className="fade-in">
      {test.isSuccess && <Notice tone="success">Lamp test running.</Notice>}

      <Section
        title="LEDs"
        icon={Lightbulb}
        actions={
          mapped.size > 0 ? (
            <Button loading={test.isPending} onClick={() => test.mutate()}>
              <Lightbulb size={14} strokeWidth={2} />
              Lamp test
            </Button>
          ) : undefined
        }
      >
        {panel.lights.length === 0 ? (
          <div className={styles.empty}>No LEDs</div>
        ) : (
          <div className={styles.lights}>
            {panel.lights.map((light) => (
              <div key={light.name} className={styles.light}>
                <span
                  className={`${styles.lamp} ${light.state && light.state !== 'off' ? styles.lit : ''}`}
                  data-colour={light.colour ?? 'unknown'}
                  aria-hidden
                />
                <span className={styles.main}>
                  <span className={styles.label}>{light.label ?? light.name}</span>
                  <span className={styles.meta}>
                    {light.role && <span>{ROLE_NAMES[light.role]}</span>}
                    {light.label && <span className="mono">{light.name}</span>}
                  </span>
                </span>
                {light.present ? (
                  <span className={styles.state}>{stateName(light.state)}</span>
                ) : (
                  <Badge tone="error">Missing</Badge>
                )}
              </div>
            ))}
          </div>
        )}
      </Section>

      {codes.length > 0 && (
        <Section title="Blink Codes" icon={Sparkles}>
          <FactList>
            {codes.map((code) => (
              <Fact
                key={`${code.led}-${code.state}`}
                label={`${LOGICAL_NAMES[code.led]} · ${code.state}`}
                value={code.means}
              />
            ))}
          </FactList>
        </Section>
      )}

      {state.button.reset && (
        <Section title="Reset Button" icon={RotateCcw}>
          <FactList>
            <Fact label="Short press" value="Shows on the cloud light whether the gateway is manageable" />
            <Fact label="Four short presses" value="Raises the setup AP; with a working uplink, refuses and flashes every light" />
            <Fact label={`Held ${state.button.holdSeconds} s`} value="Factory reset: releases the gateway, wipes the overlay, reboots" />
          </FactList>
        </Section>
      )}
    </div>
  );
}
