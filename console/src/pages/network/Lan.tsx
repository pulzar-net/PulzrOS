import { useMemo, useState } from 'react';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import {
  createColumnHelper,
  getCoreRowModel,
  getSortedRowModel,
  useReactTable,
  type SortingState,
} from '@tanstack/react-table';
import { api } from '@/services/api';
import type { LanClient, LanForward, LanStatus, LanTraffic } from '@/types';
import Section from '@/components/ui/Section';
import Badge from '@/components/ui/Badge';
import Button from '@/components/ui/Button';
import Dialog from '@/components/ui/Dialog';
import Notice from '@/components/ui/Notice';
import Select from '@/components/ui/Select';
import { TextField } from '@/components/ui/Field';
import Fact, { FactList } from '@/components/Fact';
import DataTable from '@/components/DataTable';
import Spinner from '@/components/ui/Spinner';
import ErrorState from '@/components/ErrorState';
import { bytes, duration } from '@/lib/format';
import styles from '../Pages.module.css';

/**
 * The devlan zone: who is on the LAN ports, what each may reach, and which
 * tunnel forwards are open.
 *
 * Two things change here, both per MAC: the policy (parkeze or internet) and
 * the reservation. Forwards are listed and never opened: the only way into
 * the LAN is the one net-api asks for (lan-forward), so a button for it here
 * would be a second. Everything set here is in parkeze-lan's state, which is
 * what parkeze.net's `lan` op reads.
 */

const POLICIES = [
  { value: 'parkeze' as const, label: 'Parkeze' },
  { value: 'internet' as const, label: 'Internet' },
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
      column.accessor((c) => c.hostname ?? '', {
        id: 'name',
        header: 'Name',
        size: 140,
        cell: (info) => info.getValue() || '—',
      }),
      column.accessor((c) => c.ip ?? '', {
        id: 'ip',
        header: 'Address',
        size: 210,
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
        size: 150,
        cell: (info) => <span className="mono">{info.getValue()}</span>,
      }),
      column.accessor('policy', {
        header: 'Policy',
        size: 140,
        enableSorting: false,
        cell: (info) => (
          <Select
            inline
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
        size: 90,
        meta: { numeric: true },
        cell: (info) => bytes(info.getValue()),
      }),
      // Both billed interfaces: the modem's, and a dongle's or a phone's.
      column.accessor((c) => total(c.traffic, 'wwan') + total(c.traffic, 'usbwan'), {
        id: 'cellular',
        header: 'Cellular',
        size: 90,
        meta: { numeric: true },
        cell: (info) => bytes(info.getValue()),
      }),
      // Online is a client answering ARP now; otherwise its last DHCP contact.
      column.accessor((c) => (c.online ? Number.MAX_SAFE_INTEGER : (c.lastSeen ?? 0)), {
        id: 'lastSeen',
        header: 'Seen',
        size: 110,
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
  const online = clients.filter((c) => c.online).length;

  return (
    <div className="fade-in">
      <Section title="LAN">
        <FactList>
          <Fact label="Gateway" value={state.address} mono />
          <Fact label="Ports" value={(state.ports ?? []).join(', ')} mono />
          <Fact label="Clients" value={`${online} online, ${clients.length} known`} />
        </FactList>
      </Section>

      <Section title="Clients" note={clients.length ? String(clients.length) : undefined}>
        {policy.isError && <Notice tone="error">{(policy.error as Error).message}</Notice>}
        <DataTable table={table} fill="reserve" />
      </Section>

      <Forwards forwards={state.forwards ?? []} />

      {editing && <ReserveDialog client={editing} onClose={() => setEditing(null)} />}
    </div>
  );
}

function Forwards({ forwards }: { forwards: LanForward[] }) {
  return (
    <Section title="Tunnel forwards" note={forwards.length ? String(forwards.length) : undefined}>
      {forwards.length === 0 ? (
        <FactList>
          <Fact label="Open" value="None" />
        </FactList>
      ) : (
        <FactList>
          {forwards.map((f) => (
            <Fact
              key={f.port}
              label={`Port ${f.port}`}
              value={`${f.ip}:${f.dport}, closes in ${duration(f.expiresIn)}`}
              mono
            />
          ))}
        </FactList>
      )}
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
    </Dialog>
  );
}

function ipOrder(ip: string | null): number {
  if (!ip) return Number.MAX_SAFE_INTEGER;
  return ip.split('.').reduce((n, part) => n * 256 + Number(part), 0);
}
