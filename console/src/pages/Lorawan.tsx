import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { Link } from 'react-router-dom';
import { Antenna, RotateCw, Server } from 'lucide-react';
import { api } from '@/services/api';
import type { LorawanStatus } from '@/types';
import Card from '@/components/ui/Card';
import { StatusBadge } from '@/components/ui/Badge';
import Fact, { FactList } from '@/components/Fact';
import Metric, { MetricGrid } from '@/components/Metric';
import Notice from '@/components/ui/Notice';
import Button from '@/components/ui/Button';
import PageHeader from '@/components/PageHeader';
import Spinner from '@/components/ui/Spinner';
import ErrorState from '@/components/ErrorState';
import GpsCard from '@/components/GpsCard';
import { count } from '@/lib/format';

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

  if (status.isLoading) return <Spinner label="Reading radio state" />;
  if (status.isError) return <ErrorState error={status.error} onRetry={status.refetch} />;

  const lora = status.data!;
  const { forwarder, concentrator, bridge } = lora;

  // Heard but not delivered. Worth calling out explicitly, because the counts
  // alone read as "it is working" right up until you notice one is zero.
  const deaf = (forwarder.received ?? 0) === 0 && forwarder.running;
  const stuck = (forwarder.received ?? 0) > 0 && (forwarder.forwarded ?? 0) === 0;

  return (
    <div className="fade-in">
      <PageHeader
        title="LoRaWAN"
        subtitle={`${concentrator.channels} channels · ${lora.region ?? '—'}`}
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
    </div>
  );
}
