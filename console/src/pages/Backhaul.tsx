import { useEffect, useState } from 'react';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { Cable, Network, Radio, ShieldCheck } from 'lucide-react';
import { api } from '@/services/api';
import type { BackhaulStatus, NetworkStatus } from '@/types';
import Card from '@/components/ui/Card';
import Badge, { StatusBadge } from '@/components/ui/Badge';
import Fact, { FactList } from '@/components/Fact';
import Notice from '@/components/ui/Notice';
import Button from '@/components/ui/Button';
import { CheckboxField, TextField } from '@/components/ui/Field';
import PageHeader from '@/components/PageHeader';
import Spinner from '@/components/ui/Spinner';
import ErrorState from '@/components/ErrorState';
import styles from './Pages.module.css';

/**
 * How this gateway reaches the network, and how we reach it.
 *
 * Narrower than LuCI's networking pages on purpose: DHCP or a static address
 * for ethernet, APN and on/off for cellular, and nothing that could take the
 * console address away from the person using it. See docs/backhaul.md.
 */
export default function Backhaul() {
  const queryClient = useQueryClient();

  const network = useQuery({
    queryKey: ['network-status'],
    queryFn: () => api.get<NetworkStatus>('/network/status'),
  });
  const paths = useQuery({
    queryKey: ['backhaul'],
    queryFn: () => api.get<BackhaulStatus>('/network/backhaul'),
    refetchInterval: 15_000,
  });

  if (network.isLoading) return <Spinner label="Reading network state" />;
  if (network.isError) return <ErrorState error={network.error} onRetry={network.refetch} />;

  const state = network.data!;

  return (
    <div className="fade-in">
      <PageHeader title="Backhaul" />

      {paths.data && <Notice tone="info">{paths.data.tunnel.note}</Notice>}

      <CellularCard
        state={state}
        onApplied={() => {
          queryClient.invalidateQueries({ queryKey: ['network-status'] });
          queryClient.invalidateQueries({ queryKey: ['backhaul'] });
        }}
      />

      <EthernetCard
        state={state}
        onApplied={() => {
          queryClient.invalidateQueries({ queryKey: ['network-status'] });
          queryClient.invalidateQueries({ queryKey: ['backhaul'] });
        }}
      />

      <Card title="Management tunnel" icon={ShieldCheck}>
        <FactList>
          <Fact
            label="State"
            value={
              <StatusBadge
                ok={paths.data?.tunnel.state === 'up'}
                okLabel="Connected"
                badLabel={
                  paths.data?.tunnel.state === 'none'
                    ? 'Not enrolled'
                    : paths.data?.tunnel.state === 'waiting'
                      ? 'No recent handshake'
                      : 'Unknown'
                }
              />
            }
          />
          <Fact label="Address" value={paths.data?.tunnel.address} mono />
          <Fact label="Hub" value={paths.data?.tunnel.endpoint} mono />
          <Fact
            label="Last handshake"
            value={
              paths.data?.tunnel.lastHandshake != null
                ? `${paths.data.tunnel.lastHandshake}s ago`
                : null
            }
          />
          <Fact
            label="Egress"
            value={
              paths.data?.wired.device ? (
                <span className="mono">
                  {paths.data.wired.device} → {paths.data.wired.gateway}
                </span>
              ) : (
                <Badge tone="warning">No wired route — tunnel is down by design</Badge>
              )
            }
          />
        </FactList>
      </Card>

      {/* Local access, kept separate from the uplink above even though both
          live on one socket. They fail independently — an unplugged gateway
          still answers a laptop — and showing them as one thing is what makes
          a working gateway look dead. */}
      <Card title="Local access" icon={Cable}>
        <FactList>
          <Fact label="Console address" value={state.console.address} mono />
          <Fact label="Link-local" value={state.linkLocal.address} mono />
          <Fact
            label="State"
            value={<StatusBadge ok={state.console.up === true} />}
          />
        </FactList>
      </Card>
    </div>
  );
}

/**
 * The one uplink an operator may change.
 *
 * Only the APN and the on/off switch are exposed. Everything else about a 1NCE
 * SIM is fixed by the carrier, and a console offering to change the PDP type is
 * a console offering a way to strand a gateway that is only reachable over it.
 */
function CellularCard({
  state,
  onApplied,
}: {
  state: NetworkStatus;
  onApplied: () => void;
}) {
  const [apn, setApn] = useState(state.cellular.apn ?? '');
  const [enabled, setEnabled] = useState(state.cellular.enabled);

  // Re-sync when a refetch brings different values, so an APN changed from
  // parkeze.net does not sit invisibly behind a stale local edit.
  useEffect(() => {
    setApn(state.cellular.apn ?? '');
    setEnabled(state.cellular.enabled);
  }, [state.cellular.apn, state.cellular.enabled]);

  const apply = useMutation({
    mutationFn: () => api.post('/network/cellular', { apn: apn.trim(), enabled }),
    onSuccess: onApplied,
  });

  const modem = state.cellular.modem;

  return (
    <Card title="Cellular" icon={Radio}>
      <FactList>
        <Fact label="State" value={<StatusBadge ok={state.cellular.up === true} />} />
        <Fact label="Address" value={state.cellular.address} mono />
        <Fact label="Network" value={modem?.network} />
        <Fact label="Technology" value={modem?.technology} />
        <Fact label="Signal" value={modem?.rssi != null ? `${modem.rssi} dBm` : null} />
      </FactList>

      <div className={styles.divider} />

      <TextField
        label="APN"
        value={apn}
        onChange={(event) => setApn(event.target.value)}
        hint="Set by the carrier. 1NCE SIMs use iot.1nce.net."
      />
      <CheckboxField
        label="Cellular backhaul enabled"
        checked={enabled}
        onChange={(event) => setEnabled(event.target.checked)}
      />

      {apply.isError && <Notice tone="error">{(apply.error as Error).message}</Notice>}
      {apply.isSuccess && <Notice tone="success">Applied. The modem is re-attaching.</Notice>}

      <div className={styles.actions}>
        <Button variant="primary" loading={apply.isPending} onClick={() => apply.mutate()}>
          Apply
        </Button>
      </div>
    </Card>
  );
}

/**
 * The wired uplink: DHCP, or a static address for a site that needs one.
 *
 * Changing it never cuts off the person doing it. The console address lives on
 * the same port as a separate interface and is not touched, so a wrong static
 * address costs the uplink, not this page — which is also why there is no
 * timed rollback. The management tunnel follows on its own once the uplink comes up.
 */
function EthernetCard({ state, onApplied }: { state: NetworkStatus; onApplied: () => void }) {
  const wan = state.wan;
  const [mode, setMode] = useState<'dhcp' | 'static'>(wan.mode);
  const [address, setAddress] = useState(wan.staticAddress ?? '');
  const [netmask, setNetmask] = useState(wan.staticNetmask ?? '255.255.255.0');
  const [gateway, setGateway] = useState(wan.staticGateway ?? '');
  const [dns, setDns] = useState((wan.dns ?? []).join(', '));

  const apply = useMutation({
    mutationFn: () =>
      api.post('/network/ethernet', {
        mode,
        address,
        netmask,
        gateway,
        dns: dns.split(',').map((server) => server.trim()).filter(Boolean),
      }),
    onSuccess: onApplied,
  });

  return (
    <Card title="Ethernet" icon={Network}>
      <FactList>
        <Fact label="State" value={<StatusBadge ok={wan.up === true} />} />
        <Fact label="Address" value={wan.address} mono />
        <Fact label="Gateway" value={wan.gateway} mono />
      </FactList>

      <div className={styles.row}>
        <Button variant={mode === 'dhcp' ? 'primary' : undefined} onClick={() => setMode('dhcp')}>
          DHCP
        </Button>
        <Button variant={mode === 'static' ? 'primary' : undefined} onClick={() => setMode('static')}>
          Static
        </Button>
      </div>

      {mode === 'static' && (
        <>
          <TextField label="Address" value={address} placeholder="10.0.0.50"
                     onChange={(event) => setAddress(event.target.value)} />
          <TextField label="Netmask" value={netmask}
                     onChange={(event) => setNetmask(event.target.value)} />
          <TextField label="Gateway" value={gateway} placeholder="10.0.0.1"
                     onChange={(event) => setGateway(event.target.value)} />
          <TextField label="DNS" value={dns} placeholder="1.1.1.1, 8.8.8.8"
                     onChange={(event) => setDns(event.target.value)} />
        </>
      )}

      {apply.isError && <Notice tone="error">{(apply.error as Error).message}</Notice>}
      {apply.isSuccess && <Notice tone="success">Applied.</Notice>}

      <div className={styles.actions}>
        <Button variant="primary" loading={apply.isPending} onClick={() => apply.mutate()}>
          Apply
        </Button>
      </div>
    </Card>
  );
}
