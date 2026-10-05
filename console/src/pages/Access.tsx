import { useState } from 'react';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { Eye, EyeOff, Radio } from 'lucide-react';
import { api } from '@/services/api';
import type { AccessStatus, BackhaulStatus } from '@/types';
import Section from '@/components/ui/Section';
import Badge, { StatusBadge } from '@/components/ui/Badge';
import Fact, { FactList } from '@/components/Fact';
import Notice from '@/components/ui/Notice';
import Button from '@/components/ui/Button';
import { CheckboxField } from '@/components/ui/Field';
import Spinner from '@/components/ui/Spinner';
import ErrorState from '@/components/ErrorState';
import { duration } from '@/lib/format';
import styles from './Pages.module.css';

/**
 * How you get to this gateway when the normal ways have stopped working.
 *
 * Two mechanisms, and they have opposite risk profiles, so the page keeps them
 * visually separate rather than merging them into "connectivity settings":
 *
 *   the ethernet port   always there, always the same, nothing to configure.
 *                       Read-only here: there is no decision left to make.
 *   the setup AP        a radio anyone in range can see, off by default.
 *                       Powerful, and the thing most worth being careful with.
 *
 * See docs/access.md for the reasoning behind both.
 */
export default function Access() {
  const queryClient = useQueryClient();
  const refresh = () => queryClient.invalidateQueries({ queryKey: ['access'] });

  const access = useQuery({
    queryKey: ['access'],
    queryFn: () => api.get<AccessStatus>('/access/status'),
    // Ticks the AP's remaining-window countdown without a second timer.
    refetchInterval: (query) => (query.state.data?.ap.up ? 10_000 : 30_000),
  });

  if (access.isLoading) return <Spinner label="Reading access state" />;
  if (access.isError) return <ErrorState error={access.error} onRetry={access.refetch} />;

  const state = access.data!;

  return (
    <div className="fade-in">
      <ApCard state={state} onChange={refresh} />
      <Tunnel />
      <PortCard state={state} />
    </div>
  );
}

function ApCard({ state, onChange }: { state: AccessStatus; onChange: () => void }) {
  const [showKey, setShowKey] = useState(false);
  const ap = state.ap;

  const key = useQuery({
    queryKey: ['ap-key'],
    queryFn: () => api.get<{ open: boolean; key: string | null; note?: string }>('/access/key'),
    enabled: showKey,
  });

  const configure = useMutation({
    mutationFn: (body: Record<string, unknown>) => api.post('/access/ap', body),
    onSuccess: onChange,
  });
  const raise = useMutation({
    mutationFn: () => api.post('/access/ap/up', { window: 1800 }),
    onSuccess: onChange,
  });
  const lower = useMutation({
    mutationFn: () => api.post('/access/ap/down'),
    onSuccess: onChange,
  });

  if (!ap.capable) {
    return (
      <Section title="Setup access point">
        <Notice tone="info">{ap.reason ?? 'This board has no WiFi radio.'}</Notice>
      </Section>
    );
  }

  return (
    <Section
      title="Setup access point"
      note={
        ap.up ? (
          <Badge tone="warning">Broadcasting</Badge>
        ) : ap.enabled ? (
          <Badge tone="neutral">Standby</Badge>
        ) : (
          <Badge tone="neutral">Disabled</Badge>
        )
      }
    >
      <FactList>
        <Fact label="Network" value={ap.ssid} mono />
        <Fact
          label="Security"
          value={
            ap.secured ? (
              <Badge tone="success">WPA2, per-device key</Badge>
            ) : (
              <Badge tone="warning">Open — gateway is unadopted</Badge>
            )
          }
        />
        <Fact label="Connected" value={ap.clients ? `${ap.clients} device(s)` : 'Nobody'} />
        {ap.up && (ap.remainingSeconds ?? 0) > 0 && (
          <Fact label="Comes down in" value={duration(ap.remainingSeconds)} />
        )}
        {ap.secured && (
          <Fact
            label="Passphrase"
            value={
              showKey ? (
                key.isLoading ? (
                  'Reading…'
                ) : (
                  <span className="mono">{key.data?.key ?? '—'}</span>
                )
              ) : (
                <button className={styles.linkButton} onClick={() => setShowKey(true)}>
                  <Eye size={12} strokeWidth={2} /> Show
                </button>
              )
            }
          />
        )}
      </FactList>

      {showKey && (
        <button className={styles.linkButton} onClick={() => setShowKey(false)}>
          <EyeOff size={12} strokeWidth={2} /> Hide
        </button>
      )}

      <div className={styles.divider} />

      <CheckboxField
        label="Allow the setup access point"
        checked={ap.enabled ?? false}
        onChange={(event) => configure.mutate({ enabled: event.target.checked })}
      />

      <CheckboxField
        label="Raise it automatically when the gateway goes offline"
        checked={ap.fallback ?? false}
        disabled={!ap.enabled}
        onChange={(event) => configure.mutate({ fallback: event.target.checked })}
      />

      <div className={styles.actions}>
        {ap.up ? (
          <Button variant="danger" loading={lower.isPending} onClick={() => lower.mutate()}>
            Take it down now
          </Button>
        ) : (
          <Button
            disabled={!ap.enabled}
            loading={raise.isPending}
            onClick={() => raise.mutate()}
          >
            <Radio size={14} strokeWidth={2} />
            Raise it for 30 minutes
          </Button>
        )}
      </div>
    </Section>
  );
}

/**
 * How parkeze.net reaches this gateway: a WireGuard tunnel the gateway opens
 * outwards, so nothing at the site has to accept an inbound connection.
 */
function Tunnel() {
  const paths = useQuery({
    queryKey: ['backhaul'],
    queryFn: () => api.get<BackhaulStatus>('/network/backhaul'),
    refetchInterval: 15_000,
  });
  const tunnel = paths.data?.tunnel;

  return (
    <Section title="Management tunnel">
      <FactList>
        <Fact
          label="State"
          value={
            tunnel ? (
              <StatusBadge
                ok={tunnel.state === 'up'}
                okLabel="Connected"
                badLabel={
                  tunnel.state === 'none'
                    ? 'Not enrolled'
                    : tunnel.state === 'waiting'
                      ? 'No recent handshake'
                      : 'Unknown'
                }
              />
            ) : null
          }
        />
        <Fact label="Address" value={tunnel?.address} mono />
        <Fact label="Hub" value={tunnel?.endpoint} mono />
        <Fact
          label="Last handshake"
          value={tunnel?.lastHandshake != null ? `${tunnel.lastHandshake}s ago` : null}
        />
        <Fact
          label="Egress"
          value={
            paths.data?.wired.device ? (
              <span className="mono">
                {paths.data.wired.device} → {paths.data.wired.gateway}
              </span>
            ) : paths.data ? (
              <Badge tone="warning">No wired route</Badge>
            ) : null
          }
        />
      </FactList>
    </Section>
  );
}

function PortCard({ state }: { state: AccessStatus }) {
  const port = state.port;

  return (
    <Section
      title="Ethernet port"
      note={
        port.uplink ? (
          <Badge tone="success">Uplink up</Badge>
        ) : (
          <Badge tone="neutral">No uplink</Badge>
        )
      }
    >
      <FactList>
        <Fact
          label="Local name"
          value={<span className="mono">https://{port.hostname}.local</span>}
        />
        <Fact
          label="Console address"
          value={<span className="mono">https://{port.console}</span>}
        />
        <Fact
          label="Uplink"
          value={
            port.uplink ? (
              <span className="mono">{port.uplink}</span>
            ) : (
              'No lease'
            )
          }
        />
      </FactList>

    </Section>
  );
}
