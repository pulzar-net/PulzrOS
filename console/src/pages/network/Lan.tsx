import { useMemo, useState } from 'react';
import { ArrowRightLeft, Cable, Globe, MonitorSmartphone } from 'lucide-react';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import {
  createColumnHelper,
  getCoreRowModel,
  getSortedRowModel,
  useReactTable,
  type SortingState,
} from '@tanstack/react-table';
import { api } from '@/services/api';
import type { LanClient, LanExposed, LanForward, LanStatus, LanTraffic } from '@/types';
import Section from '@/components/ui/Section';
import Badge from '@/components/ui/Badge';
import Button from '@/components/ui/Button';
import Dialog from '@/components/ui/Dialog';
import Notice from '@/components/ui/Notice';
import Segmented from '@/components/ui/Segmented';
import { SelectField, TextField } from '@/components/ui/Field';
import Fact, { FactList } from '@/components/Fact';
import DataTable from '@/components/DataTable';
import Spinner from '@/components/ui/Spinner';
import ErrorState from '@/components/ErrorState';
import { bytes, duration, portLabel } from '@/lib/format';
import styles from '../Pages.module.css';
import own from './Lan.module.css';

/**
 * The devlan zone: who is on the LAN ports, what each may reach, and which
 * tunnel forwards are open.
 *
 * Per MAC: the policy (parkeze or internet), the reservation and the cellular
 * rule. Tunnel forwards are listed and never opened here: they are net-api's
 * (lan-forward). Exposed ports are opened here, because they are the site's:
 * a port on the wired or WiFi uplink to a reserved client, never over the
 * tunnel or cellular (parkeze-lan). Everything set here is in parkeze-lan's
 * state, which is what parkeze.net's `lan` op reads.
 */

const POLICIES: { value: LanClient['policy']; label: string }[] = [
  // `parkeze` is the stored value from before the rename: Pulzr Net's own
  // servers (HTTPS and MQTT), NTP and the gateway's DNS, nothing else.
  { value: 'parkeze', label: 'Pulzr Net' },
  { value: 'internet', label: 'Internet' },
];

const total = (traffic: LanTraffic, only?: string) =>
  Object.entries(traffic)
    .filter(([uplink]) => !only || uplink === only)
    .reduce((sum, [, t]) => sum + t.txBytes + t.rxBytes, 0);

const column = createColumnHelper<LanClient>();

export default function Lan() {
  const queryClient = useQueryClient();
  const [sorting, setSorting] = useState<SortingState>([{ id: 'ip', desc: false }]);
  const [editing, setEditing] = useState<LanClient | null>(null);

  const lan = useQuery({
    queryKey: ['lan'],
    queryFn: () => api.get<LanStatus>('/lan/status'),
    refetchInterval: 15_000,
  });

  const policy = useMutation({
    mutationFn: (body: { mac: string; policy: string }) => api.post('/lan/policy', body),
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ['lan'] }),
  });
  // The mutation object is new on every render; its mutate and pending state
  // are what the cells use, and columns rebuilt each render remount every
  // open menu in the table.
  const setPolicy = policy.mutate;
  const policyPending = policy.isPending;

  const columns = useMemo(
    () => [
      // The fill column: a hostname is the one value here of no fixed width.
      column.accessor((c) => c.hostname ?? '', {
        id: 'name',
        header: 'Name',
        cell: (info) => <span className={own.name} title={info.getValue()}>{info.getValue() || '—'}</span>,
      }),
      column.accessor((c) => c.ip ?? '', {
        id: 'ip',
        header: 'Address',
        size: 190,
        sortingFn: (a, b) => ipOrder(a.original.ip) - ipOrder(b.original.ip),
        cell: (info) => (
          <>
            <span className="mono">{info.getValue() || '—'}</span>{' '}
            {info.row.original.reserved && <Badge tone="neutral">Reserved</Badge>}
          </>
        ),
      }),
      column.accessor('mac', {
        header: 'MAC',
        size: 140,
        cell: (info) => <span className="mono">{info.getValue()}</span>,
      }),
      column.accessor((c) => c.port ?? '', {
        id: 'port',
        header: 'Port',
        size: 72,
        cell: (info) => (info.getValue() ? portLabel(info.getValue()) : '—'),
      }),
      column.accessor('policy', {
        header: 'Policy',
        size: 190,
        enableSorting: false,
        cell: (info) => (
          <Segmented
            aria-label={`Policy for ${info.row.original.mac}`}
            value={info.getValue()}
            options={POLICIES}
            disabled={policyPending}
            onChange={(next) => setPolicy({ mac: info.row.original.mac, policy: next })}
          />
        ),
      }),
      column.accessor((c) => total(c.traffic), {
        id: 'traffic',
        header: 'Traffic',
        size: 82,
        meta: { numeric: true },
        cell: (info) => bytes(info.getValue()),
      }),
      // Both billed interfaces: the modem's, and a dongle's or a phone's.
      column.accessor((c) => total(c.traffic, 'wwan') + total(c.traffic, 'usbwan'), {
        id: 'cellular',
        header: 'Cellular',
        size: 82,
        meta: { numeric: true },
        cell: (info) => (
          <>
            {bytes(info.getValue())}{' '}
            {info.row.original.cellular === 'block'
              ? <Badge tone="neutral">Blocked</Badge>
              : (info.row.original.cellularBlock ?? []).length > 0 && <Badge tone="neutral">Limited</Badge>}
          </>
        ),
      }),
      // Online is a client answering ARP now; otherwise its last DHCP contact.
      column.accessor((c) => (c.online ? Number.MAX_SAFE_INTEGER : (c.lastSeen ?? 0)), {
        id: 'lastSeen',
        header: 'Seen',
        size: 100,
        cell: (info) =>
          info.row.original.online
            ? <Badge tone="success">Online</Badge>
            : info.getValue()
              ? `${duration(Math.floor(Date.now() / 1000) - info.getValue())} ago`
              : '—',
      }),
      column.display({
        id: 'reserve',
        header: '',
        size: 96,
        cell: (info) => (
          <Button onClick={() => setEditing(info.row.original)}>
            {info.row.original.reserved ? 'Edit' : 'Reserve'}
          </Button>
        ),
      }),
    ],
    [setPolicy, policyPending],
  );

  const table = useReactTable({
    data: lan.data?.clients ?? [],
    columns,
    state: { sorting },
    onSortingChange: setSorting,
    getRowId: (row) => row.mac,
    getCoreRowModel: getCoreRowModel(),
    getSortedRowModel: getSortedRowModel(),
  });

  if (lan.isLoading) return <Spinner label="Reading the LAN" />;
  if (lan.isError) return <ErrorState error={lan.error} onRetry={lan.refetch} />;

  const state = lan.data!;
  if (!state.configured) return <Notice tone="warning">No LAN configured on this gateway.</Notice>;

  const clients = state.clients ?? [];
  const links = state.links ?? (state.ports ?? []).map((name) => ({ name, up: false, speed: null }));
  const cellular = clients.reduce((sum, c) => sum + total(c.traffic, 'wwan') + total(c.traffic, 'usbwan'), 0);
  const nameOf = (ip: string) => clients.find((c) => c.ip === ip)?.hostname;

  return (
    <div className="fade-in">
      <Section title="LAN" icon={Cable}>
        <FactList>
          <Fact label="Gateway" value={state.address} mono />
          {links.map((link) => (
            <Fact
              key={link.name}
              label={portLabel(link.name)}
              value={
                <span className={styles.status}>
                  {link.up ? <Badge tone="success">Up</Badge> : <Badge tone="neutral">No link</Badge>}
                  {link.up && link.speed && <span>{link.speed >= 1000 ? `${link.speed / 1000} Gb/s` : `${link.speed} Mb/s`}</span>}
                  <span className={styles.dim}>
                    {clients
                      .filter((c) => c.port === link.name && c.online)
                      .map((c) => c.hostname ?? c.ip ?? c.mac)
                      .join(', ')}
                  </span>
                </span>
              }
            />
          ))}
          <Fact label="Over cellular" value={`${bytes(cellular)} since boot`} />
        </FactList>
      </Section>

      <Section title="Clients" icon={MonitorSmartphone} wide>
        {policy.isError && <Notice tone="error">{(policy.error as Error).message}</Notice>}
        <DataTable table={table} fill="name"
                   cellClassName={(id) => (id === 'reserve' ? own.reserve : own.cell)} />
      </Section>

      <Exposed state={state} clients={clients} nameOf={nameOf} />

      <Forwards forwards={state.forwards ?? []} nameOf={nameOf} />

      {editing && <ReserveDialog client={editing} onClose={() => setEditing(null)} />}
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
    <Section title="Exposed ports" icon={Globe}>
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

// Every forward is one net-api opened over MQTT (lan-forward); the console
// has no way to open one, so "Parkeze Net" is always who.
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
                  <span className={styles.dim}>Parkeze Net, closes in {duration(f.expiresIn)}</span>
                </span>
              }
            />
          ))
        )}
      </FactList>
    </Section>
  );
}

function ReserveDialog({ client, onClose }: { client: LanClient; onClose: () => void }) {
  const queryClient = useQueryClient();
  const [ip, setIp] = useState(client.reserved ?? client.ip ?? '');
  const [name, setName] = useState(client.hostname ?? '');

  const save = useMutation({
    mutationFn: (body: { mac: string; ip: string | null; name?: string }) => api.post('/lan/reserve', body),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['lan'] });
      onClose();
    },
  });

  return (
    <Dialog
      open
      size="compact"
      onClose={onClose}
      title={client.mac}
      footer={
        <div className={styles.row}>
          {client.reserved && (
            <Button
              variant="danger"
              loading={save.isPending}
              onClick={() => save.mutate({ mac: client.mac, ip: null })}
            >
              Release
            </Button>
          )}
          <Button
            variant="primary"
            loading={save.isPending}
            disabled={!ip.trim()}
            onClick={() =>
              save.mutate({ mac: client.mac, ip: ip.trim(), name: name.trim() || undefined })
            }
          >
            Reserve
          </Button>
        </div>
      }
    >
      {save.isError && <Notice tone="error">{(save.error as Error).message}</Notice>}
      <TextField label="Address" mono value={ip} onChange={(e) => setIp(e.target.value)} />
      <TextField label="Name" value={name} onChange={(e) => setName(e.target.value)} />
      <Cellular client={client} />
    </Dialog>
  );
}

const CELLULAR = [
  { value: 'allow', label: 'Cellular allowed' },
  { value: 'block', label: 'Cellular blocked' },
] as const;

// Whether this client may use cellular when it carries traffic, and which
// ports it may not use there: a camera's stream, say, while its alarms go out.
function Cellular({ client }: { client: LanClient }) {
  const queryClient = useQueryClient();
  const [mode, setMode] = useState<'allow' | 'block'>(client.cellular ?? 'allow');
  const [blocks, setBlocks] = useState((client.cellularBlock ?? []).join(', '));
  const list = blocks.split(/[\s,]+/).map((b) => b.trim().toLowerCase()).filter(Boolean);
  const changed = mode !== (client.cellular ?? 'allow')
    || (mode === 'allow' && list.join(',') !== (client.cellularBlock ?? []).join(','));

  const save = useMutation({
    mutationFn: () => api.post('/lan/cellular', { mac: client.mac, mode, blocks: mode === 'allow' ? list : [] }),
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ['lan'] }),
  });

  return (
    <>
      <div className={styles.options}>
        <Segmented aria-label={`Cellular for ${client.mac}`} value={mode} options={[...CELLULAR]} onChange={setMode} />
      </div>
      {mode === 'allow' && (
        <TextField label="Blocked on cellular" mono value={blocks} placeholder="tcp:554, udp:5000-5010"
                   onChange={(e) => setBlocks(e.target.value)} />
      )}
      {save.isError && <Notice tone="error">{(save.error as Error).message}</Notice>}
      <div className={styles.actions}>
        <Button loading={save.isPending} disabled={!changed} onClick={() => save.mutate()}>
          Apply cellular
        </Button>
      </div>
    </>
  );
}

function ipOrder(ip: string | null): number {
  if (!ip) return Number.MAX_SAFE_INTEGER;
  return ip.split('.').reduce((n, part) => n * 256 + Number(part), 0);
}
