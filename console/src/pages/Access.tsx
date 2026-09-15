import { useState } from 'react';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { Cable, Eye, EyeOff, Radio, ShieldAlert } from 'lucide-react';
import { api } from '@/services/api';
import type { AccessStatus } from '@/types';
import Card from '@/components/ui/Card';
import Badge from '@/components/ui/Badge';
import Fact, { FactList } from '@/components/Fact';
import Notice from '@/components/ui/Notice';
import Button from '@/components/ui/Button';
import { CheckboxField } from '@/components/ui/Field';
import PageHeader from '@/components/PageHeader';
import Spinner from '@/components/ui/Spinner';
import ErrorState from '@/components/ErrorState';
import WifiJoin from '@/components/WifiJoin';
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
      <PageHeader
        title="Access"
        subtitle="How to reach this gateway when the network is gone."
      />

      <ApCard state={state} onChange={refresh} />
      <WifiJoin />
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
      <Card title="Setup access point" icon={Radio}>
        <Notice tone="info">{ap.reason ?? 'This board has no WiFi radio.'}</Notice>
      </Card>
    );
  }

  return (
    <Card
      title="Setup access point"
      icon={Radio}
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
      {/* The single most important thing on this page: an open radio, and
          why it is acceptable right now. */}
      {ap.up && !ap.secured && (
        <Notice tone="warning">
          This access point is <strong>open</strong>. That is deliberate while
          the gateway is unadopted — it holds no credentials yet, and the only
          thing anyone can do through it is claim the gateway, which needs a
          Parkeze login. It becomes password-protected the moment it is adopted.
        </Notice>
      )}

      {ap.up && ap.secured && (
        <Notice tone="info">
          Broadcasting with WPA2. Anyone joining also needs a signature from
          parkeze.net before they can change anything — see Console access.
        </Notice>
      )}

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
        <p className={styles.note}>
          Read this to whoever is standing at the gateway. It is unique to this
          unit — it opens nothing else in the fleet.{' '}
          <button className={styles.linkButton} onClick={() => setShowKey(false)}>
            <EyeOff size={12} strokeWidth={2} /> Hide
          </button>
        </p>
      )}

      <div className={styles.divider} />

      <CheckboxField
        label="Allow the setup access point"
        checked={ap.enabled ?? false}
        onChange={(event) => configure.mutate({ enabled: event.target.checked })}
        hint="The master switch. Off means this gateway will never raise a radio, including when it loses its uplink — which also means a site visit is the only way back into one that drops off."
      />

      <CheckboxField
        label="Raise it automatically when the gateway goes offline"
        checked={ap.fallback ?? false}
        disabled={!ap.enabled}
        onChange={(event) => configure.mutate({ fallback: event.target.checked })}
        hint={`After ${duration(ap.fallbackAfter)} unreachable, for 30 minutes at a time. Somebody who cuts this gateway's uplink can force the radio up — and gains nothing by it, because they still need the passphrase and a signature from parkeze.net.`}
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
    </Card>
  );
}

function PortCard({ state }: { state: AccessStatus }) {
  const port = state.port;

  return (
    <Card
      title="Ethernet port"
      icon={Cable}
      note={
        port.uplink ? (
          <Badge tone="success">Uplink up</Badge>
        ) : (
          <Badge tone="neutral">No uplink</Badge>
        )
      }
    >
      <p className={styles.note}>
        There is one socket and it does not have a role. It is the backhaul and
        the console port at the same time, so there is nothing to choose and
        nothing that can be set wrong.
      </p>

      <FactList>
        <Fact
          label="Plug a laptop in"
          value={<span className="mono">https://{port.hostname}.local</span>}
        />
        <Fact
          label="Or, by address"
          value={<span className="mono">https://{port.console}</span>}
        />
        <Fact
          label="Uplink"
          value={
            port.uplink ? (
              <span className="mono">{port.uplink}</span>
            ) : (
              'No lease — nothing on this cable is offering one'
            )
          }
        />
      </FactList>

      {/* The one thing about this design that surprises people, so it is
          stated rather than left to be discovered with a laptop in hand. */}
      <Notice tone="info">
        This gateway never hands out addresses. A laptop plugged straight in
        will say it has no internet connection and give itself a
        <code> 169.254.x.x </code> address — that is expected, and the console
        is reachable at the <code>.local</code> name above as soon as it does.
      </Notice>

      {port.uplink && (
        <Notice tone="info">
          <ShieldAlert size={13} strokeWidth={2} style={{ verticalAlign: '-2px' }} />{' '}
          Nothing on this network can reach the gateway. Only a directly
          connected laptop gets to the console; management from parkeze.net
          arrives over the tunnel this gateway opens outwards.
        </Notice>
      )}
    </Card>
  );
}
