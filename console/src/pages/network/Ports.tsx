import { useState } from 'react';
import { Trash2 } from 'lucide-react';
import type { LanClient, Port, PortRole, PortsLayout, PortsStatus } from '@/types';
import Button from '@/components/ui/Button';
import Dialog from '@/components/ui/Dialog';
import Segmented from '@/components/ui/Segmented';
import { TextField } from '@/components/ui/Field';
import Fact, { FactList } from '@/components/Fact';
import { addressList } from '@/lib/format';
import styles from './Ports.module.css';

/**
 * What each Ethernet port is for, and the VLANs it carries (pulzr-ports):
 * the dialog a port opens from the Network page's diagram, with everything
 * known about it and its role.
 *
 * Edits are a draft until Apply, and the whole layout is applied at once and
 * kept only once the page reaches the gateway again afterwards; see
 * useApplyChange. A layout that cuts off whoever made it comes back on its own.
 */

export type Draft = PortsLayout['ports'];
type DraftPort = Draft[number];
type VlanRole = Exclude<PortRole, 'none'>;

export function speed(mbps: number | null | undefined) {
  if (!mbps) return null;
  return mbps >= 1000 ? `${mbps / 1000} Gb/s` : `${mbps} Mb/s`;
}

export const toDraft = (state: PortsStatus): Draft =>
  state.ports.map((p) => ({
    name: p.name,
    role: p.role,
    addressing: p.addressing,
    vlans: p.vlans.map((v) => ({ vid: v.vid, role: v.role, addressing: v.addressing })),
  }));

export const same = (a: DraftPort, b: DraftPort) =>
  a.role === b.role && JSON.stringify(a.vlans.map((v) => [v.vid, v.role])) === JSON.stringify(b.vlans.map((v) => [v.vid, v.role]));

export function PortEditor({
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
