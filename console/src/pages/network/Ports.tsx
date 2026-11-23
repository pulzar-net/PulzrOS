import { useEffect, useMemo, useState } from 'react';
import { useQuery } from '@tanstack/react-query';
import { createColumnHelper, getCoreRowModel, useReactTable } from '@tanstack/react-table';
import { EthernetPort, Trash2 } from 'lucide-react';
import { api } from '@/services/api';
import type { LanClient, LanStatus, Port, PortRole, PortsLayout, PortsStatus } from '@/types';
import Section from '@/components/ui/Section';
import Badge from '@/components/ui/Badge';
import Button from '@/components/ui/Button';
import Dialog from '@/components/ui/Dialog';
import Notice from '@/components/ui/Notice';
import Segmented from '@/components/ui/Segmented';
import { TextField } from '@/components/ui/Field';
import DataTable from '@/components/DataTable';
import Fact, { FactList } from '@/components/Fact';
import Spinner from '@/components/ui/Spinner';
import ErrorState from '@/components/ErrorState';
import ApplyChangeNotice from '@/components/ApplyChangeNotice';
import { useApplyChange } from '@/hooks/useApplyChange';
import { useFeatures } from '@/hooks/useFeatures';
import { addressList, countdown } from '@/lib/format';
import styles from './Ports.module.css';

/**
 * What each Ethernet port is for, what is on it, and the VLANs it carries
 * (pulzr-ports), laid out the way a switch's own page is: the jacks in a
 * row, coloured by link, and a table of every port and VLAN with what is at
 * the other end. A row opens its port to edit.
 *
 * Edits are a draft until Apply, and the whole layout is applied at once and
 * kept only once this page reaches the gateway again afterwards; see
 * useApplyChange. A layout that cuts off whoever made it comes back on its own.
 */

type Draft = PortsLayout['ports'];
type DraftPort = Draft[number];
type VlanRole = Exclude<PortRole, 'none'>;

const ROLE_NAMES: Record<PortRole, string> = { uplink: 'Uplink', devices: 'LAN', none: 'Unused' };

const toDraft = (state: PortsStatus): Draft =>
  state.ports.map((p) => ({
    name: p.name,
    role: p.role,
    addressing: p.addressing,
    vlans: p.vlans.map((v) => ({ vid: v.vid, role: v.role, addressing: v.addressing })),
  }));

const same = (a: DraftPort, b: DraftPort) =>
  a.role === b.role && JSON.stringify(a.vlans.map((v) => [v.vid, v.role])) === JSON.stringify(b.vlans.map((v) => [v.vid, v.role]));

/** Gigabit and up, fast Ethernet, or nothing: the colour of a jack. */
function tier(port: Port) {
  if (!port.link.up) return '';
  return (port.link.speed ?? 0) >= 1000 ? styles.gigabit : styles.fast;
}

function speed(mbps: number | null | undefined) {
  if (!mbps) return null;
  return mbps >= 1000 ? `${mbps / 1000} Gb/s` : `${mbps} Mb/s`;
}

const clientName = (c: LanClient) => c.hostname ?? c.ip ?? c.mac;

/** One row of the table: a port, or a VLAN on one. */
interface Row {
  key: string;
  port: Port;
  vid: number | null;
  role: PortRole;
  changed: boolean;
}

const column = createColumnHelper<Row>();

export default function Ports() {
  const status = useQuery({
    queryKey: ['ports'],
    queryFn: () => api.get<PortsStatus>('/ports/status'),
    refetchInterval: 10_000,
  });
  const change = useApplyChange();
  const features = useFeatures();
  // Who is behind each LAN port: pulzr-lan reads it off the bridge's
  // forwarding table, the same answer as the LAN page's Port column.
  const lan = useQuery({
    queryKey: ['lan'],
    queryFn: () => api.get<LanStatus>('/lan/status'),
    enabled: features.has('lan'),
    refetchInterval: 15_000,
  });
  const [draft, setDraft] = useState<Draft | null>(null);
  const [dirty, setDirty] = useState(false);
  const [editing, setEditing] = useState<string | null>(null);
  // The port under the pointer, on the strip or in the table: both show it.
  const [hovered, setHovered] = useState<string | null>(null);
  const lit = (name: string) => name === hovered || name === editing;

  // The page's copy follows the gateway until somebody edits it.
  useEffect(() => {
    if (status.data && !dirty) setDraft(toDraft(status.data));
  }, [status.data, dirty]);

  const state = status.data;
  const clients = lan.data?.clients;

  const rows = useMemo<Row[]>(() => {
    if (!state || !draft) return [];
    const out: Row[] = [];
    for (const port of state.ports) {
      const d = draft.find((p) => p.name === port.name)!;
      const before = toDraft(state).find((p) => p.name === port.name)!;
      out.push({ key: port.name, port, vid: null, role: d.role, changed: !same(d, before) });
      for (const v of d.vlans) {
        out.push({ key: `${port.name}.${v.vid}`, port, vid: v.vid, role: v.role,
                   changed: !before.vlans.some((b) => b.vid === v.vid && b.role === v.role) });
      }
    }
    return out;
  }, [state, draft]);

  const columns = useMemo(() => {
    const behind = (device: string) => (clients ?? []).filter((c) => c.online && c.port === device);
    const uplinkOf = (r: Row) => (r.vid == null ? r.port.uplink : r.port.vlans.find((v) => v.vid === r.vid)?.uplink);
    return [
      column.display({
        id: 'port',
        header: 'Port',
        size: 128,
        cell: ({ row: { original: r } }) => (
          <span className={`${styles.port} ${r.vid != null ? styles.vlanPort : ''}`}>
            {r.vid == null && <span className={`${styles.dot} ${tier(r.port)}`} />}
            {r.vid == null ? r.port.label : `VLAN ${r.vid}`}
            {r.changed && <span className={styles.changed}>edited</span>}
          </span>
        ),
      }),
      column.display({
        id: 'link',
        header: 'Link',
        size: 88,
        cell: ({ row: { original: r } }) =>
          r.vid != null ? <span className={styles.dim}>Tagged</span>
            : r.port.link.up ? speed(r.port.link.speed) ?? 'Up'
            : <span className={styles.dim}>No cable</span>,
      }),
      column.display({
        id: 'role',
        header: 'Role',
        size: 84,
        cell: ({ row: { original: r } }) =>
          r.role === 'none' ? <span className={styles.dim}>Unused</span>
            : <Badge tone={r.role === 'uplink' ? 'info' : 'neutral'}>{ROLE_NAMES[r.role]}</Badge>,
      }),
      // One line a cell, every row the same height: what is behind a port
      // is split over columns rather than stacked in one.
      column.display({
        id: 'connected',
        header: 'Connected',
        cell: ({ row: { original: r } }) => {
          const uplink = uplinkOf(r);
          let text: string | null = null;
          if (uplink?.router) text = [uplink.router.maker ?? 'Router', uplink.router.address].join(' · ');
          else if (r.role === 'devices') {
            const here = behind(r.vid == null ? r.port.name : `${r.port.name}.${r.vid}`);
            if (here.length) text = here.map(clientName).join(', ');
          }
          return text ? <span className={styles.line} title={text}>{text}</span> : <span className={styles.dim}>—</span>;
        },
      }),
      column.display({
        id: 'announced',
        header: 'Announced',
        size: 170,
        cell: ({ row: { original: r } }) => {
          // What spoke LLDP or CDP on the port: by name, else by maker. A
          // neighbour that sends its MAC as its port id said nothing of a port.
          const n = r.vid == null ? r.port.neighbors?.[0] : undefined;
          if (!n) return <span className={styles.dim}>—</span>;
          const who = n.name ?? (n.maker ? `${n.maker} device` : n.chassis);
          const where = n.portDescription ?? (n.port && n.port !== n.chassis ? n.port : null);
          const text = [who, where ? `port ${where}` : null].filter(Boolean).join(', ');
          return <span className={styles.line} title={text}>{text}</span>;
        },
      }),
      column.display({
        id: 'address',
        header: 'Address',
        size: 140,
        cell: ({ row: { original: r } }) => {
          const uplink = uplinkOf(r);
          // Every address on the device, whichever interface holds it: the
          // board's port carries its lease and the console's two.
          const held = r.vid == null ? r.port.addresses : r.port.vlans.find((v) => v.vid === r.vid)?.addresses;
          const address = held?.length ? held.join(', ')
            : uplink?.state.address ?? (r.vid == null && state?.console === r.port.name ? state.consoleAddress : null);
          return address ? <span className="mono">{address}</span> : <span className={styles.dim}>—</span>;
        },
      }),
      column.display({
        id: 'provider',
        header: 'Provider',
        size: 170,
        cell: ({ row: { original: r } }) => {
          const name = uplinkOf(r)?.internet?.provider?.name;
          return name ? <span className={styles.line} title={name}>{name}</span> : <span className={styles.dim}>—</span>;
        },
      }),
      column.display({
        id: 'public',
        header: 'Public Address',
        size: 130,
        cell: ({ row: { original: r } }) => {
          const address = uplinkOf(r)?.internet?.address;
          return address ? <span className="mono">{address}</span> : <span className={styles.dim}>—</span>;
        },
      }),
    ];
  }, [clients, state]);

  const table = useReactTable({
    data: rows,
    columns,
    getRowId: (r) => r.key,
    getCoreRowModel: getCoreRowModel(),
  });

  if (status.isLoading || !draft) return <Spinner label="Reading the ports" />;
  if (status.isError) return <ErrorState error={status.error} onRetry={status.refetch} />;

  const busy = change.applying || change.phase === 'confirming';
  const foreign = state!.pending && change.phase !== 'confirming' ? state!.pending : null;
  const edited = rows.filter((r) => r.changed).length;
  const editPort = editing ? state!.ports.find((p) => p.name === editing) : null;

  return (
    <div className="fade-in">
      <ApplyChangeNotice change={change} />
      {foreign && (
        <Notice tone="warning">
          A port change{foreign.by ? ` by ${foreign.by}` : ''} is undone in {countdown(foreign.in)} unless it is kept.{' '}
          <Button onClick={() => api.post('/ports/confirm').then(() => status.refetch())}>Keep</Button>{' '}
          <Button onClick={change.undo}>Undo</Button>
        </Notice>
      )}

      <Section title="Ports" icon={EthernetPort} wide>
        <div className={styles.strip} role="list">
          {state!.ports.map((port) => {
            const role = draft.find((p) => p.name === port.name)!.role;
            return (
              <button
                key={port.name}
                type="button"
                role="listitem"
                className={`${styles.jack} ${tier(port)} ${editing === port.name ? styles.selected : ''} ${hovered === port.name ? styles.lit : ''}`}
                onClick={() => setEditing(port.name)}
                onMouseEnter={() => setHovered(port.name)}
                onMouseLeave={() => setHovered(null)}
                aria-label={`${port.label}, ${ROLE_NAMES[role]}`}
              >
                <span className={styles.jackRole}>{ROLE_NAMES[role]}</span>
                <span className={styles.socket}><EthernetPort size={20} strokeWidth={1.8} /></span>
                <span className={styles.jackName}>{port.label}</span>
                <span className={styles.jackSpeed}>{port.link.up ? speed(port.link.speed) ?? 'Up' : '—'}</span>
              </button>
            );
          })}
        </div>

        <DataTable
          table={table}
          fill="connected"
          rowClassName={(row) => `${styles.row} ${lit(row.original.port.name) ? styles.litRow : ''}`}
          onRowHover={(row) => setHovered(row?.original.port.name ?? null)}
          cellClassName={() => styles.cell}
          onRowClick={(row) => setEditing(row.original.port.name)}
          minWidth={1100}
        />
      </Section>

      {(dirty || busy) && (
        <Section wide>
          <div className={styles.bar}>
            <span className={styles.summary}>
              {edited === 1 ? '1 change' : `${edited} changes`}
            </span>
            <Button disabled={busy} onClick={() => { setDirty(false); setDraft(toDraft(state!)); }}>
              Discard
            </Button>
            <Button
              variant="primary"
              disabled={busy}
              loading={change.applying}
              onClick={async () => {
                await change.apply('/ports', { ports: draft });
                setDirty(false);
              }}
            >
              Apply
            </Button>
          </div>
        </Section>
      )}

      {editPort && (
        <PortEditor
          port={editPort}
          clients={(clients ?? []).filter((c) => c.online && (c.port === editPort.name || c.port?.startsWith(`${editPort.name}.`)))}
          consoleAddress={state!.console === editPort.name ? state!.consoleAddress : null}
          draft={draft.find((p) => p.name === editPort.name)!}
          devices={state!.devices}
          disabled={busy}
          onClose={() => setEditing(null)}
          onChange={(next) => {
            setDraft(draft.map((p) => (p.name === editPort.name ? next(p) : p)));
            setDirty(true);
            if (change.phase !== 'confirming') change.reset();
          }}
        />
      )}
    </div>
  );
}

function PortEditor({
  port, clients, consoleAddress, draft, devices, disabled, onClose, onChange,
}: {
  port: Port;
  /** Online LAN clients behind this port or one of its VLANs. */
  clients: LanClient[];
  consoleAddress: string | null;
  draft: DraftPort;
  devices: boolean;
  disabled: boolean;
  onClose: () => void;
  onChange: (next: (p: DraftPort) => DraftPort) => void;
}) {
  const [vid, setVid] = useState('');
  const roles: { value: PortRole; label: string }[] = [
    { value: 'uplink', label: 'Uplink' },
    ...(devices ? [{ value: 'devices' as const, label: 'LAN' }] : []),
    { value: 'none', label: 'Unused' },
  ];
  const vlanRoles: { value: VlanRole; label: string }[] = [
    { value: 'uplink', label: 'Uplink' },
    ...(devices ? [{ value: 'devices' as const, label: 'LAN' }] : []),
  ];
  const number = Number(vid);
  const canAdd = /^\d{1,4}$/.test(vid) && number >= 1 && number <= 4094
    && !draft.vlans.some((v) => v.vid === number) && draft.vlans.length < 8;

  return (
    <Dialog open onClose={onClose} title={port.label}
            footer={<Button variant="primary" onClick={onClose}>Done</Button>}>
      <div className={styles.editor}>
        <PortDetails port={port} clients={clients} consoleAddress={consoleAddress} />

        <div className={styles.heading}>Settings</div>
        <div>
          <div className={styles.label}>Untagged</div>
          <Segmented
            aria-label={`${port.label} role`}
            value={draft.role}
            options={roles}
            disabled={disabled}
            onChange={(role) => onChange((p) => ({ ...p, role }))}
          />
        </div>

        {draft.vlans.length > 0 && (
          <div>
            <div className={styles.label}>VLANs</div>
            <div className={styles.vlans}>
              {draft.vlans.map((v) => (
                <div key={v.vid} className={styles.vlan}>
                  <span className={styles.vlanName}>VLAN {v.vid}</span>
                  <Segmented
                    aria-label={`${port.label} VLAN ${v.vid} role`}
                    value={v.role}
                    options={vlanRoles}
                    disabled={disabled}
                    onChange={(role) => onChange((p) => ({
                      ...p, vlans: p.vlans.map((x) => (x.vid === v.vid ? { ...x, role } : x)),
                    }))}
                  />
                  <Button
                    className={styles.remove}
                    aria-label={`Remove VLAN ${v.vid}`}
                    disabled={disabled}
                    onClick={() => onChange((p) => ({ ...p, vlans: p.vlans.filter((x) => x.vid !== v.vid) }))}
                  >
                    <Trash2 size={14} strokeWidth={2} />
                  </Button>
                </div>
              ))}
            </div>
          </div>
        )}

        <div className={styles.add}>
          <div className={styles.vid}>
            <TextField label="VLAN ID" inputMode="numeric" value={vid} placeholder="20"
                       onChange={(event) => setVid(event.target.value.trim())} />
          </div>
          <Button
            disabled={disabled || !canAdd}
            onClick={() => {
              onChange((p) => ({
                ...p,
                vlans: [...p.vlans, { vid: number, role: 'uplink' as const, addressing: { mode: 'dhcp' as const } }]
                  .sort((a, b) => a.vid - b.vid),
              }));
              setVid('');
            }}
          >
            Add VLAN
          </Button>
        </div>
      </div>
    </Dialog>
  );
}

/** Everything known about a port: its link, the uplink on it and the router
    at the end of that, the devices behind it, and whatever announced itself. */
function PortDetails({ port, clients, consoleAddress }: {
  port: Port;
  clients: LanClient[];
  consoleAddress: string | null;
}) {
  const uplinks = [
    ...(port.uplink ? [{ label: 'Untagged', uplink: port.uplink }] : []),
    ...port.vlans.filter((v) => v.uplink).map((v) => ({ label: `VLAN ${v.vid}`, uplink: v.uplink! })),
  ];
  return (
    <>
      <div className={styles.detailGrid}>
        <div>
          <div className={styles.heading}>Link</div>
          <FactList>
            <Fact label="State" value={port.link.up ? (speed(port.link.speed) ?? 'Up') : 'No cable'} />
            <Fact label="MAC" value={port.link.mac} mono />
            {consoleAddress && <Fact label="Console" value={consoleAddress} mono />}
          </FactList>
        </div>

        {uplinks.map(({ label, uplink }) => (
          <div key={label}>
            <div className={styles.heading}>Uplink{uplinks.length > 1 || label !== 'Untagged' ? `, ${label}` : ''}</div>
            <FactList>
              <Fact label="Address" value={addressList(uplink.state)} mono />
              <Fact label="Addressing" value={uplink.addressing.mode === 'static' ? 'Static' : 'DHCP'} />
              <Fact label="Router" value={uplink.router ? [uplink.router.maker, uplink.router.address].filter(Boolean).join(' · ') : null} />
              {uplink.router?.mac && <Fact label="Router MAC" value={uplink.router.mac} mono />}
              {uplink.internet?.provider?.name && <Fact label="Provider" value={uplink.internet.provider.name} />}
              {uplink.internet?.address && <Fact label="Public address" value={uplink.internet.address} mono />}
            </FactList>
          </div>
        ))}
      </div>

      {clients.length > 0 && (
        <div>
          <div className={styles.heading}>Devices</div>
          <FactList>
            {clients.map((c) => (
              <Fact key={c.mac} label={c.hostname ?? c.mac}
                    value={[c.ip, c.port?.includes('.') ? `VLAN ${c.port.split('.')[1]}` : null, c.mac].filter(Boolean).join(' · ')} mono />
            ))}
          </FactList>
        </div>
      )}

      {(port.neighbors ?? []).map((n, i) => (
        <div key={i}>
          <div className={styles.heading}>Announced over {n.protocol ?? 'LLDP'}</div>
          <FactList>
            {/* Only what it said: most equipment fills in a few of these. */}
            {([
              ['Name', n.name ?? (n.maker ? `${n.maker} device` : null), false],
              ['Maker', n.maker && n.name ? n.maker : null, false],
              ['Description', n.description, false],
              ['Its port', [n.port !== n.chassis ? n.port : null, n.portDescription].filter(Boolean).join(', ') || null, false],
              ['Management', n.managementAddress, true],
              ['Capabilities', n.capabilities.length ? n.capabilities.join(', ') : null, false],
              ['Chassis', n.chassis, true],
            ] as [string, string | null, boolean][]).filter(([, value]) => value).map(([label, value, mono]) => (
              <Fact key={label} label={label} value={value} mono={mono} />
            ))}
          </FactList>
        </div>
      ))}
    </>
  );
}
