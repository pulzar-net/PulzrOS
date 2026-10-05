import { useState } from 'react';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { api } from '@/services/api';
import type { NetworkStatus } from '@/types';
import Section from '@/components/ui/Section';
import { StatusBadge } from '@/components/ui/Badge';
import Fact, { FactList } from '@/components/Fact';
import Notice from '@/components/ui/Notice';
import Button from '@/components/ui/Button';
import { TextField } from '@/components/ui/Field';
import Spinner from '@/components/ui/Spinner';
import ErrorState from '@/components/ErrorState';
import styles from '../Pages.module.css';

/**
 * The wired uplink: DHCP, or a static address for a site that needs one.
 *
 * Changing it never cuts off the person doing it. The console address lives on
 * the same port as a separate interface and is not touched, so a wrong static
 * address costs the uplink, not this page — which is also why there is no
 * timed rollback. The management tunnel follows on its own once the uplink
 * comes up.
 */
export default function Ethernet() {
  const queryClient = useQueryClient();
  const network = useQuery({
    queryKey: ['network-status'],
    queryFn: () => api.get<NetworkStatus>('/network/status'),
  });

  if (network.isLoading) return <Spinner label="Reading network state" />;
  if (network.isError) return <ErrorState error={network.error} onRetry={network.refetch} />;

  const state = network.data!;
  const wan = state.wan;

  return (
    <div className="fade-in">
      <Section>
        <FactList>
          <Fact label="State" value={<StatusBadge ok={wan.up === true} />} />
          <Fact label="Address" value={wan.address} mono />
          <Fact label="Gateway" value={wan.gateway} mono />
          <Fact label="Console address" value={state.console.address} mono />
          <Fact label="Link-local" value={state.linkLocal.address} mono />
        </FactList>
      </Section>

      <Addressing
        state={state}
        onApplied={() => {
          queryClient.invalidateQueries({ queryKey: ['network-status'] });
          queryClient.invalidateQueries({ queryKey: ['backhaul'] });
        }}
      />
    </div>
  );
}

function Addressing({ state, onApplied }: { state: NetworkStatus; onApplied: () => void }) {
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
    <Section title="Addressing">
      <div className={styles.row}>
        <Button variant={mode === 'dhcp' ? 'primary' : undefined} onClick={() => setMode('dhcp')}>
          DHCP
        </Button>
        <Button variant={mode === 'static' ? 'primary' : undefined} onClick={() => setMode('static')}>
          Static
        </Button>
      </div>

      {mode === 'static' && (
        <div className={styles.form}>
          <TextField label="Address" value={address} placeholder="10.0.0.50"
                     onChange={(event) => setAddress(event.target.value)} />
          <TextField label="Netmask" value={netmask}
                     onChange={(event) => setNetmask(event.target.value)} />
          <TextField label="Gateway" value={gateway} placeholder="10.0.0.1"
                     onChange={(event) => setGateway(event.target.value)} />
          <TextField label="DNS" value={dns} placeholder="1.1.1.1, 8.8.8.8"
                     onChange={(event) => setDns(event.target.value)} />
        </div>
      )}

      {apply.isError && <Notice tone="error">{(apply.error as Error).message}</Notice>}
      {apply.isSuccess && <Notice tone="success">Applied.</Notice>}

      <div className={styles.actions}>
        <Button variant="primary" loading={apply.isPending} onClick={() => apply.mutate()}>
          Apply
        </Button>
      </div>
    </Section>
  );
}
