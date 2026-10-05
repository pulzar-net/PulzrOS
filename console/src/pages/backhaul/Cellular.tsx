import { useEffect, useState } from 'react';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { api } from '@/services/api';
import type { NetworkStatus } from '@/types';
import Section from '@/components/ui/Section';
import { StatusBadge } from '@/components/ui/Badge';
import Fact, { FactList } from '@/components/Fact';
import Notice from '@/components/ui/Notice';
import Button from '@/components/ui/Button';
import { CheckboxField, TextField } from '@/components/ui/Field';
import Spinner from '@/components/ui/Spinner';
import ErrorState from '@/components/ErrorState';
import styles from '../Pages.module.css';

/**
 * The metered uplink.
 *
 * Only the APN and the on/off switch are exposed. Everything else about a 1NCE
 * SIM is fixed by the carrier, and a console offering to change the PDP type is
 * a console offering a way to strand a gateway that is only reachable over it.
 */
export default function Cellular() {
  const queryClient = useQueryClient();
  const network = useQuery({
    queryKey: ['network-status'],
    queryFn: () => api.get<NetworkStatus>('/network/status'),
  });

  const cellular = network.data?.cellular;
  const [apn, setApn] = useState('');
  const [enabled, setEnabled] = useState(false);

  // Re-sync when a refetch brings different values, so an APN changed from
  // parkeze.net does not sit invisibly behind a stale local edit.
  useEffect(() => {
    if (!cellular) return;
    setApn(cellular.apn ?? '');
    setEnabled(cellular.enabled);
  }, [cellular?.apn, cellular?.enabled]); // eslint-disable-line react-hooks/exhaustive-deps

  const apply = useMutation({
    mutationFn: () => api.post('/network/cellular', { apn: apn.trim(), enabled }),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['network-status'] });
      queryClient.invalidateQueries({ queryKey: ['backhaul'] });
    },
  });

  if (network.isLoading) return <Spinner label="Reading network state" />;
  if (network.isError) return <ErrorState error={network.error} onRetry={network.refetch} />;

  const modem = cellular!.modem;

  return (
    <div className="fade-in">
      <Section>
        <FactList>
          <Fact label="State" value={<StatusBadge ok={cellular!.up === true} />} />
          <Fact label="Address" value={cellular!.address} mono />
          <Fact label="Network" value={modem?.network} />
          <Fact label="Technology" value={modem?.technology} />
          <Fact label="Signal" value={modem?.rssi != null ? `${modem.rssi} dBm` : null} />
        </FactList>
      </Section>

      <Section title="Connection">
        <div className={styles.form}>
          <TextField
            label="APN"
            value={apn}
            onChange={(event) => setApn(event.target.value)}
          />
          <CheckboxField
            label="Use cellular as a backhaul"
            checked={enabled}
            onChange={(event) => setEnabled(event.target.checked)}
          />
        </div>

        {apply.isError && <Notice tone="error">{(apply.error as Error).message}</Notice>}
        {apply.isSuccess && <Notice tone="success">Applied. The modem is re-attaching.</Notice>}

        <div className={styles.actions}>
          <Button variant="primary" loading={apply.isPending} onClick={() => apply.mutate()}>
            Apply
          </Button>
        </div>
      </Section>
    </div>
  );
}
