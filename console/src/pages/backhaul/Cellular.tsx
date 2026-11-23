import { useEffect, useState } from 'react';
import { CreditCard, SignalHigh } from 'lucide-react';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { api } from '@/services/api';
import type { NetworkStatus, SimSlot } from '@/types';
import Section from '@/components/ui/Section';
import Badge, { StatusBadge } from '@/components/ui/Badge';
import Fact, { FactList } from '@/components/Fact';
import Notice from '@/components/ui/Notice';
import Button from '@/components/ui/Button';
import { CheckboxField, TextField } from '@/components/ui/Field';
import Spinner from '@/components/ui/Spinner';
import ErrorState from '@/components/ErrorState';
import ApplyChangeNotice from '@/components/ApplyChangeNotice';
import { useApplyChange, type Pending } from '@/hooks/useApplyChange';
import { addressList, modemKind } from '@/lib/format';
import styles from '../Pages.module.css';

/**
 * The metered uplink.
 *
 * Only the APN and the on/off switch are exposed. Everything else about a 1NCE
 * SIM is fixed by the carrier, and a console offering to change the PDP type is
 * a console offering a way to strand a gateway that is only reachable over it.
 *
 * A modem with more than one SIM holder lists them, and one can be made the
 * one in use. Applied like the rest: a SIM that cannot attach cuts off a
 * gateway reached over it, and the old slot comes back unless this page
 * reaches the gateway again.
 */
export default function Cellular() {
  const queryClient = useQueryClient();
  const change = useApplyChange();
  const network = useQuery({
    queryKey: ['network-status'],
    queryFn: () => api.get<NetworkStatus>('/network/status'),
  });

  const cellular = network.data?.cellular;
  // A HiLink dongle or a phone sets its own APN; this one is the modem's.
  const usbEthernet = cellular?.modem?.kind === 'hilink' || cellular?.modem?.kind === 'tether';
  const [apn, setApn] = useState('');
  const [enabled, setEnabled] = useState(false);

  // Re-sync when a refetch brings different values, so an APN changed from
  // Pulzr Cloud does not sit invisibly behind a stale local edit.
  useEffect(() => {
    if (!cellular) return;
    setApn(cellular.apn ?? '');
    setEnabled(cellular.enabled);
  }, [cellular?.apn, cellular?.enabled]); // eslint-disable-line react-hooks/exhaustive-deps

  const apply = useMutation({
    mutationFn: () =>
      api.post<{ pending?: Pending }>('/network/cellular', { apn: usbEthernet ? undefined : apn.trim(), enabled }),
    onSuccess: (answer) => {
      change.watch(answer.pending);
      queryClient.invalidateQueries({ queryKey: ['network-status'] });
      queryClient.invalidateQueries({ queryKey: ['backhaul'] });
    },
  });

  if (network.isLoading) return <Spinner label="Reading network state" />;
  if (network.isError) return <ErrorState error={network.error} onRetry={network.refetch} />;

  const modem = cellular!.modem;
  const slots = modem?.slots && modem.slots.length > 1 ? modem.slots : null;

  return (
    <div className="fade-in">
      <ApplyChangeNotice change={change} />
      <Section>
        <FactList>
          <Fact label="State" value={<StatusBadge ok={cellular!.up === true} />} />
          <Fact label="Adapter" value={modemKind(modem?.kind)} />
          <Fact label="Model" value={modem?.model} />
          <Fact label="Address" value={addressList(cellular)} mono />
          <Fact label="Network" value={modem?.network} />
          <Fact label="Technology" value={modem?.technology} />
          <Fact label="Signal" value={modem?.rssi != null ? `${modem.rssi} dBm` : null} />
        </FactList>
      </Section>

      {slots && (
        <Slots
          slots={slots}
          disabled={change.applying || change.phase === 'confirming'}
          onUse={(slot) => change.apply('/network/cellular/slot', { slot })}
        />
      )}

      <Section title="Connection" icon={SignalHigh}>
        <div className={styles.form}>
          {!usbEthernet && (
            <TextField
              label="APN"
              value={apn}
              onChange={(event) => setApn(event.target.value)}
            />
          )}
          <CheckboxField
            label="Use cellular as a backhaul"
            checked={enabled}
            onChange={(event) => setEnabled(event.target.checked)}
          />
        </div>

        {apply.isError && <Notice tone="error">{(apply.error as Error).message}</Notice>}

        <div className={styles.actions}>
          <Button variant="primary" loading={apply.isPending} onClick={() => apply.mutate()}>
            Apply
          </Button>
        </div>
      </Section>
    </div>
  );
}

function Slots({ slots, disabled, onUse }: { slots: SimSlot[]; disabled: boolean; onUse: (slot: number) => void }) {
  return (
    <Section title="SIM" icon={CreditCard}>
      <FactList>
        {slots.map((s) => (
          <Fact
            key={s.slot}
            label={`Slot ${s.slot}`}
            value={
              <span className={styles.status}>
                {s.present ? <span className="mono">{s.iccid || 'SIM'}</span> : <span className={styles.dim}>Empty</span>}
                {s.active ? (
                  <Badge tone="success">In use</Badge>
                ) : (
                  <Button disabled={disabled || !s.present} onClick={() => onUse(s.slot)}>Use</Button>
                )}
              </span>
            }
          />
        ))}
      </FactList>
    </Section>
  );
}
