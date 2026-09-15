import { useQuery } from '@tanstack/react-query';
import { Cpu, Fingerprint, Network, Radio } from 'lucide-react';
import { api } from '@/services/api';
import type { BackhaulStatus, LorawanStatus, SystemSummary } from '@/types';
import Card from '@/components/ui/Card';
import Badge, { StatusBadge } from '@/components/ui/Badge';
import Fact, { FactList } from '@/components/Fact';
import Metric, { MetricGrid } from '@/components/Metric';
import Notice from '@/components/ui/Notice';
import PageHeader from '@/components/PageHeader';
import Spinner from '@/components/ui/Spinner';
import ErrorState from '@/components/ErrorState';
import { count, duration } from '@/lib/format';
import styles from './Pages.module.css';

/**
 * The first screen: is this gateway working, and if not, which half is broken.
 *
 * The two questions are kept separate all the way down the page — a gateway
 * that hears uplinks but cannot deliver them and one that delivers nothing
 * because it hears nothing look identical from a single health light and have
 * completely different fixes.
 */
export default function Overview() {
  const summary = useQuery({
    queryKey: ['system-summary'],
    queryFn: () => api.get<SystemSummary>('/system/summary'),
  });
  const backhaul = useQuery({
    queryKey: ['backhaul'],
    queryFn: () => api.get<BackhaulStatus>('/network/backhaul'),
    refetchInterval: 15_000,
  });
  const lorawan = useQuery({
    queryKey: ['lorawan-status'],
    queryFn: () => api.get<LorawanStatus>('/lorawan/status'),
    refetchInterval: 15_000,
  });

  if (summary.isLoading) return <Spinner label="Reading gateway state" />;
  if (summary.isError) return <ErrorState error={summary.error} onRetry={summary.refetch} />;

  const system = summary.data!;
  const paths = backhaul.data;
  const lora = lorawan.data;

  const manageable = Boolean(
    paths && (paths.tailscale.state === 'Running' || paths.cellular.up),
  );
  const concentrator = lora?.concentrator;
  const partial = concentrator?.status === 'partial';

  return (
    <div className="fade-in">
      <PageHeader title={system.identity.hostname ?? 'Gateway'} />

      {system.identity.serialSource === 'random' && (
        <Notice tone="warning">
          This gateway could not read a hardware serial and generated a random
          one. It will not recognise itself after a reflash — raise this with
          support before deploying it.
        </Notice>
      )}

      {partial && (
        <Notice tone="warning">
          Only {concentrator!.present} of {concentrator!.slots} concentrators
          responded, so this gateway is running at {concentrator!.channels}{' '}
          channels instead of {concentrator!.slots * 8}. It works — but it is
          hearing less than it should, and nothing about the uplink counts makes
          that obvious.
        </Notice>
      )}

      <MetricGrid>
        <Metric
          label="Manageable"
          value={manageable ? 'Yes' : 'No'}
          tone={manageable ? 'default' : 'error'}
          meta={manageable ? 'At least one control path is up' : 'No control path is reachable'}
        />
        <Metric
          label="Channels"
          value={concentrator?.channels ?? '—'}
          tone={partial ? 'warning' : concentrator?.channels ? 'default' : 'error'}
          meta={
            concentrator
              ? `${concentrator.present} of ${concentrator.slots} concentrators`
              : 'No concentrator detected'
          }
        />
        <Metric
          label="Uplinks forwarded"
          value={count(lora?.forwarder.forwarded)}
          meta={lora?.forwarder.running ? 'Packet forwarder running' : 'Packet forwarder stopped'}
        />
        <Metric
          label="Uptime"
          value={duration(system.health.uptime)}
          meta={
            system.health.temperature != null
              ? `${system.health.temperature.toFixed(1)} °C`
              : undefined
          }
        />
      </MetricGrid>

      {/* The two control paths, side by side and never merged into one light.
          They fail independently, and one of them costs money. */}
      <div className={styles.grid2}>
        <Card title="Wired · Tailscale" icon={Network}>
          <FactList>
            <Fact label="Ethernet" value={<StatusBadge ok={Boolean(paths?.wired.up)} />} />
            <Fact
              label="Tailscale"
              value={
                <StatusBadge
                  ok={paths?.tailscale.state === 'Running'}
                  okLabel="Connected"
                  badLabel={paths?.tailscale.state ?? 'Offline'}
                />
              }
            />
            <Fact label="Address" value={paths?.tailscale.self?.addresses?.[0]} mono />
          </FactList>
        </Card>

        <Card title="Cellular · 1NCE" icon={Radio}>
          <FactList>
            <Fact
              label="Modem"
              value={
                <StatusBadge
                  ok={Boolean(paths?.cellular.modem)}
                  okLabel="Present"
                  badLabel="Absent"
                />
              }
            />
            <Fact label="Data" value={<StatusBadge ok={Boolean(paths?.cellular.up)} />} />
            <Fact
              label="Signal"
              value={
                paths?.cellular.modem?.rssi != null
                  ? `${paths.cellular.modem.rssi} dBm`
                  : null
              }
            />
          </FactList>
        </Card>
      </div>

      <Card title="Identity" icon={Fingerprint}>
        <FactList>
          <Fact label="Gateway EUI" value={system.identity.gatewayEui} mono />
          <Fact label="Serial" value={system.identity.serial} mono />
          <Fact
            label="Board"
            value={
              system.identity.boardName
                ? `${system.identity.boardName} (${system.identity.board})`
                : null
            }
          />
          <Fact
            label="Adoption"
            value={
              system.adoption.state === 'adopted' ? (
                <Badge tone="success">
                  Adopted{system.adoption.org ? ` · ${system.adoption.org}` : ''}
                </Badge>
              ) : (
                <Badge tone="warning">Not adopted</Badge>
              )
            }
          />
        </FactList>
      </Card>

      <Card title="Firmware" icon={Cpu}>
        <FactList>
          <Fact
            label="ParkezeOS"
            value={
              system.firmware.version
                ? `${system.firmware.version} (${system.firmware.commit})`
                : null
            }
          />
          <Fact label="OpenWrt" value={system.firmware.openwrt} />
          <Fact label="Kernel" value={system.firmware.kernel} mono />
        </FactList>
      </Card>
    </div>
  );
}
