import { useQuery } from '@tanstack/react-query';
import { api } from '@/services/api';
import type { BackhaulStatus, LorawanStatus, SystemSummary } from '@/types';
import Section from '@/components/ui/Section';
import Badge, { StatusBadge } from '@/components/ui/Badge';
import Fact, { FactList } from '@/components/Fact';
import Notice from '@/components/ui/Notice';
import Spinner from '@/components/ui/Spinner';
import ErrorState from '@/components/ErrorState';
import { duration } from '@/lib/format';
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

  const concentrator = lora?.concentrator;
  const partial = concentrator?.status === 'partial';

  return (
    <div className="fade-in">
      {system.identity.serialSource === 'random' && (
        <Notice tone="warning">
          No hardware serial. Using a random one, which changes on reflash.
        </Notice>
      )}

      {partial && (
        <Notice tone="warning">
          {concentrator!.present} of {concentrator!.slots} concentrators
          responded. Running at {concentrator!.channels} of{' '}
          {concentrator!.slots * 8} channels.
        </Notice>
      )}

      {/* The two control paths, side by side and never merged into one light.
          They fail independently, and one of them costs money. */}
      <div className={styles.grid2}>
        <div>
          <Section title="Wired · Management tunnel">
            <FactList>
              <Fact label="Ethernet" value={<StatusBadge ok={Boolean(paths?.wired.up)} />} />
              <Fact
                label="Tunnel"
                value={
                  <StatusBadge
                    ok={paths?.tunnel.state === 'up'}
                    okLabel="Connected"
                    badLabel={paths?.tunnel.state === 'none' ? 'Not enrolled' : 'Offline'}
                  />
                }
              />
              <Fact label="Address" value={paths?.tunnel.address} mono />
            </FactList>
          </Section>
        </div>

        <div>
          <Section title="Cellular · 1NCE">
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
          </Section>
        </div>
      </div>

      <Section title="Identity">
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
      </Section>

      <Section title="Firmware">
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
          <Fact label="Uptime" value={duration(system.health.uptime)} />
          {system.health.temperature != null && (
            <Fact label="Temperature" value={`${system.health.temperature.toFixed(1)} °C`} />
          )}
        </FactList>
      </Section>
    </div>
  );
}
