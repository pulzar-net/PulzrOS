import { useMemo, useState } from 'react';
import { ArrowRightLeft, Cable, Check, Copy, Globe, MonitorSmartphone, Waypoints } from 'lucide-react';
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
import type { LanClient, LanExposed, LanForward, LanStatus, LanTraffic, LanTunnel, UplinksStatus } from '@/types';
import Section from '@/components/ui/Section';
import Badge from '@/components/ui/Badge';
import Button from '@/components/ui/Button';
import Dialog from '@/components/ui/Dialog';
import Notice from '@/components/ui/Notice';
import Segmented from '@/components/ui/Segmented';
import { CheckboxField, SelectField, TextField } from '@/components/ui/Field';
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
 * rule. Tunnel forwards are listed and never opened here: they are the cloud's
 * (lan-forward). Exposed ports are opened here, because they are the site's:
 * a port on the wired or WiFi uplink to a reserved client, never over the
 * tunnel or cellular (pulzr-lan). So are tunnels out to a customer's own
 * servers: what each server reaches, and whether the LAN's internet goes
 * through it. Everything set here is in pulzr-lan's state, which is what
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

const column = createColumnHelper<LanClient>();

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

export default function Lan() {
  const queryClient = useQueryClient();
  const [sorting, setSorting] = useState<SortingState>([{ id: 'ip', desc: false }]);
  const [editing, setEditing] = useState<LanClient | null>(null);
  const [show, setShow] = useState<'active' | 'all'>('active');

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
      column.display({
        id: 'vendor',
        header: 'Vendor',
        size: 170,
        cell: (info) => <VendorCell mac={info.row.original.mac} />,
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
              // In the bridge's table and nowhere else: never asked for a
              // lease, and not on this subnet if it answers no ARP either.
              : (info.row.original.port && !info.row.original.ip) || info.row.original.learned
                ? <Badge tone="warning">No lease</Badge>
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

  const exposedIps = new Set((lan.data?.exposed ?? []).map((e) => e.ip));
  const now = Math.floor(Date.now() / 1000);
  const shown = (lan.data?.clients ?? []).filter((c) => show === 'all' || listed(c, exposedIps, now));

  const table = useReactTable({
    data: shown,
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
          <Fact label="Gateway" value={[state.address, ...(state.addresses ?? [])].join(', ')} mono />
          {links.map((link) => (
            <Fact
              key={link.name}
              label={portLabel(link.name)}
              value={
                <span className={styles.status}>
                  {link.up ? <Badge tone="success">Up</Badge> : <Badge tone="neutral">No link</Badge>}
                  {link.up && link.speed && (
                    <span title={link.carrierChanges != null ? `${link.carrierChanges} link changes since boot` : undefined}>
                      {link.speed >= 1000 ? `${link.speed / 1000} Gb/s` : `${link.speed} Mb/s`}
                      {link.duplex === 'half' && ' half duplex'}
                    </span>
                  )}
                  <span className={styles.dim}>
                    {shown
                      .filter((c) => c.port === link.name)
                      .map((c) => c.hostname ?? c.ip ?? c.mac)
                      .join(', ')}
                  </span>
                </span>
              }
            />
          ))}
          <Fact label="Over cellular" value={bytes(cellular)} />
        </FactList>
      </Section>

      <Section title="Clients" icon={MonitorSmartphone} wide
               actions={<Segmented aria-label="Clients shown" value={show} options={[...SHOW]} onChange={setShow} />}>
        {policy.isError && <Notice tone="error">{(policy.error as Error).message}</Notice>}
        <DataTable table={table} fill="name"
                   cellClassName={(id) => (id === 'reserve' ? own.reserve : own.cell)} />
      </Section>

      <Exposed state={state} clients={clients} nameOf={nameOf} />

      <Tunnels state={state} clients={clients} />

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

const SWITCH = [
  { value: 'off', label: 'Off' },
  { value: 'on', label: 'On' },
] as const;

const REACH = [
  { value: 'none', label: 'None' },
  { value: 'lan', label: 'Whole LAN' },
  { value: 'devices', label: 'Devices' },
] as const;

// WireGuard handshakes every two minutes while the keepalive runs; three
// without one is a tunnel that is down.
const HANDSHAKE_FRESH = 180;

type TunnelChange = { name: string } & Partial<{
  remove: boolean; internet: boolean; reach: LanTunnel['reach']; devices: string[];
  endpoint: string; publicKey: string; address: string;
}>;

// Tunnels the gateway dials out to a customer's servers (pulzr-lan tunnel).
function Tunnels({ state, clients }: { state: LanStatus; clients: LanClient[] }) {
  const queryClient = useQueryClient();
  const tunnels = state.tunnels ?? [];
  const [name, setName] = useState('');
  const [endpoint, setEndpoint] = useState('');
  const [key, setKey] = useState('');
  const [address, setAddress] = useState('');

  const save = useMutation({
    mutationFn: (body: TunnelChange) => api.post('/lan/tunnel', body),
    onSuccess: (_, body) => {
      if (body.endpoint) { setName(''); setEndpoint(''); setKey(''); setAddress(''); }
      queryClient.invalidateQueries({ queryKey: ['lan'] });
    },
  });

  // A device the server may be given keeps its address: reserved, or on
  // another subnet of the bridge, where nothing is leased (pulzr-lan pinned).
  const subnets = (state.addresses ?? []).map(subnetOf);
  const pinned = clients.filter((c) => c.reserved || (c.ip && subnets.some((n) => inSubnet(c.ip!, n))));
  const exists = tunnels.some((t) => t.name === name.trim());

  return (
    <Section title="Tunnels" icon={Waypoints}>
      {save.isError && <Notice tone="error">{(save.error as Error).message}</Notice>}
      {tunnels.map((t, i) => (
        <div key={t.name}>
          {i > 0 && <div className={styles.divider} />}
          <TunnelFacts
            tunnel={t}
            pinned={pinned}
            pending={save.isPending}
            change={(body) => save.mutate({ name: t.name, ...body })}
            edit={() => { setName(t.name); setEndpoint(t.endpoint ?? ''); setKey(t.serverKey ?? ''); setAddress(t.address ?? ''); }}
          />
        </div>
      ))}
      {tunnels.length > 0 && <div className={styles.divider} />}
      <div className={styles.form}>
        <TextField label="Name" mono value={name} placeholder="campo" onChange={(e) => setName(e.target.value)} />
        <TextField label="Server endpoint" mono value={endpoint} placeholder="203.0.113.10:51820"
                   onChange={(e) => setEndpoint(e.target.value)} />
        <TextField label="Server public key" mono value={key} onChange={(e) => setKey(e.target.value)} />
        <TextField label="Address" mono value={address} placeholder="10.77.0.2/30"
                   onChange={(e) => setAddress(e.target.value)} />
      </div>
      <div className={styles.actions}>
        <Button
          variant="primary"
          loading={save.isPending}
          disabled={!name.trim() || !endpoint.trim() || !key.trim()}
          onClick={() => save.mutate({ name: name.trim(), endpoint: endpoint.trim(), publicKey: key.trim(),
                                       address: address.trim() || undefined })}
        >
          {exists ? 'Save tunnel' : 'Add tunnel'}
        </Button>
      </div>
    </Section>
  );
}

function TunnelFacts({
  tunnel: t, pinned, pending, change, edit,
}: {
  tunnel: LanTunnel;
  pinned: LanClient[];
  pending: boolean;
  change: (body: Omit<TunnelChange, 'name'>) => void;
  edit: () => void;
}) {
  // Devices chosen with none ticked yet is a choice the gateway has not
  // heard: it reaches nothing until the first.
  const [mode, setMode] = useState<LanTunnel['reach']>(t.reach);
  const [copied, setCopied] = useState(false);
  const now = Math.floor(Date.now() / 1000);
  const fresh = t.latestHandshake != null && now - t.latestHandshake < HANDSHAKE_FRESH;
  const shown = mode === 'devices' && t.reach === 'none' ? 'devices' : t.reach;
  const options = [
    ...pinned.map((c) => ({ ip: (c.reserved ?? c.ip)!, label: [c.hostname, c.reserved ?? c.ip].filter(Boolean).join(' ') })),
    ...t.devices.filter((ip) => !pinned.some((c) => (c.reserved ?? c.ip) === ip)).map((ip) => ({ ip, label: ip })),
  ];

  const toggle = (ip: string, on: boolean) => {
    const devices = on ? [...t.devices, ip] : t.devices.filter((d) => d !== ip);
    change(devices.length ? { reach: 'devices', devices } : { reach: 'none' });
  };

  return (
    <>
      <FactList>
        <Fact
          label="Tunnel"
          value={
            <span className={styles.status}>
              <span className="mono">{t.name}</span>
              {fresh ? <Badge tone="success">Connected</Badge> : <Badge tone="warning">Not connected</Badge>}
              {!fresh && t.latestHandshake != null && (
                <span className={styles.dim}>Last handshake {duration(now - t.latestHandshake)} ago</span>
              )}
              <Button onClick={edit}>Edit</Button>
              <Button variant="danger" disabled={pending} onClick={() => change({ remove: true })}>Remove</Button>
            </span>
          }
        />
        <Fact label="Server" value={t.endpoint} mono />
        <Fact
          label="Public key"
          value={
            t.publicKey && (
              <span className={styles.status}>
                <span className="mono">{t.publicKey}</span>
                {navigator.clipboard && (
                  <Button onClick={() => void navigator.clipboard.writeText(t.publicKey!).then(() => setCopied(true))}>
                    {copied ? <Check size={14} strokeWidth={2} /> : <Copy size={14} strokeWidth={2} />}
                    {copied ? 'Copied' : 'Copy'}
                  </Button>
                )}
              </span>
            )
          }
        />
        <Fact label="Address" value={t.address} mono />
        <Fact label="Traffic" value={`${bytes(t.rxBytes)} in, ${bytes(t.txBytes)} out`} />
        <Fact
          label="Internet"
          value={
            <Segmented aria-label={`Internet through ${t.name}`} value={t.internet ? 'on' : 'off'}
                       options={[...SWITCH]} disabled={pending}
                       onChange={(next) => change({ internet: next === 'on' })} />
          }
        />
        <Fact
          label="Reaches"
          value={
            <Segmented aria-label={`What ${t.name} reaches`} value={shown} options={[...REACH]} disabled={pending}
                       onChange={(next) => { setMode(next); if (next !== 'devices') change({ reach: next }); }} />
          }
        />
      </FactList>
      {shown === 'devices' && (
        options.length === 0
          ? <Notice tone="info">No reserved clients.</Notice>
          : options.map((o) => (
              <CheckboxField key={o.ip} label={o.label} disabled={pending} checked={t.devices.includes(o.ip)}
                             onChange={(e) => toggle(o.ip, e.target.checked)} />
            ))
      )}
    </>
  );
}

// "10.0.0.2/24" as a network and mask.
function subnetOf(cidr: string) {
  const [ip, bits] = cidr.split('/');
  const mask = Number(bits) === 0 ? 0 : (~0 << (32 - Number(bits))) >>> 0;
  return { net: (ipOrder(ip) & mask) >>> 0, mask };
}

function inSubnet(ip: string, n: { net: number; mask: number }) {
  return ((ipOrder(ip) & n.mask) >>> 0) === n.net;
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
