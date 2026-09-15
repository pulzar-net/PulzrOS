import { useState } from 'react';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { Cable, Eye, EyeOff, Radio, ShieldAlert, Wifi } from 'lucide-react';
import { api } from '@/services/api';
import type { AccessStatus } from '@/types';
import Card from '@/components/ui/Card';
import Badge from '@/components/ui/Badge';
import Fact, { FactList } from '@/components/Fact';
import Notice from '@/components/ui/Notice';
import Button from '@/components/ui/Button';
import { CheckboxField, SelectField } from '@/components/ui/Field';
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
 *   the setup AP    a radio anyone in range can see. Powerful, and the thing
 *                   most worth being careful with.
 *   LAN DHCP        harmless to us, potentially an outage for whoever owns the
 *                   network the port is patched into.
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
      <LanCard state={state} onChange={refresh} />
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

function LanCard({ state, onChange }: { state: AccessStatus; onChange: () => void }) {
  const port = state.port;

  const configure = useMutation({
    mutationFn: (mode: string) => api.post('/access/lan', { mode }),
    onSuccess: onChange,
  });
  const probe = useMutation({
    mutationFn: () => api.post('/access/lan/probe'),
    onSuccess: onChange,
  });

  return (
    <Card
      title="Ethernet port"
      icon={Cable}
      note={
        port.role === 'wan' ? (
          <Badge tone="info">Backhaul</Badge>
        ) : port.role === 'lan' ? (
          <Badge tone="success">Console port</Badge>
        ) : (
          <Badge tone="neutral">Deciding…</Badge>
        )
      }
    >
      <p className={styles.note}>
        There is one ethernet socket, so it is either the uplink or the console
        port. Plugged into a network it takes an address and carries the
        backhaul; plugged into a laptop it hands one out.
      </p>

      <FactList>
        <Fact
          label="Right now"
          value={
            port.role === 'wan'
              ? 'Backhaul — taking an address, accepting nothing inbound'
              : port.role === 'lan'
                ? 'Console port — handing out addresses'
                : 'Not decided yet'
          }
        />
        <Fact label="Because" value={port.reason} />
        <Fact
          label="Always reachable at"
          value={<span className="mono">https://{state.ap.ssid?.replace('parkeze_', 'parkeze-') ?? 'parkeze'}.local</span>}
        />
      </FactList>

      {/* The failure this design is built around: serving DHCP onto a network
          we do not own. Worth saying out loud wherever somebody can turn the
          safety off. */}
      {port.configured === 'lan' && (
        <Notice tone="warning">
          <ShieldAlert size={13} strokeWidth={2} style={{ verticalAlign: '-2px' }} />{' '}
          Pinned to console port. This gateway will hand out addresses even when
          plugged into a network that already has a DHCP server — which is an
          outage for whoever owns that network. Only leave this set if you know
          what is on the other end of the cable.
        </Notice>
      )}

      {port.configured === 'auto' && port.role === 'wan' &&
        port.reason.includes('busy') && (
        <Notice tone="info">
          Nothing is handing out addresses here, but the segment is busy — most
          likely a statically addressed network. The port stays a backhaul
          rather than risk answering DHCP on it. Reach the console at the
          <code> .local</code> name above, or pin the role below.
        </Notice>
      )}

      <div className={styles.divider} />

      <SelectField
        label="Role"
        value={port.configured}
        onChange={(event) => configure.mutate(event.target.value)}
        hint="Automatic decides from what is on the cable, every time it is plugged in, and resolves anything ambiguous to backhaul."
      >
        <option value="auto">Automatic — decide from what is connected</option>
        <option value="wan">Always the backhaul</option>
        <option value="lan">Always the console port</option>
      </SelectField>

      <div className={styles.actions}>
        <Button loading={probe.isPending} onClick={() => probe.mutate()}>
          <Wifi size={14} strokeWidth={2} />
          Check the cable again
        </Button>
      </div>
    </Card>
  );
}
