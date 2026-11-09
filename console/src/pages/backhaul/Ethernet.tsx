import { useState } from 'react';
import { EthernetPort } from 'lucide-react';
import { useQuery } from '@tanstack/react-query';
import { api } from '@/services/api';
import type { Addressing, NetworkStatus, Port, PortUplink, PortsStatus } from '@/types';
import Section from '@/components/ui/Section';
import { StatusBadge } from '@/components/ui/Badge';
import Fact, { FactList } from '@/components/Fact';
import Notice from '@/components/ui/Notice';
import Button from '@/components/ui/Button';
import Segmented from '@/components/ui/Segmented';
import { TextField } from '@/components/ui/Field';
import Spinner from '@/components/ui/Spinner';
import ErrorState from '@/components/ErrorState';
import PortsChangeNotice from '@/components/PortsChangeNotice';
import { usePortsChange } from '@/hooks/usePortsChange';
import styles from '../Pages.module.css';

/**
 * Every wired uplink, one card each: a port, or a VLAN on one, that
 * parkeze-ports has as an uplink. Each one's addressing is DHCP or static.
 *
 * Applied like a port change, because it is one: a wrong static address on
 * the uplink the tunnel rides takes the gateway away from somebody working
 * through Pulzr Net, and the change is undone unless this page reaches the
 * gateway again afterwards.
 */

interface Wired {
  key: string;
  label: string;
  port: Port;
  vid: number | null;
  uplink: PortUplink;
}

const MODES = [
  { value: 'dhcp', label: 'DHCP' },
  { value: 'static', label: 'Static' },
] as const;

export default function Ethernet() {
  const ports = useQuery({
    queryKey: ['ports'],
    queryFn: () => api.get<PortsStatus>('/ports/status'),
    refetchInterval: 10_000,
  });
  const network = useQuery({
    queryKey: ['network-status'],
    queryFn: () => api.get<NetworkStatus>('/network/status'),
  });
  const change = usePortsChange();

  if (ports.isLoading) return <Spinner label="Reading the uplinks" />;
  if (ports.isError) return <ErrorState error={ports.error} onRetry={ports.refetch} />;

  const state = ports.data!;
  const wired: Wired[] = [];
  for (const port of state.ports) {
    if (port.role === 'uplink' && port.uplink)
      wired.push({ key: port.name, label: port.label, port, vid: null, uplink: port.uplink });
    for (const v of port.vlans)
      if (v.role === 'uplink' && v.uplink)
        wired.push({ key: `${port.name}.${v.vid}`, label: `${port.label} VLAN ${v.vid}`, port, vid: v.vid, uplink: v.uplink });
  }
  const busy = change.applying || change.phase === 'confirming';

  return (
    <div className="fade-in">
      <PortsChangeNotice change={change} />
      {!wired.length && <Notice tone="info">No port is an uplink.</Notice>}
      {wired.map((w) => (
        <Uplink
          key={w.key}
          wired={w}
          console={state.console === w.port.name && w.vid == null ? network.data : undefined}
          disabled={busy}
          onApply={(addressing) => change.apply('/ports/addressing', { port: w.port.name, vid: w.vid, addressing })}
        />
      ))}
    </div>
  );
}

function Uplink({
  wired, console: net, disabled, onApply,
}: {
  wired: Wired;
  console?: NetworkStatus;
  disabled: boolean;
  onApply: (addressing: Addressing) => void;
}) {
  const a = wired.uplink.addressing;
  const [mode, setMode] = useState<'dhcp' | 'static'>(a.mode);
  const [address, setAddress] = useState(a.address ?? '');
  const [netmask, setNetmask] = useState(a.netmask ?? '255.255.255.0');
  const [gateway, setGateway] = useState(a.gateway ?? '');
  const [dns, setDns] = useState((a.dns ?? []).join(', '));
  const link = wired.port.link;
  const dnsList = dns.split(',').map((x) => x.trim()).filter(Boolean);
  // Applying what is already set would reload the network and open an undo
  // window for nothing.
  const changed = mode !== a.mode || (mode === 'static' && (
    address !== (a.address ?? '') || netmask !== (a.netmask ?? '255.255.255.0')
    || gateway !== (a.gateway ?? '') || dnsList.join(',') !== (a.dns ?? []).join(',')));
  // The lease as it stands, kept as a static address: what a site router's
  // forward needs, since it points at one address for good.
  const lease = a.mode === 'dhcp' && mode === 'dhcp' ? leaseOf(wired.uplink.state) : null;

  return (
    <Section title={wired.label} icon={EthernetPort} note={<StatusBadge ok={wired.uplink.state.up} />}>
      <FactList>
        <Fact label="Address" value={wired.uplink.state.address} mono />
        <Fact label="Gateway" value={wired.uplink.state.gateway} mono />
        <Fact label="Link" value={link.up ? (link.speed ? speed(link.speed) : 'Up') : 'No cable'} />
        {net && <Fact label="Console address" value={net.console.address} mono />}
        {net && <Fact label="Link-local" value={net.linkLocal.address} mono />}
      </FactList>

      <div className={styles.options}>
        <Segmented aria-label={`${wired.label} addressing`} value={mode} options={[...MODES]}
                   disabled={disabled} onChange={setMode} />
      </div>

      {mode === 'static' && (
        <div className={styles.form}>
          <TextField label="Address" mono value={address} placeholder="10.0.0.50"
                     onChange={(event) => setAddress(event.target.value)} />
          <TextField label="Netmask" mono value={netmask}
                     onChange={(event) => setNetmask(event.target.value)} />
          <TextField label="Gateway" mono value={gateway} placeholder="10.0.0.1"
                     onChange={(event) => setGateway(event.target.value)} />
          <TextField label="DNS" mono value={dns} placeholder="1.1.1.1, 8.8.8.8"
                     onChange={(event) => setDns(event.target.value)} />
        </div>
      )}

      <div className={styles.actions}>
        {lease && (
          <Button disabled={disabled} onClick={() => onApply(lease)}>
            Make {lease.address} static
          </Button>
        )}
        <Button
          variant="primary"
          disabled={disabled || !changed}
          onClick={() => onApply(mode === 'static' ? { mode, address, netmask, gateway, dns: dnsList } : { mode })}
        >
          Apply
        </Button>
      </div>
    </Section>
  );
}

// "10.0.0.50/24" and its route as static addressing; null when the lease is
// missing a part.
function leaseOf(state: PortUplink['state']): Addressing | null {
  const [address, bits] = (state.address ?? '').split('/');
  const prefix = Number(bits);
  if (!state.up || !address || !state.gateway || !(prefix >= 1 && prefix <= 30)) return null;
  const mask = (0xffffffff << (32 - prefix)) >>> 0;
  const netmask = [24, 16, 8, 0].map((shift) => (mask >>> shift) & 255).join('.');
  return { mode: 'static', address, netmask, gateway: state.gateway, dns: (state.dns ?? []).slice(0, 3) };
}

function speed(mbps: number) {
  return mbps >= 1000 ? `${mbps / 1000} Gb/s` : `${mbps} Mb/s`;
}
