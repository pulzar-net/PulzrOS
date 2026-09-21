import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { Link } from 'react-router-dom';
import { Antenna, Route, RotateCw, Server } from 'lucide-react';
import { api } from '@/services/api';
import type { LorawanStatus } from '@/types';
import Card from '@/components/ui/Card';
import { StatusBadge } from '@/components/ui/Badge';
import Fact, { FactList } from '@/components/Fact';
import Metric, { MetricGrid } from '@/components/Metric';
import Notice from '@/components/ui/Notice';
import { CheckboxField } from '@/components/ui/Field';
import Button from '@/components/ui/Button';
import PageHeader from '@/components/PageHeader';
import Spinner from '@/components/ui/Spinner';
import ErrorState from '@/components/ErrorState';
import GpsCard from '@/components/GpsCard';
import { bytes, count } from '@/lib/format';

/**
 * The radio side: what it is hearing and whether any of it is getting out.
 *
 * Received and forwarded are shown separately and never summed. They answer
 * different questions with different fixes — nothing heard means antenna,
 * region plan, or a concentrator that never initialised; heard but not
 * forwarded means backhaul, bridge credentials, or the multiplexer. A single
 * "packets" number gets those diagnosed as each other.
 *
 * Hardware configuration lives on its own page: this one is for an operator
 * asking "is it working", which is a different visit from "what is fitted".
 */
export default function Lorawan() {
  const queryClient = useQueryClient();

  const status = useQuery({
    queryKey: ['lorawan-status'],
    queryFn: () => api.get<LorawanStatus>('/lorawan/status'),
    refetchInterval: 10_000,
  });

  const restart = useMutation({
    mutationFn: () => api.post('/lorawan/restart'),
    onSuccess: () =>
      setTimeout(() => queryClient.invalidateQueries({ queryKey: ['lorawan-status'] }), 3000),
  });

  // One endpoint for both settings: they are the same decision seen from two
  // sides, and changing one without seeing the other is how a gateway ends up
  // silently dropping uplinks.
  const setBackhaul = useMutation({
    mutationFn: (body: { allowCellular?: boolean; buffer?: boolean }) =>
      api.post('/lorawan/backhaul', body),
    onSuccess: () =>
      // Delayed, because turning holding on restarts the forwarder and an
      // immediate refetch would read the state it is on its way out of.
      setTimeout(() => queryClient.invalidateQueries({ queryKey: ['lorawan-status'] }), 3000),
  });

  if (status.isLoading) return <Spinner label="Reading radio state" />;
  if (status.isError) return <ErrorState error={status.error} onRetry={status.refetch} />;

  const lora = status.data!;
  const { forwarder, concentrator, bridge, backhaul, buffer } = lora;

  // Heard but not delivered. Worth calling out explicitly, because the counts
  // alone read as "it is working" right up until you notice one is zero.
  const deaf = (forwarder.received ?? 0) === 0 && forwarder.running;
  const stuck = (forwarder.received ?? 0) > 0 && (forwarder.forwarded ?? 0) === 0;

  // Confined to wired, with wired down. Whether that is a pause or a loss is
  // the whole reason holding is a separate setting, so the two are not shown
  // as one warning.
  const confined = backhaul != null && !backhaul.sending;
  const held = confined && (buffer?.enabled ?? false);
  const dropping = confined && !(buffer?.enabled ?? false);

  // Holding is switched on and no broker is running. The forwarder is then
  // publishing at a loopback port with nothing behind it, so every uplink is
  // lost — and nothing else on this page looks wrong, which is exactly how it
  // got missed on a live gateway. It is its own alarm.
  const brokerMissing = (buffer?.enabled ?? false) && !(buffer?.running ?? false);

  return (
    <div className="fade-in">
      <PageHeader
        title="LoRaWAN"
        actions={
          <Button loading={restart.isPending} onClick={() => restart.mutate()}>
            <RotateCw size={14} strokeWidth={2} />
            Restart forwarder
          </Button>
        }
      />

      {!forwarder.running && (
        <Notice tone="error">
          The packet forwarder is not running, so this gateway is not hearing
          anything. If the concentrator is detected, the log will say why it
          would not start.
        </Notice>
      )}

      {stuck && (
        <Notice tone="warning">
          Uplinks are being heard but none are being forwarded. The radio is
          fine — this is the backhaul, the bridge credentials, or the
          multiplexer on a multi-concentrator gateway.
        </Notice>
      )}

      {deaf && (
        <Notice tone="warning">
          The forwarder is running but has heard nothing. Check the antenna, the
          region plan, and the concentrator on the{' '}
          <Link to="/hardware">hardware page</Link>.
        </Notice>
      )}

      <MetricGrid>
        <Metric
          label="Received"
          value={count(forwarder.received)}
          meta="Uplinks heard by the radio"
          tone={deaf ? 'warning' : 'default'}
        />
        <Metric
          label="Forwarded"
          value={count(forwarder.forwarded)}
          meta="Delivered to the network server"
          tone={stuck ? 'warning' : 'default'}
        />
        <Metric
          label="Transmitted"
          value={count(forwarder.transmitted)}
          meta="Downlinks sent"
        />
        <Metric
          label="CRC valid"
          value={forwarder.crcOkPercent != null ? `${forwarder.crcOkPercent}%` : '—'}
          meta="Of what was heard. A low figure is interference or a bad antenna."
        />
      </MetricGrid>

      <Card title="Packet forwarder" icon={Antenna}>
        <FactList>
          <Fact label="State" value={<StatusBadge ok={forwarder.running} okLabel="Running" badLabel="Stopped" />} />
          <Fact label="Gateway EUI" value={lora.gatewayEui} mono />
          <Fact label="Region" value={lora.region} />
          <Fact label="Channels" value={concentrator.channels} />
          <Fact
            label="Concentrators"
            value={`${concentrator.present} of ${concentrator.slots}`}
          />
          <Fact label="Last uplink" value={forwarder.lastUplink} />
        </FactList>
      </Card>

      <GpsCard />

      <Card title="Network server" icon={Server}>
        <FactList>
          <Fact
            label="Bridge"
            value={<StatusBadge ok={bridge.connected} okLabel="Connected" badLabel="Not connected" />}
          />
          <Fact label="Broker" value={bridge.broker} mono />
        </FactList>
      </Card>

      {backhaul && (
        <Card title="Uplink backhaul" icon={Route}>
          {brokerMissing && (
            <Notice tone="error">
              Holding is switched on but the local broker is not running, so
              uplinks are being published to a port with nothing behind it and
              are being lost. Turn holding off until this is resolved. The log
              will name the reason.
            </Notice>
          )}

          {held && !brokerMissing && (
            <Notice tone="warning">
              Wired is down and uplinks are not allowed onto cellular, so they
              are being held on the gateway. They go out when ethernet returns.
            </Notice>
          )}

          {dropping && (
            <Notice tone="error">
              Wired is down, uplinks are not allowed onto cellular, and nothing
              is holding them — so they are being dropped. Turn on holding
              below, or allow cellular.
            </Notice>
          )}

          <FactList>
            <Fact
              label="Sending"
              value={
                <StatusBadge
                  ok={backhaul.sending}
                  okLabel="Yes"
                  badLabel={buffer?.enabled ? 'Held' : 'No'}
                />
              }
            />
            <Fact
              label="Wired"
              value={<StatusBadge ok={backhaul.wiredUp} okLabel="Up" badLabel="Down" />}
            />
            {buffer?.enabled && (
              <Fact
                label="Queued"
                value={buffer.persistent ? bytes(buffer.queuedBytes) : 'In memory'}
              />
            )}
            {buffer?.enabled && (
              <Fact
                label="Local broker"
                value={<StatusBadge ok={buffer.running} okLabel={`Running on ${buffer.port}`} badLabel="Not running" />}
              />
            )}
          </FactList>

          <CheckboxField
            label="Allow uplinks over cellular"
            checked={backhaul.allowCellular}
            disabled={setBackhaul.isPending}
            onChange={(e) => setBackhaul.mutate({ allowCellular: e.target.checked })}
            hint="A busy site can produce uplinks continuously, and how many is set by
                  what is in range rather than by anything here. Turn this off where the
                  data plan matters more than the delay."
          />

          <CheckboxField
            label="Hold uplinks that cannot be sent"
            checked={buffer?.enabled ?? false}
            disabled={setBackhaul.isPending}
            onChange={(e) => setBackhaul.mutate({ buffer: e.target.checked })}
            hint={
              buffer?.persistent
                ? 'Held on the SD card, so the queue survives a reboot. Restarts the forwarder.'
                : 'Held in memory and lost on reboot — fit an SD card for a queue that survives one. Restarts the forwarder.'
            }
          />
        </Card>
      )}
    </div>
  );
}
