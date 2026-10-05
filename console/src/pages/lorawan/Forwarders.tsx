import { useEffect, useState } from 'react';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { Navigate, useParams } from 'react-router-dom';
import { RotateCw } from 'lucide-react';
import { api } from '@/services/api';
import type { ConcentratorView, Forwarder, ForwardersView, Slot } from '@/types';
import Section from '@/components/ui/Section';
import Badge, { StatusBadge } from '@/components/ui/Badge';
import Fact, { FactList } from '@/components/Fact';
import Notice from '@/components/ui/Notice';
import Button from '@/components/ui/Button';
import Tabs from '@/components/ui/Tabs';
import { SelectField, TextField } from '@/components/ui/Field';
import type { SelectOption } from '@/components/ui/Select';
import Spinner from '@/components/ui/Spinner';
import ErrorState from '@/components/ErrorState';
import { count } from '@/lib/format';
import styles from '../Pages.module.css';

const SUBTABS = [
  { key: 'status', label: 'Status' },
  { key: 'mqtt', label: 'MQTT' },
  { key: 'gnss', label: 'GNSS' },
  { key: 'concentrator', label: 'Concentrator' },
] as const;

type Subtab = (typeof SUBTABS)[number]['key'];

/**
 * One tab per forwarder: a concentrator slot's concentratord and the MQTT
 * forwarder that carries what it hears. Most gateways have one; a RAK7289CV2
 * has two, and the network server sees each as its own gateway.
 *
 * Numbered from 1 here and in the URL. Slot 0 is the firmware's name for it,
 * and nobody standing at the panel calls it that.
 */
export default function Forwarders() {
  const params = useParams();
  const number = Number(params.forwarder);
  const tab = params.tab as Subtab | undefined;
  const queryClient = useQueryClient();

  const view = useQuery({
    queryKey: ['forwarders'],
    queryFn: () => api.get<ForwardersView>('/lorawan/forwarders'),
    refetchInterval: 10_000,
  });

  const restart = useMutation({
    mutationFn: () => api.post('/lorawan/restart'),
    onSuccess: () =>
      setTimeout(() => queryClient.invalidateQueries({ queryKey: ['forwarders'] }), 4000),
  });

  const redetect = useMutation({
    mutationFn: () => api.post('/lorawan/detect'),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['concentrator'] });
      queryClient.invalidateQueries({ queryKey: ['forwarders'] });
    },
  });

  if (view.isLoading) return <Spinner label="Reading the forwarders" />;
  if (view.isError) return <ErrorState error={view.error} onRetry={view.refetch} />;

  const data = view.data!;
  const forwarder = data.forwarders[number - 1];
  if (!forwarder || !SUBTABS.some((entry) => entry.key === tab)) {
    return <Navigate to="/lorawan/forwarders/1/status" replace />;
  }

  const base = `/lorawan/forwarders/${number}`;

  return (
    <div className="fade-in">
      <Tabs
        tabs={data.forwarders.map((entry) => ({
          to: `/lorawan/forwarders/${entry.index + 1}/${tab}`,
          label: (
            <>
              Forwarder {entry.index + 1}
              <StateDot forwarder={entry} />
            </>
          ),
        }))}
        actions={
          <Button loading={restart.isPending} onClick={() => restart.mutate()}>
            <RotateCw size={14} strokeWidth={2} />
            Restart
          </Button>
        }
      />

      <Tabs
        variant="secondary"
        tabs={SUBTABS.map((entry) => ({ to: `${base}/${entry.key}`, label: entry.label }))}
        actions={
          tab === 'concentrator' && (
            <Button loading={redetect.isPending} onClick={() => redetect.mutate()}>
              <RotateCw size={14} strokeWidth={2} />
              Re-detect
            </Button>
          )
        }
      />

      {tab === 'status' && <Status forwarder={forwarder} />}
      {tab === 'mqtt' && <Mqtt forwarder={forwarder} view={data} />}
      {tab === 'gnss' && <Gnss forwarder={forwarder} view={data} />}
      {tab === 'concentrator' && <Concentrator slot={forwarder.slot} />}
    </div>
  );
}

/** Green running, amber running without forwarding, red stopped, grey absent. */
function StateDot({ forwarder }: { forwarder: Forwarder }) {
  const tone =
    forwarder.slot.status !== 'present'
      ? 'var(--text-tertiary)'
      : !forwarder.running
        ? 'var(--status-error)'
        : forwarder.mqtt !== 'connected'
          ? 'var(--status-warning)'
          : 'var(--status-success)';
  return <span className={styles.dot} style={{ background: tone }} aria-hidden />;
}

function Status({ forwarder }: { forwarder: Forwarder }) {
  const stats = forwarder.stats;
  const absent = forwarder.slot.status !== 'present';
  // Heard nothing, or heard and delivered nothing: two different faults that
  // look alike from a single count, so each gets its own line.
  const deaf = forwarder.running && (stats?.received ?? 0) === 0;
  const stuck = (stats?.received ?? 0) > 0 && (stats?.forwarded ?? 0) === 0;

  return (
    <>
      {absent && (
        <Notice tone="warning">
          Concentrator {forwarder.index + 1} did not respond.
        </Notice>
      )}
      {!absent && !forwarder.running && (
        <Notice tone="error">
          Concentratord is not running.
        </Notice>
      )}
      {deaf && (
        <Notice tone="warning">
          Nothing heard.
        </Notice>
      )}
      {stuck && (
        <Notice tone="warning">
          Hearing uplinks, forwarding none.
        </Notice>
      )}

      <Section>
        <FactList>
          <Fact
            label="Concentratord"
            value={<StatusBadge ok={forwarder.running} okLabel="Running" badLabel="Stopped" />}
          />
          <Fact
            label="MQTT forwarder"
            value={<StatusBadge ok={forwarder.forwarding} okLabel="Running" badLabel="Stopped" />}
          />
          <Fact label="Gateway ID" value={forwarder.gatewayId ?? 'From the chip'} mono />
          <Fact label="Channels" value={forwarder.slot.profile?.channels ?? forwarder.slot.channels} />
          <Fact label="Uplinks heard" value={stats ? count(stats.received) : null} />
          <Fact label="Uplinks forwarded" value={stats ? count(stats.forwarded) : null} />
          <Fact label="Downlinks sent" value={stats ? count(stats.transmitted) : null} />
          <Fact label="CRC valid" value={stats ? `${stats.crcOkPercent}%` : null} />
          <Fact label="Last uplink" value={stats?.lastUplink} />
        </FactList>
      </Section>
    </>
  );
}

function Mqtt({ forwarder, view }: { forwarder: Forwarder; view: ForwardersView }) {
  const mqtt = view.mqtt;
  if (!mqtt.host) {
    return (
      <Notice tone="info">
        Not adopted, so no broker.
      </Notice>
    );
  }

  const upstream = `ssl://${mqtt.host}:${mqtt.port}`;

  return (
    <Section>
      <FactList>
        <Fact
          label="Connection"
          value={
            forwarder.mqtt == null ? null : (
              <StatusBadge
                ok={forwarder.mqtt === 'connected'}
                okLabel="Connected"
                badLabel="Not connected"
              />
            )
          }
        />
        <Fact
          label="Publishes to"
          value={mqtt.buffered ? 'Local buffer' : upstream}
          mono={!mqtt.buffered}
        />
        {mqtt.buffered && <Fact label="LNS broker" value={upstream} mono />}
        <Fact label="Topic prefix" value={mqtt.topicPrefix} mono />
        <Fact label="Username" value={mqtt.username} mono />
        <Fact label="TLS" value="System CA bundle" />
      </FactList>
    </Section>
  );
}

function Gnss({ forwarder, view }: { forwarder: Forwarder; view: ForwardersView }) {
  const location = view.location;

  return (
    <Section>
      <FactList>
        <Fact
          label="Receiver"
          value={
            forwarder.gnss.attached ? (
              <span className="mono">{forwarder.gnss.device}</span>
            ) : (
              <Badge tone="neutral">None</Badge>
            )
          }
        />
        <Fact
          label="Timing"
          value={forwarder.gnss.attached ? 'GPS time and PPS' : 'Gateway clock'}
        />
        <Fact
          label="Reports"
          value={forwarder.gnss.attached ? 'The receiver’s position' : 'The recorded position'}
        />
        {!forwarder.gnss.attached && (
          <Fact
            label="Recorded position"
            value={
              location.latitude && location.longitude
                ? `${location.latitude}, ${location.longitude}`
                : null
            }
            mono
          />
        )}
        {!forwarder.gnss.attached && <Fact label="Recorded from" value={location.source} />}
      </FactList>
    </Section>
  );
}

const BUSES: SelectOption<Slot['bus']>[] = [
  { value: '', label: 'Automatic' },
  { value: 'spi', label: 'SPI' },
  { value: 'usb', label: 'USB' },
  { value: 'uart', label: 'UART' },
];

/**
 * The slot's hardware.
 *
 * Editable only where the device says it is. On a Pi the hardware is a kit and
 * the bus and reset GPIO genuinely vary between HATs. On a RAK unit it is
 * soldered down, so an editable bus is only ever a way to break a working
 * gateway.
 */
function Concentrator({ slot }: { slot: Slot }) {
  const queryClient = useQueryClient();
  const concentrator = useQuery({
    queryKey: ['concentrator'],
    queryFn: () => api.get<ConcentratorView>('/lorawan/concentrator'),
  });

  const [override, setOverride] = useState(slot.override ?? '');
  const [bus, setBus] = useState(slot.bus);
  const [device, setDevice] = useState(slot.device);
  const [resetGpio, setResetGpio] = useState(slot.resetGpioOverride);

  useEffect(() => {
    setOverride(slot.override ?? '');
    setBus(slot.bus);
    setDevice(slot.device);
    setResetGpio(slot.resetGpioOverride);
  }, [slot.index, slot.override, slot.bus, slot.device, slot.resetGpioOverride]);

  const refresh = () => {
    queryClient.invalidateQueries({ queryKey: ['concentrator'] });
    queryClient.invalidateQueries({ queryKey: ['forwarders'] });
  };

  const save = useMutation({
    mutationFn: () =>
      api.post(`/lorawan/slots/${slot.index}`, { override, bus, device, resetGpio }),
    onSuccess: refresh,
  });

  const configurable = concentrator.data?.configurable ?? false;
  const tone =
    slot.status === 'present' ? 'success' : slot.status === 'absent' ? 'error' : 'warning';

  return (
    <>
      {slot.mismatch && (
        <Notice tone="warning">
          Set to {slot.override}; detected {slot.detected}.
        </Notice>
      )}

      <Section>
        <FactList>
          <Fact label="State" value={<Badge tone={tone}>{slot.status}</Badge>} />
          <Fact label="Device" value={slot.device} mono />
          <Fact label="Detected" value={slot.detected} />
          <Fact label="Active" value={slot.active} />
          <Fact label="Chip" value={slot.profile?.chip} />
          <Fact label="Also sold as" value={slot.profile?.known_as?.join(', ')} />
          {slot.bus === 'spi' && (
            <Fact label="Reset GPIO" value={slot.resetGpio || 'Not probed yet'} mono />
          )}
        </FactList>
      </Section>

      {configurable && (
        <Section title="Hardware">
          <div className={styles.form}>
            <SelectField
              label="Part"
              value={override}
              onChange={setOverride}
              options={[
                { value: '', label: 'Automatic — use what is detected' },
                ...(concentrator.data?.supported ?? []).map((part) => ({
                  value: part.id,
                  label: part.detectable ? part.name : `${part.name} — manual only`,
                })),
              ]}
            />
            <SelectField label="Bus" value={bus} onChange={setBus} options={BUSES} />
            <TextField
              label="Device"
              mono
              value={device}
              placeholder="/dev/spidev0.0"
              onChange={(event) => setDevice(event.target.value)}
            />
            <TextField
              label="Reset GPIO override"
              mono
              value={resetGpio}
              placeholder="Use the part's own pin"
              onChange={(event) => setResetGpio(event.target.value)}
            />
          </div>

          {save.isError && <Notice tone="error">{(save.error as Error).message}</Notice>}
          {save.isSuccess && <Notice tone="success">Applied. Re-detecting and restarting.</Notice>}

          <div className={styles.actions}>
            <Button variant="primary" loading={save.isPending} onClick={() => save.mutate()}>
              Apply and restart
            </Button>
          </div>
        </Section>
      )}
    </>
  );
}
