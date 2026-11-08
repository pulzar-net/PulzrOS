import { useEffect, useState } from 'react';
import { Inbox, Map } from 'lucide-react';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { api } from '@/services/api';
import type { ConcentratorView, LorawanStatus } from '@/types';
import Section from '@/components/ui/Section';
import { StatusBadge } from '@/components/ui/Badge';
import Fact, { FactList } from '@/components/Fact';
import Notice from '@/components/ui/Notice';
import Button from '@/components/ui/Button';
import { CheckboxField, SelectField } from '@/components/ui/Field';
import Spinner from '@/components/ui/Spinner';
import ErrorState from '@/components/ErrorState';
import { bytes } from '@/lib/format';
import styles from '../Pages.module.css';

const REGIONS = ['US915', 'EU868', 'AU915', 'AS923', 'IN865', 'KR920', 'RU864'];

/**
 * What applies to every forwarder: the region plan, and how uplinks leave the
 * gateway when the wired backhaul is down.
 */
export default function Settings() {
  const status = useQuery({
    queryKey: ['lorawan-status'],
    queryFn: () => api.get<LorawanStatus>('/lorawan/status'),
    refetchInterval: 15_000,
  });
  const concentrator = useQuery({
    queryKey: ['concentrator'],
    queryFn: () => api.get<ConcentratorView>('/lorawan/concentrator'),
  });

  if (status.isLoading || concentrator.isLoading) return <Spinner label="Reading LoRaWAN settings" />;
  if (status.isError) return <ErrorState error={status.error} onRetry={status.refetch} />;
  if (concentrator.isError) {
    return <ErrorState error={concentrator.error} onRetry={concentrator.refetch} />;
  }

  return (
    <div className="fade-in">
      <Region region={concentrator.data!.region} onSaved={() => concentrator.refetch()} />
      {status.data!.backhaul && <Delivery lora={status.data!} />}
    </div>
  );
}

function Region({ region, onSaved }: { region: string; onSaved: () => void }) {
  const [value, setValue] = useState(region);
  useEffect(() => setValue(region), [region]);

  const save = useMutation({
    mutationFn: () => api.post('/lorawan/concentrator', { region: value }),
    onSuccess: onSaved,
  });

  return (
    <Section title="Region Plan" icon={Map}>
      <div className={styles.form}>
        <SelectField
          label="Region"
          value={value}
          onChange={setValue}
          options={REGIONS.map((option) => ({ value: option, label: option }))}
        />
      </div>

      {save.isError && <Notice tone="error">{(save.error as Error).message}</Notice>}
      {save.isSuccess && <Notice tone="success">Applied. The forwarders are restarting.</Notice>}

      <div className={styles.actions}>
        <Button variant="primary" disabled={value === region} loading={save.isPending}
                onClick={() => save.mutate()}>
          Apply and restart
        </Button>
      </div>
    </Section>
  );
}

/**
 * Whether uplinks may use the metered link, and whether they are held when
 * they cannot be sent. One endpoint for both: they are the same decision seen
 * from two sides, and changing one without seeing the other is how a gateway
 * ends up silently dropping uplinks.
 */
function Delivery({ lora }: { lora: LorawanStatus }) {
  const queryClient = useQueryClient();
  const backhaul = lora.backhaul!;
  const buffer = lora.buffer;

  const save = useMutation({
    mutationFn: (body: { allowCellular?: boolean; buffer?: boolean }) =>
      api.post('/lorawan/backhaul', body),
    onSuccess: () =>
      // Delayed: turning holding on restarts the forwarders, and an immediate
      // refetch would read the state they are on their way out of.
      setTimeout(() => queryClient.invalidateQueries({ queryKey: ['lorawan-status'] }), 3000),
  });

  // Confined to the free links — wired and WiFi — with both down. Whether
  // that is a pause or a loss is the whole reason holding is a separate
  // setting.
  const confined = !backhaul.sending;
  // Holding needs both the setting and an SD card to keep the queue on;
  // without a card the buffer does not run and uplinks go straight out.
  const wanted = buffer?.enabled ?? false;
  const holding = wanted && (buffer?.persistent ?? false);
  // Holding on with no broker running: the forwarders publish to a port with
  // nothing behind it and every uplink is lost, while nothing else looks wrong.
  const brokerMissing = holding && !(buffer?.running ?? false);

  return (
    <Section title="Uplink Delivery" icon={Inbox}>
      {wanted && !holding && (
        <Notice tone="warning">No SD card. Uplinks are not being held.</Notice>
      )}
      {brokerMissing && (
        <Notice tone="error">
          Holding is on and the local broker is not running. Uplinks are being lost.
        </Notice>
      )}
      {confined && holding && !brokerMissing && (
        <Notice tone="warning">
          Wired and WiFi are down. Uplinks are being held.
        </Notice>
      )}
      {confined && !holding && (
        <Notice tone="error">
          Wired and WiFi are down. Uplinks are being dropped.
        </Notice>
      )}

      <FactList>
        <Fact
          label="Sending"
          value={<StatusBadge ok={backhaul.sending} okLabel="Yes" badLabel={holding ? 'Held' : 'No'} />}
        />
        <Fact label="Wired" value={<StatusBadge ok={backhaul.wiredUp} />} />
        {backhaul.wifiUp !== undefined && (
          <Fact label="WiFi" value={<StatusBadge ok={backhaul.wifiUp} />} />
        )}
        {holding && (
          <Fact label="Queued" value={bytes(buffer!.queuedBytes)} />
        )}
        {holding && (
          <Fact
            label="Local broker"
            value={
              <StatusBadge ok={buffer!.running} okLabel={`Running on ${buffer!.port}`} badLabel="Not running" />
            }
          />
        )}
      </FactList>

      <div className={styles.options}>
        <CheckboxField
          label="Allow uplinks over cellular"
          checked={backhaul.allowCellular}
          disabled={save.isPending}
          onChange={(e) => save.mutate({ allowCellular: e.target.checked })}
        />
        <CheckboxField
          label="Hold uplinks that cannot be sent"
          checked={wanted}
          disabled={save.isPending}
          onChange={(e) => save.mutate({ buffer: e.target.checked })}
        />
      </div>
    </Section>
  );
}
