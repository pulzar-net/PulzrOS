import { useMemo, useState } from 'react';
import { Link } from 'react-router-dom';
import { useQuery } from '@tanstack/react-query';
import {
  createColumnHelper,
  getCoreRowModel,
  getSortedRowModel,
  useReactTable,
  type SortingState,
} from '@tanstack/react-table';
import { EthernetPort, MonitorSmartphone, Wifi } from 'lucide-react';
import { api } from '@/services/api';
import type { LanStatus, Port, PortsStatus } from '@/types';
import type { RadiosStatus } from '@/pages/radios/model';
import Section from '@/components/ui/Section';
import Badge from '@/components/ui/Badge';
import DataTable from '@/components/DataTable';
import Spinner from '@/components/ui/Spinner';
import ErrorState from '@/components/ErrorState';
import { useFeatures } from '@/hooks/useFeatures';
import { duration, portLabel } from '@/lib/format';
import { linkSpeed } from '@/lib/uplinks';
import styles from '../Pages.module.css';

/**
 * The Network area's own page: every port, and every client on the
 * gateway's LAN and its access points, each the way into the page that
 * changes it (Ports, LAN, WiFi).
 *
 * Nothing here is a report of its own. The ports are pulzr-ports'; the
 * clients are pulzr-lan's (DHCP leases, the neighbor table and the bridge's
 * forwarding table) joined with each access point's station list from
 * /radios, which is what says a client is on WiFi and on which network: on
 * the LAN bridge a WiFi client is only behind the AP's interface. A station
 * on an AP that is not on the LAN (the setup network) has no lease here and
 * is listed by its MAC alone.
 */

interface ClientRow {
  mac: string;
  name: string | null;
  ip: string | null;
  /** The port's label, or the SSID. */
  where: string | null;
  wifi: boolean;
  signal: number | null;
  online: boolean;
  /** Unix seconds. */
  lastSeen: number | null;
}

interface PortRow {
  name: string;
  label: string;
  role: string;
  up: boolean;
  present: boolean;
  speed: number | null;
  clients: number;
}

const ROLES: Record<Port['role'], string> = { uplink: 'Uplink', devices: 'LAN', none: 'Unused' };

const clientColumn = createColumnHelper<ClientRow>();
const portColumn = createColumnHelper<PortRow>();

export default function Network() {
  const features = useFeatures();
  const ports = useQuery({
    queryKey: ['ports'],
    queryFn: () => api.get<PortsStatus>('/ports/status'),
    refetchInterval: 15_000,
  });
  const lan = useQuery({
    queryKey: ['lan'],
    queryFn: () => api.get<LanStatus>('/lan/status'),
    refetchInterval: 15_000,
    enabled: features.has('lan'),
  });
  const radios = useQuery({
    queryKey: ['radios'],
    queryFn: () => api.get<RadiosStatus>('/radios'),
    refetchInterval: 15_000,
    enabled: features.has('wifi'),
  });
  const [sorting, setSorting] = useState<SortingState>([{ id: 'seen', desc: true }]);

  const clients = useMemo(() => {
    const now = Math.floor(Date.now() / 1000);
    // Each AP interface's SSID, and its stations by MAC.
    const ssidOf = new Map<string, string>();
    const stations = new Map<string, { ssid: string; signal: number | null; seen: number }>();
    for (const radio of radios.data?.radios ?? []) {
      for (const iface of radio.interfaces) {
        if (iface.role !== 'ap' || !iface.ifname) continue;
        const ssid = iface.ssid ?? iface.ifname;
        ssidOf.set(iface.ifname, ssid);
        for (const c of iface.clients ?? []) {
          stations.set(c.mac.toLowerCase(), {
            ssid, signal: c.signal ?? null, seen: now - Math.floor((c.inactive ?? 0) / 1000),
          });
        }
      }
    }
    const rows = new Map<string, ClientRow>();
    for (const c of lan.data?.clients ?? []) {
      const mac = c.mac.toLowerCase();
      const station = stations.get(mac);
      const ssid = station?.ssid ?? (c.port ? ssidOf.get(c.port) : undefined);
      rows.set(mac, {
        mac,
        name: c.reserved ?? c.hostname,
        ip: c.ip,
        where: ssid ?? (c.port ? portLabel(c.port) : null),
        wifi: Boolean(ssid),
        signal: station?.signal ?? null,
        online: c.online || Boolean(station),
        lastSeen: Math.max(c.lastSeen ?? 0, station?.seen ?? 0) || null,
      });
    }
    for (const [mac, s] of stations) {
      if (rows.has(mac)) continue;
      rows.set(mac, { mac, name: null, ip: null, where: s.ssid, wifi: true, signal: s.signal, online: true, lastSeen: s.seen });
    }
    return [...rows.values()];
  }, [lan.data, radios.data]);

  const portRows = useMemo<PortRow[]>(() => (ports.data?.ports ?? []).map((p) => {
    const vlans = p.vlans.map((v) => `VLAN ${v.vid} ${ROLES[v.role].toLowerCase()}`);
    return {
      name: p.name,
      label: p.label,
      role: [p.role === 'none' && vlans.length ? null : ROLES[p.role], ...vlans].filter(Boolean).join(', '),
      up: p.link.up === true,
      present: p.link.present,
      speed: p.link.up ? (p.link.speed ?? null) : null,
      clients: (lan.data?.clients ?? []).filter((c) => c.port === p.name).length,
    };
  }), [ports.data, lan.data]);

  const clientColumns = useMemo(() => [
    clientColumn.accessor((c) => c.name ?? '', {
      id: 'name',
      header: 'Name',
      cell: (info) => info.getValue() || <span className={styles.dim}>—</span>,
    }),
    clientColumn.accessor('mac', {
      header: 'MAC',
      size: 150,
      cell: (info) => <span className="mono">{info.getValue()}</span>,
    }),
    clientColumn.accessor((c) => c.ip ?? '', {
      id: 'ip',
      header: 'Address',
      size: 130,
      cell: (info) => (info.getValue() ? <span className="mono">{info.getValue()}</span> : '—'),
    }),
    clientColumn.accessor((c) => c.where ?? '', {
      id: 'where',
      header: 'On',
      size: 230,
      cell: (info) => {
        const c = info.row.original;
        if (!c.where) return '—';
        return (
          <span className={styles.status}>
            {c.wifi ? <Wifi size={13} strokeWidth={2} /> : <EthernetPort size={13} strokeWidth={2} />}
            <span>{c.where}</span>
            {c.signal != null && <span className={styles.dim}>{c.signal} dBm</span>}
          </span>
        );
      },
    }),
    clientColumn.accessor((c) => (c.online ? Number.MAX_SAFE_INTEGER : (c.lastSeen ?? 0)), {
      id: 'seen',
      header: 'Seen',
      size: 100,
      cell: (info) => (info.row.original.online
        ? <Badge tone="success">Online</Badge>
        : info.row.original.lastSeen
          ? `${duration(Math.floor(Date.now() / 1000) - info.row.original.lastSeen)} ago`
          : '—'),
    }),
  ], []);

  const portColumns = useMemo(() => [
    portColumn.accessor('label', {
      header: 'Port',
      size: 140,
      cell: (info) => <Link to="/network/ports">{info.getValue()}</Link>,
    }),
    portColumn.accessor('role', { header: 'Role' }),
    portColumn.accessor((p) => (p.up ? 1 : 0), {
      id: 'link',
      header: 'Link',
      size: 110,
      cell: (info) => {
        const p = info.row.original;
        if (!p.present) return <Badge tone="neutral">Absent</Badge>;
        return p.up ? <Badge tone="success">Up</Badge> : <Badge tone="neutral">No cable</Badge>;
      },
    }),
    portColumn.accessor((p) => p.speed ?? 0, {
      id: 'speed',
      header: 'Speed',
      size: 100,
      cell: (info) => linkSpeed(info.row.original.speed) ?? '—',
    }),
    portColumn.accessor('clients', {
      header: 'Clients',
      size: 80,
      cell: (info) => info.getValue() || '—',
    }),
  ], []);

  const clientTable = useReactTable({
    data: clients,
    columns: clientColumns,
    state: { sorting },
    onSortingChange: setSorting,
    getRowId: (row) => row.mac,
    getCoreRowModel: getCoreRowModel(),
    getSortedRowModel: getSortedRowModel(),
  });
  const portTable = useReactTable({
    data: portRows,
    columns: portColumns,
    getRowId: (row) => row.name,
    getCoreRowModel: getCoreRowModel(),
  });

  if (ports.isLoading) return <Spinner label="Reading the ports" />;
  if (ports.isError) return <ErrorState error={ports.error} onRetry={ports.refetch} />;

  const showClients = features.has('lan') || features.has('wifi');

  return (
    <div className="fade-in">
      <Section title="Ports" icon={EthernetPort} wide>
        <DataTable table={portTable} fill="role" />
      </Section>
      {showClients && (
        <Section
          title="Clients"
          icon={MonitorSmartphone}
          wide
          note={clients.length ? `${clients.filter((c) => c.online).length} online` : undefined}
        >
          {lan.isError
            ? <ErrorState error={lan.error} onRetry={lan.refetch} />
            : clients.length
              ? <DataTable table={clientTable} fill="name" minWidth={640} />
              : <span className={styles.dim}>No clients yet.</span>}
        </Section>
      )}
    </div>
  );
}
