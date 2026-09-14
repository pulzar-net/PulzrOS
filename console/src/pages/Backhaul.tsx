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
 * Narrower than LuCI's networking pages on purpose. A Parkeze gateway has two
 * uplinks and only one of them is the operator's to configure — see
 * docs/backhaul.md. Ethernet is rendered read-only with the reason supplied by
 * the API, so the UI cannot drift from the device's own policy.
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
      <PageHeader
        title="Backhaul"
        subtitle="How this gateway reaches the network, and how we reach it."
      />

      {paths.data && <Notice tone="info">{paths.data.tailscale.note}</Notice>}

      <CellularCard
        state={state}
        onApplied={() => {
          queryClient.invalidateQueries({ queryKey: ['network-status'] });
          queryClient.invalidateQueries({ queryKey: ['backhaul'] });
        }}
      />

      {/* Shown, never editable. */}
      <Card title="Ethernet" icon={Network}>
        <Notice tone="info">{state.wan.reason}</Notice>
        <FactList>
          <Fact label="Configured" value={state.wan.enabled ? 'Enabled' : 'Disabled'} />
          <Fact label="State" value={<StatusBadge ok={state.wan.up === true} />} />
          <Fact label="Address" value={state.wan.address} mono />
          <Fact label="Gateway" value={state.wan.gateway} mono />
        </FactList>
      </Card>

      <Card title="Tailscale" icon={ShieldCheck}>
        <FactList>
          <Fact
            label="State"
            value={
              <StatusBadge
                ok={paths.data?.tailscale.state === 'Running'}
                okLabel="Connected"
                badLabel={paths.data?.tailscale.state ?? 'Unknown'}
              />
            }
          />
          <Fact label="Node" value={paths.data?.tailscale.self?.hostname} />
          <Fact
            label="Addresses"
            value={paths.data?.tailscale.self?.addresses?.join(', ')}
            mono
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

      <Card title="LAN" icon={Cable}>
        <FactList>
          <Fact label="Address" value={state.lan.address} mono />
          <Fact label="State" value={<StatusBadge ok={state.lan.up === true} />} />
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
