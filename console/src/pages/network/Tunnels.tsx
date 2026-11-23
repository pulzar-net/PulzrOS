import { useState, type ReactNode } from 'react';
import { Check, Copy, Plus, Waypoints } from 'lucide-react';
import { useMutation, useQueryClient } from '@tanstack/react-query';
import { createColumnHelper, getCoreRowModel, useReactTable } from '@tanstack/react-table';
import { api } from '@/services/api';
import type { LanClient, LanStatus, LanTunnel } from '@/types';
import Section from '@/components/ui/Section';
import Badge from '@/components/ui/Badge';
import Button from '@/components/ui/Button';
import Dialog from '@/components/ui/Dialog';
import Notice from '@/components/ui/Notice';
import Segmented from '@/components/ui/Segmented';
import { TextField } from '@/components/ui/Field';
import Fact, { FactList } from '@/components/Fact';
import DataTable from '@/components/DataTable';
import Spinner from '@/components/ui/Spinner';
import ErrorState from '@/components/ErrorState';
import { bytes, duration, portLabel } from '@/lib/format';
import { ipOrder, useLanStatus } from './Lan';
import styles from '../Pages.module.css';
import own from './Lan.module.css';

/**
 * Network > Tunnels: WireGuard tunnels the gateway dials out to a customer's
 * own servers (pulzr-lan tunnel), what each server reaches on the LAN, and
 * whether the LAN's internet goes through it. Its own page since 23 Nov 2026;
 * it was a card under the LAN's clients.
 */
export default function Tunnels() {
  const lan = useLanStatus();
  if (lan.isLoading) return <Spinner label="Reading the LAN" />;
  if (lan.isError) return <ErrorState error={lan.error} onRetry={lan.refetch} />;
  const state = lan.data!;
  if (!state.configured) return <Notice tone="warning">No LAN configured on this gateway.</Notice>;
  return (
    <div className="fade-in">
      <TunnelList state={state} clients={state.clients ?? []} />
    </div>
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

const postTunnel = (body: TunnelChange) => api.post('/lan/tunnel', body);

// A device the server may be given keeps its address: reserved, or on
// another subnet of the bridge, where nothing is leased (pulzr-lan pinned).
function pinnedClients(state: LanStatus, clients: LanClient[]) {
  const subnets = (state.addresses ?? []).map(subnetOf);
  return clients.filter((c) => c.reserved || (c.ip && subnets.some((n) => inSubnet(c.ip!, n))));
}

// Tunnels the gateway dials out to a customer's servers (pulzr-lan tunnel).
function TunnelList({ state, clients }: { state: LanStatus; clients: LanClient[] }) {
  const queryClient = useQueryClient();
  const tunnels = state.tunnels ?? [];
  const [wizard, setWizard] = useState<string | 'new' | null>(null);
  const pinned = pinnedClients(state, clients);

  const save = useMutation({
    mutationFn: postTunnel,
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ['lan'] }),
  });

  return (
    <Section title="Tunnels" icon={Waypoints} wide
             actions={<Button onClick={() => setWizard('new')}><Plus size={13} strokeWidth={2} />Add Tunnel</Button>}>
      {save.isError && <Notice tone="error">{(save.error as Error).message}</Notice>}
      {tunnels.length === 0 && <Notice tone="info">No tunnels.</Notice>}
      {tunnels.map((t, i) => (
        <div key={t.name}>
          {i > 0 && <div className={styles.divider} />}
          <TunnelFacts
            tunnel={t}
            pinned={pinned}
            pending={save.isPending}
            change={(body) => save.mutate({ name: t.name, ...body })}
            edit={() => setWizard(t.name)}
          />
        </div>
      ))}
      {wizard && (
        <TunnelWizard
          editing={wizard === 'new' ? null : tunnels.find((t) => t.name === wizard) ?? null}
          tunnels={tunnels}
          pinned={pinned}
          onClose={() => setWizard(null)}
        />
      )}
    </Section>
  );
}

type WizardStep = 'server' | 'access' | 'key';
const WIZARD_STEPS: WizardStep[] = ['server', 'access', 'key'];

// Adding a tunnel one question at a time: the server, what it reaches, and
// the gateway's key to give the server. The key exists only once the tunnel
// does, so the first step creates it.
function TunnelWizard({
  editing, tunnels, pinned, onClose,
}: {
  editing: LanTunnel | null;
  tunnels: LanTunnel[];
  pinned: LanClient[];
  onClose: () => void;
}) {
  const queryClient = useQueryClient();
  const [step, setStep] = useState<WizardStep>('server');
  const [name, setName] = useState(editing?.name ?? '');
  const [endpoint, setEndpoint] = useState(editing?.endpoint ?? '');
  const [key, setKey] = useState(editing?.serverKey ?? '');
  const [address, setAddress] = useState(editing?.address ?? '');
  const [reach, setReach] = useState<LanTunnel['reach']>(editing?.reach ?? 'none');
  const [devices, setDevices] = useState<string[]>(editing?.devices ?? []);
  const [internet, setInternet] = useState(editing?.internet ?? false);

  const live = tunnels.find((t) => t.name === name.trim());
  const taken = !editing && live !== undefined;

  const server = useMutation({
    mutationFn: async () => {
      const unchanged = editing && endpoint.trim() === editing.endpoint && key.trim() === editing.serverKey
        && (address.trim() || editing.address) === editing.address;
      if (!unchanged) {
        await postTunnel({ name: name.trim(), endpoint: endpoint.trim(), publicKey: key.trim(),
                           address: address.trim() || undefined });
      }
    },
    onSuccess: () => { queryClient.invalidateQueries({ queryKey: ['lan'] }); setStep('access'); },
  });

  // One change a request (lib/lan.uc): what it reaches, then the internet.
  const access = useMutation({
    mutationFn: async () => {
      const t = live!;
      const to = reach === 'devices' && devices.length === 0 ? 'none' : reach;
      if (to !== t.reach || (to === 'devices' && devices.join(',') !== t.devices.join(','))) {
        await postTunnel(to === 'devices' ? { name: t.name, reach: to, devices } : { name: t.name, reach: to });
      }
      if (internet !== t.internet) await postTunnel({ name: t.name, internet });
    },
    onSuccess: () => { queryClient.invalidateQueries({ queryKey: ['lan'] }); setStep('key'); },
  });

  let body: ReactNode;
  let footer: ReactNode;
  if (step === 'server') {
    body = (
      <>
        {server.isError && <Notice tone="error">{(server.error as Error).message}</Notice>}
        {taken && <Notice tone="warning">A tunnel named {name.trim()} exists.</Notice>}
        <TextField label="Name" mono value={name} placeholder="campo" disabled={editing !== null}
                   onChange={(e) => setName(e.target.value)} />
        <TextField label="Server endpoint" mono value={endpoint} placeholder="203.0.113.10:51820"
                   onChange={(e) => setEndpoint(e.target.value)} />
        <TextField label="Server public key" mono value={key} onChange={(e) => setKey(e.target.value)} />
        <TextField label="Address" mono value={address} placeholder="10.77.0.2/30"
                   onChange={(e) => setAddress(e.target.value)} />
      </>
    );
    footer = (
      <>
        <Button onClick={onClose}>Cancel</Button>
        <Button variant="primary" loading={server.isPending}
                disabled={!name.trim() || !endpoint.trim() || !key.trim() || taken}
                onClick={() => server.mutate()}>
          Next
        </Button>
      </>
    );
  } else if (step === 'access') {
    body = (
      <>
        {access.isError && <Notice tone="error">{(access.error as Error).message}</Notice>}
        <FactList>
          <Fact label="Reaches"
                value={<Segmented aria-label="What the server reaches" value={reach} options={[...REACH]} onChange={setReach} />} />
          <Fact label="Internet"
                value={<Segmented aria-label="Internet through the tunnel" value={internet ? 'on' : 'off'}
                                  options={[...SWITCH]} onChange={(next) => setInternet(next === 'on')} />} />
        </FactList>
        {reach === 'devices' && <DevicePicker pinned={pinned} selected={devices} onChange={setDevices} />}
      </>
    );
    footer = (
      <>
        <Button onClick={() => setStep('server')}>Back</Button>
        <Button variant="primary" loading={access.isPending} disabled={!live}
                onClick={() => access.mutate()}>
          Next
        </Button>
      </>
    );
  } else {
    body = live && <TunnelKey tunnel={live} />;
    footer = <Button variant="primary" onClick={onClose}>Done</Button>;
  }

  const reached = WIZARD_STEPS.indexOf(step);
  return (
    <Dialog open onClose={onClose} size="compact" title={editing ? `Edit ${editing.name}` : 'Add Tunnel'} footer={footer}>
      <div className={own.steps} aria-hidden>
        {WIZARD_STEPS.map((s, i) => <span key={s} className={`${own.step} ${i <= reached ? own.done : ''}`} />)}
      </div>
      {body}
    </Dialog>
  );
}

// What the server is given on the gateway: its key for the server's peer.
function TunnelKey({ tunnel: t }: { tunnel: LanTunnel }) {
  const [copied, setCopied] = useState(false);
  return (
    <FactList>
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
      <Fact label="Server" value={t.endpoint} mono />
    </FactList>
  );
}

type PickRow = { ip: string; name: string | null; mac: string | null; port: string | null };
const pick = createColumnHelper<PickRow>();

// The devices a server may be given, as a table: name, address, MAC, port.
function DevicePicker({
  pinned, selected, disabled, onChange,
}: {
  pinned: LanClient[];
  selected: string[];
  disabled?: boolean;
  onChange: (devices: string[]) => void;
}) {
  const rows: PickRow[] = [
    ...pinned.map((c) => ({ ip: (c.reserved ?? c.ip)!, name: c.hostname ?? null, mac: c.mac, port: c.port ?? null })),
    ...selected.filter((ip) => !pinned.some((c) => (c.reserved ?? c.ip) === ip))
      .map((ip) => ({ ip, name: null, mac: null, port: null })),
  ];
  const toggle = (ip: string) =>
    onChange(selected.includes(ip) ? selected.filter((d) => d !== ip) : [...selected, ip]);

  const columns = [
    pick.display({
      id: 'pick',
      header: '',
      size: 36,
      cell: (info) => (
        <input type="checkbox" aria-label={`Give ${info.row.original.ip}`} disabled={disabled}
               checked={selected.includes(info.row.original.ip)}
               onChange={() => toggle(info.row.original.ip)} onClick={(e) => e.stopPropagation()} />
      ),
    }),
    pick.accessor('name', { header: 'Name', cell: (info) => <span className={own.name}>{info.getValue() || '—'}</span> }),
    pick.accessor('ip', { header: 'Address', size: 130, cell: (info) => <span className="mono">{info.getValue()}</span> }),
    pick.accessor('mac', { header: 'MAC', size: 140, cell: (info) => <span className="mono">{info.getValue() ?? '—'}</span> }),
    pick.accessor('port', { header: 'Port', size: 72, cell: (info) => (info.getValue() ? portLabel(info.getValue()!) : '—') }),
  ];
  const table = useReactTable({ data: rows, columns, getRowId: (r) => r.ip, getCoreRowModel: getCoreRowModel() });

  if (rows.length === 0) return <Notice tone="info">No reserved clients.</Notice>;
  return (
    <DataTable table={table} fill="name" cellClassName={() => own.cell}
               onRowClick={disabled ? undefined : (row) => toggle(row.original.ip)} />
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
  const now = Math.floor(Date.now() / 1000);
  const fresh = t.latestHandshake != null && now - t.latestHandshake < HANDSHAKE_FRESH;
  const shown = mode === 'devices' && t.reach === 'none' ? 'devices' : t.reach;

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
      </FactList>
      <TunnelKey tunnel={t} />
      <FactList>
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
        <DevicePicker pinned={pinned} selected={t.devices} disabled={pending}
                      onChange={(devices) => change(devices.length ? { reach: 'devices', devices } : { reach: 'none' })} />
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
