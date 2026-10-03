import { useEffect, useState } from 'react';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { Cpu, Lock, RotateCw } from 'lucide-react';
import { api } from '@/services/api';
import type { ConcentratorView, Slot } from '@/types';
import Card from '@/components/ui/Card';
import Badge from '@/components/ui/Badge';
import Fact, { FactList } from '@/components/Fact';
import Notice from '@/components/ui/Notice';
import Button from '@/components/ui/Button';
import { SelectField, TextField } from '@/components/ui/Field';
import type { SelectOption } from '@/components/ui/Select';
import PageHeader from '@/components/PageHeader';
import Spinner from '@/components/ui/Spinner';
import ErrorState from '@/components/ErrorState';
import styles from './Pages.module.css';

const REGIONS = ['US915', 'EU868', 'AU915', 'AS923', 'IN865', 'KR920', 'RU864'];

const BUSES: SelectOption<Slot['bus']>[] = [
  { value: '', label: 'Automatic' },
  { value: 'spi', label: 'SPI' },
  { value: 'usb', label: 'USB' },
  { value: 'uart', label: 'UART' },
];

/**
 * Concentrator hardware, one card per slot.
 *
 * A slot is one SX130x and the eight channels it carries. Most gateways have
 * one; a RAK7289CV2 has two. Rendering per-slot rather than as a single
 * "concentrator" is what makes a 16-channel unit legible — and it is the only
 * way a half-working one is visible at all, since eight channels of sixteen
 * looks perfectly healthy from an uplink count.
 *
 * Whether any of this is editable comes from the device. On a Pi it is: the
 * hardware is a kit, the bus and the reset GPIO genuinely vary between HATs,
 * and a rebuild to correct a wrong guess would be absurd. On a RAK unit it is
 * not: the hardware is soldered down, so an editable bus field is only ever a
 * way to break a working gateway.
 */
export default function Hardware() {
  const queryClient = useQueryClient();

  const concentrator = useQuery({
    queryKey: ['concentrator'],
    queryFn: () => api.get<ConcentratorView>('/lorawan/concentrator'),
  });

  const redetect = useMutation({
    mutationFn: () => api.post('/lorawan/detect'),
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ['concentrator'] }),
  });

  if (concentrator.isLoading) return <Spinner label="Reading concentrator state" />;
  if (concentrator.isError) {
    return <ErrorState error={concentrator.error} onRetry={concentrator.refetch} />;
  }

  const view = concentrator.data!;

  return (
    <div className="fade-in">
      <PageHeader
        title="Concentrator hardware"
        actions={
          <Button loading={redetect.isPending} onClick={() => redetect.mutate()}>
            <RotateCw size={14} strokeWidth={2} />
            Re-detect
          </Button>
        }
      />

      {!view.configurable && (
        <Notice tone="info">
          <Lock size={12} strokeWidth={2} style={{ verticalAlign: '-1px' }} /> This
          board&rsquo;s concentrators are fixed in hardware, so they are shown
          but not editable. Nothing here can change without changing the board.
        </Notice>
      )}

      {view.status === 'partial' && (
        <Notice tone="warning">
          {view.presentCount} of {view.slotCount} concentrators responded. The
          gateway works at {view.channels} channels — check the slot marked
          absent below, and its reset line first.
        </Notice>
      )}

      {view.status === 'absent' && (
        <Notice tone="error">
          No concentrator responded on any slot. This gateway hears nothing.
        </Notice>
      )}

      <RegionCard region={view.region} onSaved={() => concentrator.refetch()} />

      {view.slots.map((slot) => (
        <SlotCard
          key={slot.index}
          slot={slot}
          view={view}
          onSaved={() => concentrator.refetch()}
        />
      ))}
    </div>
  );
}

function RegionCard({ region, onSaved }: { region: string; onSaved: () => void }) {
  const [value, setValue] = useState(region);
  useEffect(() => setValue(region), [region]);

  const save = useMutation({
    mutationFn: () => api.post('/lorawan/concentrator', { region: value }),
    onSuccess: onSaved,
  });

  return (
    <Card title="Region plan" icon={Cpu}>
      <SelectField
        label="Region"
        value={value}
        onChange={setValue}
        options={REGIONS.map((option) => ({ value: option, label: option }))}
        hint="Must match the regulatory region this gateway is installed in. Applies to every slot."
      />

      {save.isError && <Notice tone="error">{(save.error as Error).message}</Notice>}
      {save.isSuccess && (
        <Notice tone="success">Applied. The packet forwarder is restarting.</Notice>
      )}

      <div className={styles.actions}>
        <Button
          variant="primary"
          disabled={value === region}
          loading={save.isPending}
          onClick={() => save.mutate()}
        >
          Apply and restart
        </Button>
      </div>
    </Card>
  );
}

function SlotCard({
  slot,
  view,
  onSaved,
}: {
  slot: Slot;
  view: ConcentratorView;
  onSaved: () => void;
}) {
  const [override, setOverride] = useState(slot.override ?? '');
  const [bus, setBus] = useState(slot.bus);
  const [device, setDevice] = useState(slot.device);
  const [resetGpio, setResetGpio] = useState(slot.resetGpioOverride);

  useEffect(() => {
    setOverride(slot.override ?? '');
    setBus(slot.bus);
    setDevice(slot.device);
    setResetGpio(slot.resetGpioOverride);
  }, [slot.override, slot.bus, slot.device, slot.resetGpioOverride]);

  const save = useMutation({
    mutationFn: () =>
      api.post(`/lorawan/slots/${slot.index}`, {
        override,
        bus,
        device,
        resetGpio,
      }),
    onSuccess: onSaved,
  });

  const tone =
    slot.status === 'present' ? 'success' : slot.status === 'absent' ? 'error' : 'warning';

  return (
    <Card
      title={view.slotCount > 1 ? `Slot ${slot.index}` : 'Concentrator'}
      icon={Cpu}
      note={<Badge tone={tone}>{slot.status}</Badge>}
    >
      {slot.mismatch && (
        <Notice tone="warning">
          You selected {slot.override}, but the hardware looks like{' '}
          {slot.detected}. That is legitimate for a UART part or to work around
          a bad probe — but it is the first thing to suspect if this slot hears
          nothing.
        </Notice>
      )}

      <FactList>
        <Fact label="Detected" value={slot.detected} />
        <Fact label="Active" value={slot.active} />
        <Fact label="Chip" value={slot.profile?.chip} />
        <Fact label="Channels" value={slot.profile?.channels ?? slot.channels} />
        <Fact label="Also sold as" value={slot.profile?.known_as?.join(', ')} />
        {slot.bus === 'spi' && (
          <Fact label="Reset GPIO used" value={slot.resetGpio || 'not probed yet'} mono />
        )}
      </FactList>

      {view.configurable && (
        <>
          <div className={styles.divider} />

          <SelectField
            label="Part"
            value={override}
            onChange={setOverride}
            options={[
              { value: '', label: 'Automatic — use what is detected' },
              ...view.supported.map((part) => ({
                value: part.id,
                label: part.detectable ? part.name : `${part.name} — manual only`,
              })),
            ]}
            hint="Automatic uses whatever the probe finds. Choose a part explicitly only if the probe gets it wrong, or for a UART concentrator, which cannot be detected."
          />

          <SelectField
            label="Bus"
            value={bus}
            onChange={setBus}
            options={BUSES}
          />

          <TextField
            label="Device"
            mono
            value={device}
            placeholder="/dev/spidev0.0"
            onChange={(event) => setDevice(event.target.value)}
            hint="The device node this concentrator answers on. Left blank, detection picks one."
          />

          <TextField
            label="Reset GPIO override"
            mono
            value={resetGpio}
            placeholder="Use the part's own pin"
            onChange={(event) => setResetGpio(event.target.value)}
            hint="Only for a HAT this list has no part for, or to correct one whose pins are wrong. Leave blank to use the pin the selected part declares."
          />

          {save.isError && <Notice tone="error">{(save.error as Error).message}</Notice>}
          {save.isSuccess && (
            <Notice tone="success">Applied. Re-detecting and restarting.</Notice>
          )}

          <div className={styles.actions}>
            <Button variant="primary" loading={save.isPending} onClick={() => save.mutate()}>
              Apply and restart
            </Button>
          </div>
        </>
      )}
    </Card>
  );
}
