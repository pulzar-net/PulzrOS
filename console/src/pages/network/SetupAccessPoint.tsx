import { useState } from 'react';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { Eye, EyeOff, Radio, Router } from 'lucide-react';
import { api } from '@/services/api';
import type { AccessStatus } from '@/types';
import Section from '@/components/ui/Section';
import Badge from '@/components/ui/Badge';
import Fact, { FactList } from '@/components/Fact';
import Notice from '@/components/ui/Notice';
import Button from '@/components/ui/Button';
import { CheckboxField } from '@/components/ui/Field';
import { duration } from '@/lib/format';
import styles from '../Pages.module.css';

/**
 * The setup access point: a radio anyone in range can see, off by default,
 * for reaching the console when the normal ways have stopped working (see
 * docs/src/content/docs/access.md). On the Network page under WiFi since the
 * Access page went (owner, 23 Nov 2026); the management tunnel went to
 * Backhaul, and the Ethernet and USB console addresses are the Ports page's.
 */
export default function SetupAccessPoint() {
  const queryClient = useQueryClient();
  const access = useQuery({
    queryKey: ['access'],
    queryFn: () => api.get<AccessStatus>('/access/status'),
    // Ticks the AP's remaining-window countdown without a second timer.
    refetchInterval: (query) => (query.state.data?.ap.up ? 10_000 : 30_000),
  });
  if (!access.data) return null;
  return <ApCard state={access.data} onChange={() => queryClient.invalidateQueries({ queryKey: ['access'] })} />;
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
      <Section title="Setup Access Point" icon={Router}>
        <Notice tone="info">{ap.reason ?? 'This board has no WiFi radio.'}</Notice>
      </Section>
    );
  }

  return (
    <Section
      title="Setup Access Point"
      icon={Router}
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
        {ap.address && (
          <Fact label="Console address" value={<span className="mono">https://{ap.address}</span>} />
        )}
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
        {ap.raisedByButton && <Fact label="Raised by" value="Reset button" />}
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

      <CheckboxField
        label="Raise it with four presses of the reset button"
        checked={ap.button ?? false}
        onChange={(event) => configure.mutate({ button: event.target.checked })}
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
