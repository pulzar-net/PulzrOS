import { useEffect, useState } from 'react';
import { useQuery } from '@tanstack/react-query';
import { EthernetPort, Trash2 } from 'lucide-react';
import { api } from '@/services/api';
import type { Port, PortRole, PortsLayout, PortsStatus } from '@/types';
import Section from '@/components/ui/Section';
import Badge from '@/components/ui/Badge';
import Button from '@/components/ui/Button';
import Notice from '@/components/ui/Notice';
import Segmented from '@/components/ui/Segmented';
import { TextField } from '@/components/ui/Field';
import Fact, { FactList } from '@/components/Fact';
import Spinner from '@/components/ui/Spinner';
import ErrorState from '@/components/ErrorState';
import PortsChangeNotice from '@/components/PortsChangeNotice';
import { usePortsChange } from '@/hooks/usePortsChange';
import { countdown } from '@/lib/format';
import styles from './Ports.module.css';

/**
 * What each Ethernet port is for, and the VLANs it carries (parkeze-ports).
 *
 * The whole layout is applied at once and kept only once this page reaches
 * the gateway again afterwards; see usePortsChange. A layout that cuts off
 * whoever made it comes back on its own.
 */

type Draft = PortsLayout['ports'];
type VlanRole = Exclude<PortRole, 'none'>;

const toDraft = (state: PortsStatus): Draft =>
  state.ports.map((p) => ({
    name: p.name,
    role: p.role,
    addressing: p.addressing,
    vlans: p.vlans.map((v) => ({ vid: v.vid, role: v.role, addressing: v.addressing })),
  }));

export default function Ports() {
  const status = useQuery({
    queryKey: ['ports'],
    queryFn: () => api.get<PortsStatus>('/ports/status'),
    refetchInterval: 10_000,
  });
  const change = usePortsChange();
  const [draft, setDraft] = useState<Draft | null>(null);
  const [dirty, setDirty] = useState(false);

  // The page's copy follows the gateway until somebody edits it.
  useEffect(() => {
    if (status.data && !dirty) setDraft(toDraft(status.data));
  }, [status.data, dirty]);

  if (status.isLoading || !draft) return <Spinner label="Reading the ports" />;
  if (status.isError) return <ErrorState error={status.error} onRetry={status.refetch} />;

  const state = status.data!;
  const edit = (name: string, next: (p: Draft[number]) => Draft[number]) => {
    setDraft(draft.map((p) => (p.name === name ? next(p) : p)));
    setDirty(true);
    if (change.phase !== 'confirming') change.reset();
  };
  const busy = change.applying || change.phase === 'confirming';
  const foreign = state.pending && change.phase !== 'confirming' ? state.pending : null;

  return (
    <div className="fade-in">
      <PortsChangeNotice change={change} />
      {foreign && (
        <Notice tone="warning">
          A port change{foreign.by ? ` by ${foreign.by}` : ''} is undone in {countdown(foreign.in)} unless it is kept.{' '}
          <Button onClick={() => api.post('/ports/confirm').then(() => status.refetch())}>Keep</Button>{' '}
          <Button onClick={change.undo}>Undo</Button>
        </Notice>
      )}

      {state.ports.map((port) => (
        <PortCard
          key={port.name}
          port={port}
          draft={draft.find((p) => p.name === port.name)!}
          devices={state.devices}
          console={state.console === port.name ? state.consoleAddress : null}
          disabled={busy}
          onChange={(next) => edit(port.name, next)}
        />
      ))}

      <Section wide>
        <div className={styles.bar}>
          <Button disabled={!dirty || busy} onClick={() => { setDirty(false); setDraft(toDraft(state)); }}>
            Discard
          </Button>
          <Button
            variant="primary"
            disabled={!dirty || busy}
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
    </div>
  );
}

function PortCard({
  port, draft, devices, console: hasConsole, disabled, onChange,
}: {
  port: Port;
  draft: Draft[number];
  devices: boolean;
  console: string | null;
  disabled: boolean;
  onChange: (next: (p: Draft[number]) => Draft[number]) => void;
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

  const link = port.link.present === false ? <Badge tone="error">Missing</Badge>
    : port.link.up ? <Badge tone="success">{port.link.speed ? speed(port.link.speed) : 'Link'}</Badge>
    : <Badge tone="neutral">No cable</Badge>;

  return (
    <Section title={port.label} icon={EthernetPort} note={link}>
      <Segmented
        aria-label={`${port.label} role`}
        value={draft.role}
        options={roles}
        disabled={disabled}
        onChange={(role) => onChange((p) => ({ ...p, role }))}
      />

      {(port.uplink || hasConsole) && (
        <div className={styles.facts}>
          <FactList>
            {port.uplink && <Fact label="Address" value={port.uplink.state.address} mono />}
            {hasConsole && <Fact label="Console" value={hasConsole} mono />}
          </FactList>
        </div>
      )}

      {draft.vlans.length > 0 && (
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
                aria-label={`Remove VLAN ${v.vid}`}
                disabled={disabled}
                onClick={() => onChange((p) => ({ ...p, vlans: p.vlans.filter((x) => x.vid !== v.vid) }))}
              >
                <Trash2 size={14} strokeWidth={2} />
              </Button>
            </div>
          ))}
        </div>
      )}

      <div className={styles.add}>
        <TextField label="VLAN ID" inputMode="numeric" value={vid} placeholder="20"
                   onChange={(event) => setVid(event.target.value.trim())} />
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
    </Section>
  );
}

function speed(mbps: number) {
  return mbps >= 1000 ? `${mbps / 1000} Gb/s` : `${mbps} Mb/s`;
}
