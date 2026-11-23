import { useState } from 'react';
import { ArrowRightLeft, Globe } from 'lucide-react';
import { useMutation, useQueryClient } from '@tanstack/react-query';
import { api } from '@/services/api';
import type { LanClient, LanExposed, LanForward, LanStatus } from '@/types';
import Section from '@/components/ui/Section';
import Button from '@/components/ui/Button';
import Notice from '@/components/ui/Notice';
import Segmented from '@/components/ui/Segmented';
import { SelectField, TextField } from '@/components/ui/Field';
import Fact, { FactList } from '@/components/Fact';
import Spinner from '@/components/ui/Spinner';
import ErrorState from '@/components/ErrorState';
import { duration } from '@/lib/format';
import { useLanStatus } from './Lan';
import styles from '../Pages.module.css';

/**
 * Network > Port Forwarding: ports on the wired and WiFi uplinks forwarded
 * to a reserved client for good (pulzr-lan expose), and the tunnel forwards
 * Pulzr Cloud opens for a while (lan-forward). Its own page since 23 Nov
 * 2026; both were cards under the LAN's clients.
 */
export default function Forwarding() {
  const lan = useLanStatus();
  if (lan.isLoading) return <Spinner label="Reading the LAN" />;
  if (lan.isError) return <ErrorState error={lan.error} onRetry={lan.refetch} />;
  const state = lan.data!;
  if (!state.configured) return <Notice tone="warning">No LAN configured on this gateway.</Notice>;
  const clients = state.clients ?? [];
  const nameOf = (ip: string) => clients.find((c) => c.ip === ip)?.hostname;
  return (
    <div className="fade-in">
      <Exposed state={state} clients={clients} nameOf={nameOf} />
      <Forwards forwards={state.forwards ?? []} nameOf={nameOf} />
    </div>
  );
}

const PROTOS = [
  { value: 'tcp', label: 'TCP' },
  { value: 'udp', label: 'UDP' },
] as const;

// Ports on the wired and WiFi uplinks, forwarded to a reserved client. The
// one notice is where they answer: nowhere with no uplink up, and only
// through the site's router when the uplink's address is a private one.
function Exposed({
  state, clients, nameOf,
}: {
  state: LanStatus;
  clients: LanClient[];
  nameOf: (ip: string) => string | null | undefined;
}) {
  const queryClient = useQueryClient();
  const reserved = clients.filter((c) => c.reserved);
  const [proto, setProto] = useState<LanExposed['proto']>('tcp');
  const [port, setPort] = useState('');
  const [ip, setIp] = useState(reserved[0]?.reserved ?? '');
  const [dport, setDport] = useState('');

  const save = useMutation({
    mutationFn: (body: { proto: string; port: number; ip?: string; dport?: number }) =>
      api.post('/lan/expose', body),
    onSuccess: (_, body) => {
      if (body.ip) { setPort(''); setDport(''); }
      queryClient.invalidateQueries({ queryKey: ['lan'] });
    },
  });

  const exposed = state.exposed ?? [];
  const on = state.exposedOn ?? [];
  const behind = on.filter((o) => isPrivate(o.address));
  const target = ip || reserved[0]?.reserved || '';

  return (
    <Section title="Exposed Ports" icon={Globe}>
      {exposed.length > 0 && on.length === 0 && (
        <Notice tone="warning">No wired or WiFi uplink is up. Exposed ports answer nowhere.</Notice>
      )}
      {exposed.length > 0 && behind.length > 0 && (
        <Notice tone="info">
          Behind another router at {behind.map((o) => o.address).join(', ')}. Forward these ports to it there.
        </Notice>
      )}
      {save.isError && <Notice tone="error">{(save.error as Error).message}</Notice>}

      <FactList>
        {exposed.map((e) => (
          <Fact
            key={`${e.proto}-${e.port}`}
            label={`${e.proto.toUpperCase()} ${e.port}`}
            value={
              <span className={styles.status}>
                <span className="mono">{[nameOf(e.ip), `${e.ip}:${e.dport}`].filter(Boolean).join(' ')}</span>
                <Button variant="danger" disabled={save.isPending}
                        onClick={() => save.mutate({ proto: e.proto, port: e.port })}>
                  Remove
                </Button>
              </span>
            }
          />
        ))}
      </FactList>

      {reserved.length === 0 ? (
        exposed.length === 0 && <Notice tone="info">No reserved clients.</Notice>
      ) : (
        <>
          <div className={styles.options}>
            <Segmented aria-label="Protocol" value={proto} options={[...PROTOS]} onChange={setProto} />
          </div>
          <div className={styles.form}>
            <TextField label="Port" mono inputMode="numeric" value={port} placeholder="8080"
                       onChange={(event) => setPort(event.target.value)} />
            <SelectField
              label="Client"
              value={target}
              onChange={setIp}
              options={reserved.map((c) => ({ value: c.reserved!, label: [c.hostname, c.reserved].filter(Boolean).join(' ') }))}
            />
            <TextField label="Client port" mono inputMode="numeric" value={dport} placeholder={port || '80'}
                       onChange={(event) => setDport(event.target.value)} />
          </div>
          <div className={styles.actions}>
            <Button
              variant="primary"
              loading={save.isPending}
              disabled={!Number(port) || !target}
              onClick={() => save.mutate({ proto, port: Number(port), ip: target, dport: Number(dport) || undefined })}
            >
              Expose
            </Button>
          </div>
        </>
      )}
    </Section>
  );
}

// RFC 1918 and the carrier-grade NAT range: an address a site router or a
// carrier hands out, which the internet cannot reach without a forward.
function isPrivate(address: string) {
  const [a, b] = address.split('.').map(Number);
  return a === 10 || (a === 172 && b >= 16 && b <= 31) || (a === 192 && b === 168) || (a === 100 && b >= 64 && b <= 127);
}

// Every forward is one the cloud opened over MQTT (lan-forward); the console
// has no way to open one, so "Pulzr Cloud" is always who.
function Forwards({ forwards, nameOf }: { forwards: LanForward[]; nameOf: (ip: string) => string | null | undefined }) {
  return (
    <Section title="Tunnel Forwards" icon={ArrowRightLeft}>
      <FactList>
        {forwards.length === 0 ? (
          <Fact label="Open" value="None" />
        ) : (
          forwards.map((f) => (
            <Fact
              key={f.port}
              label={`Port ${f.port}`}
              value={
                <span className={styles.status}>
                  <span className="mono">
                    {[nameOf(f.ip), `${f.ip}:${f.dport}`].filter(Boolean).join(' ')}
                  </span>
                  <span className={styles.dim}>Pulzr Cloud, closes in {duration(f.expiresIn)}</span>
                </span>
              }
            />
          ))
        )}
      </FactList>
    </Section>
  );
}
