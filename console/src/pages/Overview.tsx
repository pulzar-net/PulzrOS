import type { CSSProperties } from 'react';
import {
  ArrowDown,
  ArrowDownUp,
  ArrowUp,
  Bluetooth as BluetoothIcon,
  Cable,
  ChevronRight,
  Cpu,
  Fingerprint,
  Network,
  Puzzle,
  Radio,
  ShieldCheck,
} from 'lucide-react';
import { Link } from 'react-router-dom';
import { useQuery } from '@tanstack/react-query';
import { api } from '@/services/api';
import type {
  AddonItem,
  AddonStatus,
  BackhaulStatus,
  BluetoothStatus,
  SystemStats,
  LorawanStatus,
  SystemHistory,
  SystemSummary,
  UplinksStatus,
} from '@/types';
import Section from '@/components/ui/Section';
import Badge, { type Tone } from '@/components/ui/Badge';
import Fact, { FactList } from '@/components/Fact';
import Stat, { StatGrid } from '@/components/Stat';
import Notice from '@/components/ui/Notice';
import Spinner from '@/components/ui/Spinner';
import ErrorState from '@/components/ErrorState';
import TimeChart, { Legend, type Series } from '@/components/TimeChart';
import { bitrate, bytes, count, duration, inUnit } from '@/lib/format';
import { uplinkRows, type LinkRow } from '@/lib/uplinks';
import { useFeatures } from '@/hooks/useFeatures';
import { useCellular } from '@/hooks/useCellular';
import styles from './Overview.module.css';

/**
 * The first screen: is this gateway working, and if not, which part.
 *
 * One card per thing the gateway does, each headed by its state and holding
 * the figures that say how well: the uplinks and the tunnel, the traffic,
 * then each radio and add-on the board runs. A figure with nothing behind it
 * is left out rather than drawn as a dash. The uplink and the management
 * tunnel stay separate rows: they fail independently, and a gateway that is
 * online but unreachable reads very differently from one that is offline.
 */

const DAY = 86400;

export default function Overview() {
  const features = useFeatures();
  const cellular = useCellular();
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
  const bluetooth = useQuery({
    queryKey: ['bluetooth'],
    queryFn: () => api.get<BluetoothStatus>('/bluetooth/status'),
    refetchInterval: 15_000,
    enabled: features.has('bluetooth'),
  });
  // The same query System > Resources makes: its core count turns the load
  // average into a share of the CPU.
  const stats = useQuery({
    queryKey: ['system-stats'],
    queryFn: () => api.get<SystemStats>('/system/stats'),
    refetchInterval: 60_000,
  });
  // With failover the order is the site's, so which uplink carries traffic is
  // pulzr-uplinks' answer, not Ethernet-then-WiFi-then-cellular.
  const order = useQuery({
    queryKey: ['uplinks'],
    queryFn: () => api.get<UplinksStatus>('/uplinks/status'),
    refetchInterval: 15_000,
    enabled: features.has('failover'),
  });
  // The same query System > Resources makes for its day view, so the two
  // share one fetch.
  const history = useQuery({
    queryKey: ['system-history', DAY],
    queryFn: () => api.get<SystemHistory>(`/system/history?span=${DAY}`),
    refetchInterval: 60_000,
  });
  // The same query System > Maintenance makes.
  const addons = useQuery({
    queryKey: ['system-addons'],
    queryFn: () => api.get<AddonStatus>('/system/addons'),
    refetchInterval: 60_000,
  });

  if (summary.isLoading) return <Spinner label="Reading gateway state" />;
  if (summary.isError) return <ErrorState error={summary.error} onRetry={summary.refetch} />;

  const system = summary.data!;
  const points = history.data?.points ?? [];
  const latest = points.at(-1);
  const links = uplinkRows(
    { paths: backhaul.data, order: features.has('failover') ? order.data : undefined, cellular: cellular.shown },
    features,
  );

  return (
    <div className="fade-in" style={{ '--card-min': '360px' } as CSSProperties}>
      {system.identity.serialSource === 'random' && (
        <Notice tone="warning">No hardware serial: this one is random and changes on reflash.</Notice>
      )}

      <UplinksCard links={links} paths={backhaul.data} latest={latest} />
      <TrafficCard links={links} points={points} />
      {features.has('lorawan') && <LorawanCard lora={lorawan.data} />}
      {features.has('bluetooth') && bluetooth.data && bluetooth.data.state !== 'absent' && (
        <BluetoothCard bt={bluetooth.data} />
      )}
      <AddonsCard items={addons.data?.items} />
      <GatewayCard system={system} />
      <SystemCard system={system} latest={latest} cores={stats.data?.cpu.cores} />
    </div>
  );
}

// ── uplinks ─────────────────────────────────────────────────────────────────

function UplinksCard({
  links,
  paths,
  latest,
}: {
  links: LinkRow[];
  paths: BackhaulStatus | undefined;
  latest: SystemHistory['points'][number] | undefined;
}) {
  const active = links.find((l) => l.active);
  const tunnel = paths?.tunnel;
  return (
    <Section
      title="Uplinks"
      icon={Network}
      actions={
        paths ? (
          active ? <Badge tone="success">{active.name}</Badge> : <Badge tone="error">No uplink</Badge>
        ) : undefined
      }
    >
      {!paths ? (
        <Spinner label="Reading uplinks" />
      ) : (
        <div className={styles.rows}>
          {links.map((link) => {
            const rate = link.device ? latest?.net[link.device] : undefined;
            const down = bitrate(rate?.[0]);
            const up = bitrate(rate?.[1]);
            const detail = link.detail.filter(Boolean).join(' · ');
            return (
              <Link key={link.key} to={link.to} className={`${styles.row} ${link.active ? styles.inUse : ''}`}>
                <link.icon size={16} strokeWidth={1.9} className={styles.rowIcon} />
                <span className={styles.rowMain}>
                  <span className={styles.rowName}>
                    {link.name}
                    {link.active && <span className={styles.tag}>In use</span>}
                  </span>
                  {detail && <span className={styles.rowDetail}>{detail}</span>}
                </span>
                {down && up && (
                  <span className={styles.rates}>
                    <span><ArrowDown size={11} strokeWidth={2.4} />{down.value} <small>{down.unit}</small></span>
                    <span><ArrowUp size={11} strokeWidth={2.4} />{up.value} <small>{up.unit}</small></span>
                  </span>
                )}
                <Badge tone={link.tone}>{link.state}</Badge>
              </Link>
            );
          })}
          {tunnel && (
            <Link to="/access" className={styles.row}>
              <ShieldCheck size={16} strokeWidth={1.9} className={styles.rowIcon} />
              <span className={styles.rowMain}>
                <span className={styles.rowName}>Management tunnel</span>
                {(tunnel.address || tunnel.lastHandshake != null) && (
                  <span className={styles.rowDetail}>
                    {[
                      tunnel.address,
                      tunnel.lastHandshake != null ? `handshake ${duration(tunnel.lastHandshake)} ago` : null,
                      tunnel.state === 'up' && tunnel.via !== 'none' ? `via ${tunnel.via}` : null,
                    ]
                      .filter(Boolean)
                      .join(' · ')}
                  </span>
                )}
              </span>
              {tunnel.state === 'up' ? (
                <Badge tone="success">Connected</Badge>
              ) : tunnel.state === 'none' ? (
                <Badge tone="neutral">Not enrolled</Badge>
              ) : (
                <Badge tone="error">Offline</Badge>
              )}
            </Link>
          )}
        </div>
      )}
    </Section>
  );
}

// ── traffic ─────────────────────────────────────────────────────────────────

const SERIES_COLOURS = ['var(--chart-down)', 'var(--chart-1)', 'var(--chart-up)', 'var(--hue-violet)'];

/**
 * Each uplink's traffic, down and up together, over the day: the question is
 * which link carried it, and the cellular one costs money. The figures above
 * the chart are pulzr-stats' last sample, a 20 s average, summed over them.
 */
function TrafficCard({ links, points }: { links: LinkRow[]; points: SystemHistory['points'] }) {
  const devices = links
    .filter((l) => l.device && points.some((p) => p.net[l.device!]))
    .map((l) => ({ name: l.name, device: l.device! }));
  if (!devices.length) return null;

  const total = (p: SystemHistory['points'][number], d: string) => (p.net[d]?.[0] ?? 0) + (p.net[d]?.[1] ?? 0);
  const peak = Math.max(0, ...points.map((p) => devices.reduce((sum, d) => sum + total(p, d.device), 0)));
  const unit = inUnit(Math.max(0, ...devices.flatMap((d) => points.map((p) => total(p, d.device)))), '/s');
  const series: Series[] = devices.map((d, i) => ({
    name: d.name,
    color: SERIES_COLOURS[i % SERIES_COLOURS.length],
    values: points.map((p) => (p.net[d.device] ? unit.scale(total(p, d.device)) : null)),
  }));

  const latest = points.at(-1)!;
  const down = bitrate(devices.reduce((sum, d) => sum + (latest.net[d.device]?.[0] ?? 0), 0))!;
  const up = bitrate(devices.reduce((sum, d) => sum + (latest.net[d.device]?.[1] ?? 0), 0))!;
  const top = bitrate(peak)!;

  return (
    <Section
      title="Traffic"
      icon={ArrowDownUp}
      note="24 h"
      actions={series.length > 1 ? <Legend series={series} /> : undefined}
      fill
    >
      <StatGrid>
        <Stat label="Down" value={down.value} unit={down.unit} />
        <Stat label="Up" value={up.value} unit={up.unit} />
        <Stat label="Peak" value={top.value} unit={top.unit} />
      </StatGrid>
      <div className={styles.chart}>
        <TimeChart times={points.map((p) => p.t)} format={unit.format} series={series} />
      </div>
    </Section>
  );
}

// ── radios and add-ons ──────────────────────────────────────────────────────

function GoTo({ to, label }: { to: string; label: string }) {
  return (
    <Link to={to} className={styles.go} aria-label={label} title={label}>
      <ChevronRight size={16} strokeWidth={2} />
    </Link>
  );
}

/** logread's time, "Mon Nov 17 01:48:00 2026", without the weekday and year. */
function logTime(stamp: string | null | undefined) {
  if (!stamp) return null;
  const parts = stamp.trim().split(/\s+/);
  return parts.length >= 4 ? `${parts[1]} ${parts[2]} ${parts[3]}` : stamp;
}

function LorawanCard({ lora }: { lora: LorawanStatus | undefined }) {
  if (!lora) {
    return (
      <Section title="LoRaWAN" icon={Radio}>
        <Spinner label="Reading the forwarder" />
      </Section>
    );
  }
  const c = lora.concentrator;
  const f = lora.forwarder;
  const [tone, state]: [Tone, string] =
    c.status === 'partial' ? ['warning', 'Partial']
      : !f.running ? ['error', c.present ? 'Stopped' : 'No concentrator']
        : !lora.bridge.connected ? ['warning', 'LNS unreachable']
          : ['success', 'Forwarding'];
  const lastUplink = logTime(f.lastUplink);

  return (
    <Section
      title="LoRaWAN"
      icon={Radio}
      actions={<><Badge tone={tone}>{state}</Badge><GoTo to="/lorawan" label="LoRaWAN" /></>}
    >
      {f.running && f.received != null && (
        <StatGrid>
          <Stat label="Received" value={count(f.received)} detail="last 30 s" />
          <Stat label="Forwarded" value={count(f.forwarded)} detail="last 30 s" />
          {f.received > 0 && f.crcOkPercent != null && <Stat label="CRC OK" value={f.crcOkPercent} unit="%" />}
          {f.totalReceived != null && <Stat label="Since boot" value={count(f.totalReceived)} detail="received" />}
        </StatGrid>
      )}
      <FactList>
        <Fact
          label="Concentrator"
          value={
            c.slots > 1
              ? `${c.present} of ${c.slots} · ${c.channels} channels`
              : c.present ? `${c.channels} channels` : 'Not found'
          }
        />
        <Fact
          label="The LNS"
          value={
            lora.bridge.connected
              ? <Badge tone="success">Connected</Badge>
              : <Badge tone="error">Not connected</Badge>
          }
        />
        {lastUplink && <Fact label="Last uplink" value={lastUplink} />}
        {lora.region && <Fact label="Region" value={lora.region} mono />}
        {lora.buffer?.enabled && lora.buffer.queuedBytes > 0 && (
          <Fact label="Queued" value={bytes(lora.buffer.queuedBytes)} />
        )}
      </FactList>
    </Section>
  );
}

function BluetoothCard({ bt }: { bt: BluetoothStatus }) {
  const [tone, state]: [Tone, string] =
    !bt.enabled ? ['neutral', 'Off']
      : bt.running ? ['success', 'Scanning']
        : bt.rebootRequired ? ['warning', 'Needs a reboot']
          : ['error', 'Stopped'];

  return (
    <Section
      title="Bluetooth"
      icon={BluetoothIcon}
      actions={<><Badge tone={tone}>{state}</Badge><GoTo to="/bluetooth" label="Bluetooth" /></>}
    />
  );
}

const ADDON_STATES: Record<string, [Tone, string]> = {
  downloading: ['info', 'Downloading'],
  installing: ['info', 'Installing'],
  removing: ['info', 'Removing'],
  reverted: ['warning', 'Reverted'],
  failed: ['error', 'Failed'],
  'pending-restore': ['info', 'Restoring'],
  unavailable: ['neutral', 'Unavailable'],
};

function addonBadge(item: AddonItem): [Tone, string] {
  if (item.state !== 'installed') return ADDON_STATES[item.state] ?? ['neutral', item.state];
  if (item.health === 'ok') return ['success', 'Running'];
  if (item.health === 'idle') return ['neutral', 'Idle'];
  if (item.health === 'failing') return ['error', 'Failing'];
  return ['success', 'Installed'];
}

/** Each add-on the gateway has (Modbus, through pulzr-edge), and whether it is
    doing its job: its own addon-health script's answer. */
function AddonsCard({ items }: { items: Record<string, AddonItem> | undefined }) {
  const list = Object.entries(items ?? {});
  if (!list.length) return null;
  return (
    <Section title="Add-ons" icon={Puzzle} actions={<GoTo to="/system/maintenance" label="Maintenance" />}>
      <div className={styles.rows}>
        {list.map(([name, item]) => {
          const [tone, state] = addonBadge(item);
          return (
            <div key={name} className={styles.row}>
              <Cable size={16} strokeWidth={1.9} className={styles.rowIcon} />
              <span className={styles.rowMain}>
                <span className={styles.rowName}>{item.title || name}</span>
                {item.version && <span className={`${styles.rowDetail} mono`}>{item.version}</span>}
              </span>
              <Badge tone={tone}>{state}</Badge>
            </div>
          );
        })}
      </div>
    </Section>
  );
}

// ── the gateway itself ──────────────────────────────────────────────────────

function GatewayCard({ system }: { system: SystemSummary }) {
  const { identity, adoption } = system;
  return (
    <Section
      title="Gateway"
      icon={Fingerprint}
      actions={
        adoption.state === 'adopted'
          ? <Badge tone="success">Adopted</Badge>
          : <Badge tone="warning">Not adopted</Badge>
      }
    >
      <FactList>
        <Fact label="Gateway EUI" value={identity.gatewayEui} mono />
        <Fact label="Serial" value={identity.serial} mono />
        <Fact label="Board" value={identity.boardName ?? identity.board} />
        {adoption.state === 'adopted' && adoption.org && <Fact label="Organization" value={adoption.org} />}
      </FactList>
    </Section>
  );
}

function SystemCard({
  system,
  latest,
  cores,
}: {
  system: SystemSummary;
  latest: SystemHistory['points'][number] | undefined;
  /** Unknown until /system/stats answers: then the load shows as its figure. */
  cores: number | undefined;
}) {
  const { firmware, health } = system;
  return (
    <Section title="System" icon={Cpu} actions={<GoTo to="/system/resources" label="Resources" />}>
      {(latest || health.temperature != null) && (
        <StatGrid>
          {latest && <Stat label="CPU" value={Math.round(latest.cpu)} unit="%" />}
          {latest && <MemoryStat used={latest.mem} total={latest.memTotal} />}
          {latest && (cores
            ? <Stat label="Load" value={Math.round((latest.load / cores) * 100)} unit="%" />
            : <Stat label="Load" value={latest.load.toFixed(2)} />)}
          {health.temperature != null && <Stat label="Temp" value={health.temperature.toFixed(0)} unit="°C" />}
        </StatGrid>
      )}
      <FactList>
        <Fact
          label="PulzrOS"
          value={firmware.version ? `${firmware.version}${firmware.commit ? ` (${firmware.commit})` : ''}` : null}
        />
        <Fact label="Uptime" value={health.uptime != null ? duration(health.uptime) : null} />
      </FactList>
    </Section>
  );
}

/** Memory in use: GB from 1 GB up, MB below, with the total under it. The
 *  history records bytes (pulzr-stats); it was drawn as a percentage once,
 *  which read "955818..." on the Opal. */
function MemoryStat({ used, total }: { used: number; total: number }) {
  const [value, unit] = memory(used);
  return <Stat label="Memory" value={value} unit={unit} detail={total ? `of ${memory(total).join(' ')}` : undefined} />;
}

function memory(n: number): [string, string] {
  const MB = 1024 * 1024;
  const GB = 1024 * MB;
  return n >= GB ? [(n / GB).toFixed(1), 'GB'] : [String(Math.round(n / MB)), 'MB'];
}
