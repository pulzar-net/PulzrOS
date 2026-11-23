import { useMemo, useState } from 'react';
import { useNavigate } from 'react-router-dom';
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
import type { LanStatus, PortsStatus } from '@/types';
import { BAND_NAMES, ROLE_NAMES as RADIO_ROLES, channelText, securityLabel, type RadiosStatus } from '@/pages/radios/model';
import Section from '@/components/ui/Section';
import Badge from '@/components/ui/Badge';
import DataTable from '@/components/DataTable';
import Spinner from '@/components/ui/Spinner';
import ErrorState from '@/components/ErrorState';
import { useFeatures } from '@/hooks/useFeatures';
import { duration, portLabel } from '@/lib/format';
import PortStrip from './PortStrip';
import SetupAccessPoint from './SetupAccessPoint';
import styles from '../Pages.module.css';

/**
 * The Network area's own page: every port, what each WiFi radio runs, and
 * every client on the gateway's LAN and its access points, each the way into
 * the page that changes it (Ports, WiFi, LAN).
 *
 * Nothing here is a report of its own. The ports are pulzr-ports'; the
 * clients are pulzr-lan's (DHCP leases, the neighbor table and the bridge's
 * forwarding table) joined with each access point's station list from
 * /radios, which is what says a client is on WiFi and on which network: on
 * the LAN bridge a WiFi client is only behind the AP's interface. A station
 * on an AP that is not on the LAN (the setup network) has no lease here and
 * is listed by its MAC alone. Services are the LAN port scan's (pulzr-lan):
 * what answered among a camera's and a router's usual ports.
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
  /** Open ports at the last scan; undefined before one reached it. */
  services?: number[];
}

const SERVICES: Record<number, string> = { 22: 'SSH', 23: 'Telnet', 80: 'HTTP', 8080: 'HTTP', 443: 'HTTPS', 8443: 'HTTPS' };

/** One thing a radio runs: the uplink, an access point; or the radio, off. */
interface WifiRow {
  id: string;
  band: string;
  role: string | null;
  ssid: string | null;
  security: string | null;
  channel: string | null;
  /** An access point's stations. */
  clients: number | null;
  /** The uplink's signal. */
  signal: number | null;
  up: boolean;
  off: boolean;
}

const clientColumn = createColumnHelper<ClientRow>();
const wifiColumn = createColumnHelper<WifiRow>();

export default function Network() {
  const features = useFeatures();
  const navigate = useNavigate();
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
        name: c.hostname,
        ip: c.ip,
        where: ssid ?? (c.port ? portLabel(c.port) : null),
        wifi: Boolean(ssid),
        signal: station?.signal ?? null,
        online: c.online || Boolean(station),
        lastSeen: Math.max(c.lastSeen ?? 0, station?.seen ?? 0) || null,
        services: c.services,
      });
    }
    for (const [mac, s] of stations) {
      if (rows.has(mac)) continue;
      rows.set(mac, { mac, name: null, ip: null, where: s.ssid, wifi: true, signal: s.signal, online: true, lastSeen: s.seen });
    }
    return [...rows.values()];
  }, [lan.data, radios.data]);

  // Each radio's interfaces, one row each; a radio running nothing is one
  // row saying so.
  const wifiRows = useMemo<WifiRow[]>(() => (radios.data?.radios ?? []).flatMap((radio): WifiRow[] => {
    const band = BAND_NAMES[radio.band] ?? radio.band;
    const live = radio.interfaces.filter((i) => i.enabled);
    if (!radio.enabled || !live.length) {
      return [{ id: radio.id, band, role: null, ssid: null, security: null, channel: null, clients: null, signal: null, up: false, off: true }];
    }
    return live.map((i) => ({
      id: `${radio.id}.${i.id}`, band, role: RADIO_ROLES[i.role], ssid: i.ssid ?? i.meshId,
      security: i.security ? securityLabel(i.security) : null, channel: channelText(radio),
      clients: i.role === 'ap' ? (i.clients?.length ?? 0) : null,
      signal: i.role === 'uplink' || i.role === 'client' ? i.signal : null,
      up: i.up, off: false,
    }));
  }), [radios.data]);

  const wifiColumns = useMemo(() => [
    wifiColumn.accessor('band', { header: 'Radio', size: 90 }),
    wifiColumn.accessor((w) => w.role ?? '', {
      id: 'role', header: 'Role', size: 120,
      cell: (info) => info.row.original.off ? <span className={styles.dim}>Off</span> : info.getValue(),
    }),
    wifiColumn.accessor((w) => w.ssid ?? '', {
      id: 'ssid', header: 'Network',
      cell: (info) => info.getValue() || <span className={styles.dim}>—</span>,
    }),
    wifiColumn.accessor((w) => w.security ?? '', {
      id: 'security', header: 'Security', size: 100,
      cell: (info) => info.getValue() || <span className={styles.dim}>—</span>,
    }),
    wifiColumn.accessor((w) => w.channel ?? '', {
      id: 'channel', header: 'Channel', size: 80,
      cell: (info) => info.getValue() || <span className={styles.dim}>—</span>,
    }),
    wifiColumn.display({
      id: 'detail', header: 'Clients / Signal', size: 130,
      cell: ({ row: { original: w } }) => w.clients != null ? w.clients
        : w.signal != null ? `${w.signal} dBm` : <span className={styles.dim}>—</span>,
    }),
    wifiColumn.display({
      id: 'state', header: 'State', size: 90,
      cell: ({ row: { original: w } }) => w.off ? <Badge tone="neutral">Off</Badge>
        : w.up ? <Badge tone="success">Up</Badge> : <Badge tone="warning">Down</Badge>,
    }),
  ], []);

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
      size: 200,
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
    clientColumn.accessor((c) => c.services?.length ?? -1, {
      id: 'services',
      header: 'Services',
      size: 150,
      cell: (info) => {
        const open = info.row.original.services;
        // Absent is a client no scan has reached yet: unknown, not closed.
        if (!open) return <span className={styles.dim}>—</span>;
        if (!open.length) return <span className={styles.dim}>None</span>;
        // The usual port reads as its name; 8080 and 8443 say which.
        return open.map((port) => (port === 8080 || port === 8443 ? `${SERVICES[port]} ${port}` : SERVICES[port] ?? `${port}`))
          .join(', ');
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

  const wifiTable = useReactTable({
    data: wifiRows,
    columns: wifiColumns,
    getRowId: (row) => row.id,
    getCoreRowModel: getCoreRowModel(),
  });
  const clientTable = useReactTable({
    data: clients,
    columns: clientColumns,
    state: { sorting },
    onSortingChange: setSorting,
    getRowId: (row) => row.mac,
    getCoreRowModel: getCoreRowModel(),
    getSortedRowModel: getSortedRowModel(),
  });
  if (ports.isLoading) return <Spinner label="Reading the ports" />;
  if (ports.isError) return <ErrorState error={ports.error} onRetry={ports.refetch} />;

  const showClients = features.has('lan') || features.has('wifi');

  return (
    <div className="fade-in">
      <Section title="Ports" icon={EthernetPort} wide>
        <PortStrip ports={ports.data!.ports} onSelect={(name) => navigate(`/network/ports?port=${encodeURIComponent(name)}`)} />
      </Section>
      {features.has('wifi') && wifiRows.length > 0 && (
        <Section title="WiFi" icon={Wifi} wide>
          <DataTable table={wifiTable} fill="ssid" onRowClick={() => navigate('/network/wifi')} />
        </Section>
      )}
      {features.has('wifi') && <SetupAccessPoint />}
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
              // The fixed columns and room for a name: narrower scrolls.
              ? <DataTable table={clientTable} fill="name" minWidth={880} />
              : <span className={styles.dim}>No clients yet.</span>}
        </Section>
      )}
    </div>
  );
}
