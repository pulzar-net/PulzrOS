import type { ReactNode } from 'react';
import { Link } from 'react-router-dom';
import { useQuery } from '@tanstack/react-query';
import { api } from '@/services/api';
import type { BackhaulStatus, LanStatus, LorawanStatus, SystemHistory, SystemSummary } from '@/types';
import Section from '@/components/ui/Section';
import Badge, { type Tone } from '@/components/ui/Badge';
import Fact, { FactList } from '@/components/Fact';
import Notice from '@/components/ui/Notice';
import Spinner from '@/components/ui/Spinner';
import ErrorState from '@/components/ErrorState';
import TimeChart, { type Series } from '@/components/TimeChart';
import { duration, inUnit, modemKind } from '@/lib/format';
import { useFeatures } from '@/hooks/useFeatures';
import styles from './Pages.module.css';

/**
 * The first screen: is this gateway working, and if not, which part.
 *
 * One status row per thing the board has, each with its state, the value that
 * matters and the page that fixes it. The uplink and the management tunnel
 * stay separate rows: they fail independently, and a gateway that is online
 * but unreachable reads very differently from one that is offline.
 */

interface Row {
  tone: Tone;
  badge: string;
  text?: string | null;
  detail?: string | null;
  to?: string;
  page?: string;
}

const DAY = 86400;

export default function Overview() {
  const features = useFeatures();
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
    enabled: features.has('lorawan'),
  });
  const lan = useQuery({
    queryKey: ['lan'],
    queryFn: () => api.get<LanStatus>('/lan/status'),
    refetchInterval: 15_000,
    enabled: features.has('lan'),
  });
  // The same query System > Resources makes for its day view, so the two
  // share one fetch.
  const history = useQuery({
    queryKey: ['system-history', DAY],
    queryFn: () => api.get<SystemHistory>(`/system/history?span=${DAY}`),
    refetchInterval: 60_000,
  });

  if (summary.isLoading) return <Spinner label="Reading gateway state" />;
  if (summary.isError) return <ErrorState error={summary.error} onRetry={summary.refetch} />;

  const system = summary.data!;
  const paths = backhaul.data;
  const lora = lorawan.data;

  const concentrator = lora?.concentrator;
  const partial = concentrator?.status === 'partial';

  // Each uplink's traffic, down and up together: the question is which link
  // carried it, and the cellular one costs money.
  const points = history.data?.points ?? [];
  const uplinks: [string, string | null | undefined, string, boolean][] = [
    ['Ethernet', paths?.wired.device, 'var(--chart-down)', true],
    ['WiFi', paths?.wifi?.device, 'var(--chart-1)', features.has('wifi')],
    ['Cellular', paths?.cellular.device, 'var(--chart-up)', features.has('cellular')],
  ];
  const present = uplinks.filter(
    ([, device, , shown]) => shown && device && points.some((p) => p.net[device]),
  );
  const peak = Math.max(
    0,
    ...present.flatMap(([, device]) => points.map((p) => (p.net[device!]?.[0] ?? 0) + (p.net[device!]?.[1] ?? 0))),
  );
  const trafficUnit = inUnit(peak, '/s');
  const traffic: Series[] = present.map(([name, device, color]) => ({
    name,
    color,
    values: points.map((p) =>
      p.net[device!] ? trafficUnit.scale(p.net[device!][0] + p.net[device!][1]) : null,
    ),
  }));

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

      <Section title="Status">
        <FactList>
          <StatusRow label="Uplink" row={uplink(paths)} />
          <StatusRow label="Management tunnel" row={tunnel(paths)} />
          {features.has('cellular') && <StatusRow label="Cellular" row={cellular(paths)} />}
          {features.has('lorawan') && <StatusRow label="LoRaWAN" row={loraRow(lora)} />}
          {features.has('lan') && <StatusRow label="LAN" row={lanRow(lan.data)} />}
        </FactList>
      </Section>

      {traffic.length > 0 && (
        <Section title="Uplink traffic" note="24 h">
          <TimeChart times={points.map((p) => p.t)} format={trafficUnit.format} series={traffic} />
        </Section>
      )}

      <div className={`${styles.grid2} ${styles.ruled}`}>
        <div>
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
        </div>
        <div>
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
      </div>
    </div>
  );
}

function StatusRow({ label, row }: { label: string; row: Row }) {
  const value: ReactNode = (
    <span className={styles.status}>
      <Badge tone={row.tone}>{row.badge}</Badge>
      {row.text && <span>{row.text}</span>}
      {row.detail && <span className={styles.dim}>{row.detail}</span>}
      {row.to && (
        <Link className={styles.go} to={row.to}>
          {row.page}
        </Link>
      )}
    </span>
  );
  return <Fact label={label} value={value} />;
}

function speed(mbps: number | null | undefined) {
  if (!mbps) return null;
  return mbps >= 1000 ? `${mbps / 1000} Gb/s` : `${mbps} Mb/s`;
}

function join(...parts: (string | null | undefined)[]) {
  return parts.filter(Boolean).join(', ') || null;
}

function uplink(paths: BackhaulStatus | undefined): Row {
  if (!paths) return { tone: 'neutral', badge: 'Reading' };
  const { wired, wifi, cellular } = paths;
  if (wired.up) {
    const how = wired.proto === 'static' ? 'static' : wired.proto === 'dhcp' ? 'by DHCP' : null;
    return {
      tone: 'success', badge: 'Ethernet',
      text: join(wired.device, speed(wired.speed)),
      detail: [wired.address?.split('/')[0], how].filter(Boolean).join(' ') || null,
      to: '/backhaul/ethernet', page: 'Ethernet',
    };
  }
  if (wifi?.up) {
    return {
      tone: 'success', badge: 'WiFi', text: wifi.device, detail: wifi.address?.split('/')[0],
      to: '/backhaul/wifi', page: 'WiFi',
    };
  }
  if (cellular.up) {
    return {
      tone: 'warning', badge: 'Cellular', text: cellular.modem?.model ?? cellular.device,
      detail: 'metered', to: '/backhaul/cellular', page: 'Cellular',
    };
  }
  return { tone: 'error', badge: 'None', text: 'No uplink', to: '/backhaul/ethernet', page: 'Backhaul' };
}

function tunnel(paths: BackhaulStatus | undefined): Row {
  if (!paths) return { tone: 'neutral', badge: 'Reading' };
  const t = paths.tunnel;
  const handshake = t.lastHandshake != null ? `handshake ${duration(t.lastHandshake)} ago` : null;
  if (t.state === 'up') return { tone: 'success', badge: 'Connected', text: t.address, detail: handshake, to: '/access', page: 'Access' };
  if (t.state === 'none') return { tone: 'neutral', badge: 'Not enrolled', to: '/access', page: 'Access' };
  return { tone: 'error', badge: 'Offline', text: t.address, detail: handshake, to: '/access', page: 'Access' };
}

function cellular(paths: BackhaulStatus | undefined): Row {
  if (!paths) return { tone: 'neutral', badge: 'Reading' };
  const modem = paths.cellular.modem;
  const to = '/backhaul/cellular';
  if (!modem) return { tone: 'neutral', badge: 'No modem', to, page: 'Cellular' };
  const signal = modem.rssi != null ? `${modem.rssi} dBm` : modem.quality != null ? `${modem.quality}%` : null;
  return {
    tone: paths.cellular.up ? 'success' : 'neutral',
    badge: paths.cellular.up ? 'Connected' : 'Standby',
    text: join(modem.model ?? modemKind(modem.kind), signal),
    detail: join(modem.model ? modemKind(modem.kind) : null, modem.network, modem.technology),
    to, page: 'Cellular',
  };
}

function loraRow(lora: LorawanStatus | undefined): Row {
  if (!lora) return { tone: 'neutral', badge: 'Reading' };
  const c = lora.concentrator;
  const to = '/lorawan';
  const lns = lora.bridge.connected ? 'connected to the LNS' : 'not connected to the LNS';
  if (c.status === 'partial') return { tone: 'warning', badge: 'Partial', text: `${c.channels} of ${c.slots * 8} channels`, detail: lns, to, page: 'LoRaWAN' };
  if (!lora.forwarder.running) return { tone: 'error', badge: 'Stopped', text: c.present ? `${c.channels} channels` : 'No concentrator', detail: lns, to, page: 'LoRaWAN' };
  return { tone: lora.bridge.connected ? 'success' : 'warning', badge: 'Forwarding', text: `${c.channels} channels`, detail: lns, to, page: 'LoRaWAN' };
}

function lanRow(lan: LanStatus | undefined): Row {
  if (!lan) return { tone: 'neutral', badge: 'Reading' };
  const to = '/network/lan';
  if (!lan.configured) return { tone: 'neutral', badge: 'Not configured', to, page: 'LAN' };
  const clients = lan.clients ?? [];
  const online = clients.filter((c) => c.online).length;
  const forwards = lan.forwards?.length ?? 0;
  return {
    tone: online ? 'success' : 'neutral',
    badge: `${online} online`,
    text: `${clients.length} ${clients.length === 1 ? 'client' : 'clients'}`,
    detail: forwards ? `${forwards} tunnel ${forwards === 1 ? 'forward' : 'forwards'} open` : null,
    to, page: 'LAN',
  };
}
