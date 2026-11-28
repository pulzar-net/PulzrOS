import { useMemo, useState } from 'react';
import { EthernetPort, MonitorSmartphone, Wifi } from 'lucide-react';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import {
  createColumnHelper,
  getCoreRowModel,
  getSortedRowModel,
  useReactTable,
  type SortingState,
} from '@tanstack/react-table';
import { api } from '@/services/api';
import { useVendor } from '@/lib/oui';
import type { LanClient, LanStatus, LanTraffic, UplinksStatus } from '@/types';
import { BAND_NAMES, type RadiosStatus } from '@/pages/radios/model';
import Section from '@/components/ui/Section';
import Badge from '@/components/ui/Badge';
import Button from '@/components/ui/Button';
import Dialog from '@/components/ui/Dialog';
import Notice from '@/components/ui/Notice';
import Segmented from '@/components/ui/Segmented';
import { TextField } from '@/components/ui/Field';
import { useCellular } from '@/hooks/useCellular';
import DataTable from '@/components/DataTable';
import ErrorState from '@/components/ErrorState';
import { bytes, duration, portLabel } from '@/lib/format';
import styles from '../Pages.module.css';
import own from './Lan.module.css';

/**
 * Every client of the gateway, wired and WiFi, on the Network page: what it
 * is, where it is plugged in or which network it joined, and what it may
 * reach.
 *
 * The LAN's clients are pulzr-lan's (DHCP leases, the neighbor table, the
 * bridge's forwarding table and the addresses learned off ARP), each with
 * its policy (parkeze or internet), reservation and cellular rule. Joined
 * with each access point's station list from /radios, which is what says a
 * client is on WiFi and on which network: on the LAN bridge a WiFi client is
 * only behind the AP's interface. A station on an AP that is not on the LAN
 * (the setup network) has no lease here and is listed by its MAC alone.
 * Tunnels (Tunnels.tsx) and exposed ports (Forwarding.tsx) are pages of
 * their own. Everything set here is in pulzr-lan's state, which is what
 * Pulzr Cloud's `lan` op reads.
 */
const POLICIES: { value: LanClient['policy']; label: string }[] = [
  // Compat: `parkeze` is the policy value the cloud sends and reads; it stays.
  // It means Pulzr Cloud's own servers (HTTPS and MQTT), NTP and the
  // gateway's DNS, nothing else.
  { value: 'parkeze', label: 'Pulzr Cloud' },
  { value: 'internet', label: 'Internet' },
];

const total = (traffic: LanTraffic, only?: string) =>
  Object.entries(traffic)
    .filter(([uplink]) => !only || uplink === only)
    .reduce((sum, [, t]) => sum + t.txBytes + t.rxBytes, 0);

interface Row {
  mac: string;
  /** Null for a WiFi station the LAN has no record of. */
  client: LanClient | null;
  /** The port's label, or the SSID and band. */
  on: string | null;
  wifi: boolean;
  signal: number | null;
  online: boolean;
  /** Unix seconds. */
  lastSeen: number | null;
}

const column = createColumnHelper<Row>();

/** The MAC's registered organization, looked up only while the uplink in use
 * is not metered (lib/oui.ts). */
function VendorCell({ mac }: { mac: string }) {
  const uplinks = useQuery({
    queryKey: ['uplinks'],
    queryFn: () => api.get<UplinksStatus>('/uplinks/status'),
    staleTime: 30_000,
  });
  const active = uplinks.data?.uplinks.find((u) => u.iface === uplinks.data?.active);
  const vendor = useVendor(mac, active !== undefined && !active.metered);
  if (vendor === undefined || vendor === null) return <span className={styles.dim}>—</span>;
  if ('private' in vendor) return <span className={styles.dim}>Private</span>;
  return <span className={own.name} title={vendor.name}>{vendor.name}</span>;
}

// How long a client stays listed after the gateway last heard from it,
// unless it is configured: the same hour as Pulzr Cloud's Devices on LAN
// (net-api gateway_lan.ACTIVE_SECONDS).
const ACTIVE_SECONDS = 3600;

const SHOW = [
  { value: 'active', label: 'Active' },
  { value: 'all', label: 'All' },
] as const;

/** Heard from within the hour (online, on the bridge, learned from its ARP),
 *  or configured, which stays while off: reserved, or an exposed port's
 *  target. */
function listed(c: LanClient, exposed: Set<string>, now: number): boolean {
  if (c.online || c.port || c.learned) return true;
  if (c.lastSeen != null && now - c.lastSeen < ACTIVE_SECONDS) return true;
  return !!c.reserved || exposed.has(c.ip ?? '') || exposed.has(c.reserved ?? '');
}

/** pulzr-lan's state, which the LAN, Tunnels and Port Forwarding pages all
 *  read: one query, so a change on one is on the others. */
export function useLanStatus(enabled = true) {
  return useQuery({
    queryKey: ['lan'],
    queryFn: () => api.get<LanStatus>('/lan/status'),
    refetchInterval: 15_000,
    enabled,
  });
}

export default function Clients({ lan: hasLan, radios }: { lan: boolean; radios: RadiosStatus | undefined }) {
  const queryClient = useQueryClient();
  const [sorting, setSorting] = useState<SortingState>([{ id: 'seen', desc: true }]);
  const [editing, setEditing] = useState<LanClient | null>(null);
  const [show, setShow] = useState<'active' | 'all'>('active');
  // No modem, no cellular: its column, total and per-client rule stay off
  // screen (hooks/useCellular).
  const cellularShown = useCellular().shown;

  const lan = useLanStatus(hasLan);

  const policy = useMutation({
    mutationFn: (body: { mac: string; policy: string }) => api.post('/lan/policy', body),
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ['lan'] }),
  });
  // The mutation object is new on every render; its mutate and pending state
  // are what the cells use, and columns rebuilt each render remount every
  // open menu in the table.
  const setPolicy = policy.mutate;
  const policyPending = policy.isPending;

  const rows = useMemo<Row[]>(() => {
    const now = Math.floor(Date.now() / 1000);
    // Each AP interface's network and band, and its stations by MAC.
    const apOf = new Map<string, string>();
    const stations = new Map<string, { on: string; signal: number | null; seen: number }>();
    for (const radio of radios?.radios ?? []) {
      for (const iface of radio.interfaces) {
        if (iface.role !== 'ap' || !iface.ifname) continue;
        const on = `${iface.ssid ?? iface.ifname} · ${BAND_NAMES[radio.band] ?? radio.band}`;
        apOf.set(iface.ifname, on);
        for (const c of iface.clients ?? []) {
          stations.set(c.mac.toLowerCase(), {
            on, signal: c.signal ?? null, seen: now - Math.floor((c.inactive ?? 0) / 1000),
          });
        }
      }
    }
    const exposed = new Set((lan.data?.exposed ?? []).map((e) => e.ip));
    const out = new Map<string, Row>();
    for (const c of lan.data?.clients ?? []) {
      const mac = c.mac.toLowerCase();
      const station = stations.get(mac);
      if (show === 'active' && !station && !listed(c, exposed, now)) continue;
      const ap = station?.on ?? (c.port ? apOf.get(c.port) : undefined);
      out.set(mac, {
        mac,
        client: c,
        on: ap ?? (c.port ? portLabel(c.port) : null),
        wifi: Boolean(ap),
        signal: station?.signal ?? null,
        online: c.online || Boolean(station),
        lastSeen: Math.max(c.lastSeen ?? 0, station?.seen ?? 0) || null,
      });
    }
    for (const [mac, s] of stations) {
      if (!out.has(mac)) out.set(mac, { mac, client: null, on: s.on, wifi: true, signal: s.signal, online: true, lastSeen: s.seen });
    }
    return [...out.values()];
  }, [lan.data, radios, show]);

  const columns = useMemo(
    () => [
      // The fill column: a hostname is the one value here of no fixed width.
      // The name it leased with, else its maker: what a technician calls it.
      column.accessor((r) => r.client?.hostname ?? '', {
        id: 'name',
        header: 'Name',
        cell: (info) => info.getValue()
          ? <span className={own.name} title={info.getValue()}>{info.getValue()}</span>
          : <VendorCell mac={info.row.original.mac} />,
      }),
      column.accessor((r) => r.client?.ip ?? '', {
        id: 'ip',
        header: 'Address',
        size: 150,
        sortingFn: (a, b) => ipOrder(a.original.client?.ip ?? null) - ipOrder(b.original.client?.ip ?? null),
        cell: (info) => (
          <>
            <span className="mono">{info.getValue() || '—'}</span>{' '}
            {info.row.original.client?.reserved && <Badge tone="neutral">Reserved</Badge>}
          </>
        ),
      }),
      column.accessor('mac', {
        header: 'MAC',
        size: 136,
        cell: (info) => <span className="mono">{info.getValue()}</span>,
      }),
      column.accessor((r) => r.on ?? '', {
        id: 'on',
        header: 'On',
        size: 210,
        cell: (info) => {
          const r = info.row.original;
          if (!r.on) return <span className={styles.dim}>—</span>;
          return (
            <span className={own.on}>
              {r.wifi ? <Wifi size={13} strokeWidth={2} /> : <EthernetPort size={13} strokeWidth={2} />}
              <span className={own.name} title={r.on}>{r.on}</span>
              {r.signal != null && <span className={styles.dim}>{r.signal} dBm</span>}
            </span>
          );
        },
      }),
      column.accessor((r) => r.client?.policy ?? '', {
        id: 'policy',
        header: 'Policy',
        size: 156,
        enableSorting: false,
        cell: (info) => info.row.original.client ? (
          <Segmented
            size="small"
            aria-label={`Policy for ${info.row.original.mac}`}
            value={info.row.original.client.policy}
            options={POLICIES}
            disabled={policyPending}
            onChange={(next) => setPolicy({ mac: info.row.original.mac, policy: next })}
          />
        ) : <span className={styles.dim}>—</span>,
      }),
      column.accessor((r) => (r.client ? total(r.client.traffic) : 0), {
        id: 'traffic',
        header: 'Traffic',
        size: 84,
        meta: { numeric: true },
        cell: (info) => (info.row.original.client ? bytes(info.getValue()) : '—'),
      }),
      // Both billed interfaces: the modem's, and a dongle's or a phone's.
      column.accessor((r) => (r.client ? total(r.client.traffic, 'wwan') + total(r.client.traffic, 'usbwan') : 0), {
        id: 'cellular',
        header: 'Cellular',
        size: 84,
        meta: { numeric: true },
        cell: (info) => {
          const c = info.row.original.client;
          if (!c) return '—';
          return (
            <>
              {bytes(info.getValue())}{' '}
              {c.cellular === 'block'
                ? <Badge tone="neutral">Blocked</Badge>
                : (c.cellularBlock ?? []).length > 0 && <Badge tone="neutral">Limited</Badge>}
            </>
          );
        },
      }),
      // Online is a client answering ARP or associated now; otherwise its
      // last DHCP contact.
      column.accessor((r) => (r.online ? Number.MAX_SAFE_INTEGER : (r.lastSeen ?? 0)), {
        id: 'seen',
        header: 'Seen',
        size: 100,
        cell: (info) => {
          const r = info.row.original;
          if (r.online) return <Badge tone="success">Online</Badge>;
          if (r.lastSeen) return `${duration(Math.floor(Date.now() / 1000) - r.lastSeen)} ago`;
          // In the bridge's table and nowhere else: never asked for a lease,
          // and not on this subnet if it answers no ARP either.
          return (r.client?.port && !r.client.ip) || r.client?.learned ? <Badge tone="warning">No lease</Badge> : '—';
        },
      }),
      column.display({
        id: 'reserve',
        header: '',
        size: 76,
        cell: (info) => info.row.original.client && (
          <Button size="small" onClick={() => setEditing(info.row.original.client)}>
            {info.row.original.client.reserved ? 'Edit' : 'Reserve'}
          </Button>
        ),
      }),
    ],
    [setPolicy, policyPending],
  );

  const table = useReactTable({
    data: rows,
    columns,
    // Without the LAN there is nothing to set on a client.
    state: { sorting, columnVisibility: { cellular: cellularShown && hasLan, policy: hasLan, traffic: hasLan, reserve: hasLan } },
    onSortingChange: setSorting,
    getRowId: (row) => row.mac,
    getCoreRowModel: getCoreRowModel(),
    getSortedRowModel: getSortedRowModel(),
  });

  const clients = lan.data?.clients ?? [];
  const cellular = clients.reduce((sum, c) => sum + total(c.traffic, 'wwan') + total(c.traffic, 'usbwan'), 0);
  const online = rows.filter((r) => r.online).length;

  return (
    <Section
      title="Clients"
      icon={MonitorSmartphone}
      wide
      note={[`${online} online`, cellularShown && hasLan && cellular ? `${bytes(cellular)} over cellular` : null]
        .filter(Boolean).join(' · ')}
      actions={hasLan && <Segmented aria-label="Clients shown" value={show} options={[...SHOW]} onChange={setShow} />}
    >
      {lan.isError && <ErrorState error={lan.error} onRetry={lan.refetch} />}
      {policy.isError && <Notice tone="error">{(policy.error as Error).message}</Notice>}
      {/* The fixed columns and room for a name: narrower scrolls. */}
      <DataTable table={table} fill="name" minWidth={cellularShown && hasLan ? 1140 : 1060}
                 cellClassName={(id) => (id === 'reserve' ? own.reserve : own.cell)} />
      {editing && <ReserveDialog client={editing} cellular={cellularShown} onClose={() => setEditing(null)} />}
    </Section>
  );
}

function ReserveDialog({ client, cellular, onClose }: { client: LanClient; cellular: boolean; onClose: () => void }) {
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
      {cellular && <Cellular client={client} />}
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

export function ipOrder(ip: string | null): number {
  if (!ip) return Number.MAX_SAFE_INTEGER;
  return ip.split('.').reduce((n, part) => n * 256 + Number(part), 0);
}
