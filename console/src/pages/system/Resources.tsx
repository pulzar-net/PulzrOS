import { useMemo, useState, type ReactNode } from 'react';
import { keepPreviousData, useQuery } from '@tanstack/react-query';
import { api } from '@/services/api';
import type { SystemHistory, SystemStats } from '@/types';
import Section from '@/components/ui/Section';
import Fact, { FactList } from '@/components/Fact';
import Donut from '@/components/Donut';
import Button from '@/components/ui/Button';
import Processes from './Processes';
import Select from '@/components/ui/Select';
import Spinner from '@/components/ui/Spinner';
import ErrorState from '@/components/ErrorState';
import TimeChart from '@/components/TimeChart';
import Segmented from '@/components/ui/Segmented';
import { bytes, inUnit, duration } from '@/lib/format';
import styles from './Resources.module.css';

const SPANS = [
  { seconds: 3600, label: '1 hour' },
  { seconds: 21600, label: '6 hours' },
  { seconds: 86400, label: '24 hours' },
];

const percent = (v: number) => `${Math.round(v)}%`;
const rate = (v: number) => `${bytes(v)}/s`;

export default function Resources() {
  const [span, setSpan] = useState(3600);
  const [iface, setIface] = useState<string | null>(null);
  const [showProcesses, setShowProcesses] = useState(false);

  const history = useQuery({
    queryKey: ['system-history', span],
    queryFn: () => api.get<SystemHistory>(`/system/history?span=${span}`),
    // The collector samples every 20s; polling faster only redraws the same line.
    refetchInterval: 20_000,
    placeholderData: keepPreviousData,
  });
  const stats = useQuery({
    queryKey: ['system-stats'],
    queryFn: () => api.get<SystemStats>('/system/stats'),
    refetchInterval: 20_000,
  });

  const points = history.data?.points ?? [];
  const times = useMemo(() => points.map((p) => p.t), [points]);
  const interfaces = useMemo(
    () => Array.from(new Set(points.flatMap((p) => Object.keys(p.net)))).sort(),
    [points],
  );
  // The busiest interface by default: the one a person asking about traffic
  // almost always means.
  const busiest = useMemo(() => {
    let best: string | null = null;
    let most = -1;
    for (const name of interfaces) {
      const sum = points.reduce((total, p) => total + (p.net[name]?.[0] ?? 0) + (p.net[name]?.[1] ?? 0), 0);
      if (sum > most) {
        most = sum;
        best = name;
      }
    }
    return best;
  }, [interfaces, points]);
  const shown = iface && interfaces.includes(iface) ? iface : busiest;

  if (history.isLoading || stats.isLoading) return <Spinner label="Reading resources" />;
  if (history.isError) return <ErrorState error={history.error} onRetry={history.refetch} />;
  if (stats.isError) return <ErrorState error={stats.error} onRetry={stats.refetch} />;

  const last = points[points.length - 1];
  const memTotal = last?.memTotal ?? stats.data!.memory.total;
  const memUnit = inUnit(memTotal);
  const netPeak = shown
    ? Math.max(0, ...points.flatMap((p) => p.net[shown] ?? [0, 0]))
    : 0;
  const netUnit = inUnit(netPeak, '/s');
  const stale = history.isPlaceholderData;
  const { cpu, storage, temperatures, power, processes } = stats.data!;

  return (
    <div className="fade-in">
      <div className={styles.toolbar}>
        <Segmented
          aria-label="Time range"
          value={span}
          options={SPANS.map((option) => ({ value: option.seconds, label: option.label }))}
          onChange={setSpan}
        />
      </div>

      <div className={styles.grid}>
        <Panel title="CPU" value={last ? percent(last.cpu) : null}>
          <TimeChart
            times={times}
            max={100}
            format={percent}
            stale={stale}
            series={[{ name: 'CPU', color: 'var(--chart-1)', values: points.map((p) => p.cpu) }]}
          />
        </Panel>

        <Panel title="Memory" value={last ? `${bytes(last.mem)} of ${bytes(memTotal)}` : null}>
          <TimeChart
            times={times}
            max={memUnit.scale(memTotal)!}
            format={memUnit.format}
            stale={stale}
            series={[{ name: 'Memory', color: 'var(--chart-1)', values: points.map((p) => memUnit.scale(p.mem)) }]}
          />
        </Panel>

        <Panel title="Load" value={last ? last.load.toFixed(2) : null}>
          <TimeChart
            times={times}
            format={(v) => v.toFixed(1)}
            stale={stale}
            series={[{ name: 'Load', color: 'var(--chart-1)', values: points.map((p) => p.load) }]}
          />
        </Panel>

        <Panel
          title="Network"
          value={
            last && shown && last.net[shown]
              ? `↓ ${rate(last.net[shown][0])}  ↑ ${rate(last.net[shown][1])}`
              : null
          }
          control={
            interfaces.length > 1 && shown ? (
              <Select
                inline
                aria-label="Interface"
                value={shown}
                onChange={setIface}
                options={interfaces.map((name) => ({ value: name, label: name }))}
              />
            ) : null
          }
        >
          <TimeChart
            times={times}
            format={netUnit.format}
            stale={stale}
            series={
              shown
                ? [
                    { name: 'Down', color: 'var(--chart-down)', values: points.map((p) => netUnit.scale(p.net[shown]?.[0] ?? null)) },
                    { name: 'Up', color: 'var(--chart-up)', values: points.map((p) => netUnit.scale(p.net[shown]?.[1] ?? null)) },
                  ]
                : []
            }
          />
        </Panel>
      </div>

      <Section title="Storage">
        <div className={styles.donuts}>
          {storage.map((mount) => (
            <Donut
              key={mount.mount}
              label={mount.label}
              used={mount.used}
              total={mount.total}
              fixed={mount.mount === '/rom'}
              detail={
                mount.mount === '/rom'
                  ? `${bytes(mount.total)}, read-only`
                  : `${bytes(mount.used)} of ${bytes(mount.total)}`
              }
            />
          ))}
        </div>
      </Section>

      {temperatures.length > 0 && (
        <Section title="Temperature">
          <FactList>
            {temperatures.map((sensor, index) => (
              <Fact key={`${sensor.name}-${index}`} label={sensor.name} value={`${sensor.celsius.toFixed(1)} °C`} />
            ))}
          </FactList>
        </Section>
      )}

      {power.length > 0 && (
        <Section title="Power">
          <FactList>
            {power.map((supply) => (
              <Fact
                key={supply.name}
                label={supply.name}
                value={[
                  supply.type,
                  supply.online == null ? null : supply.online ? 'online' : 'offline',
                  supply.volts == null ? null : `${supply.volts.toFixed(2)} V`,
                  supply.capacity == null ? null : `${supply.capacity}%`,
                ]
                  .filter(Boolean)
                  .join(' · ')}
              />
            ))}
          </FactList>
        </Section>
      )}

      <div className={styles.pair}>
        <div>
          <Section title="Processor">
            <FactList>
              <Fact label="Chip" value={cpu.model} />
              <Fact label="Core" value={cpu.cores > 1 ? `${cpu.core} × ${cpu.cores}` : cpu.core} />
              <Fact label="Processes" value={`${cpu.processes} (${cpu.running} running)`} />
              <Fact label="Uptime" value={duration(stats.data!.uptime)} />
            </FactList>
          </Section>
        </div>

        <div>
          <Section
            title="Processes"
            actions={<Button onClick={() => setShowProcesses(true)}>All processes</Button>}
          >
            <FactList>
              {processes.slice(0, 5).map((process) => (
                <Fact key={process.pid} label={process.name} value={bytes(process.rss)} />
              ))}
            </FactList>
          </Section>
        </div>
      </div>

      <Processes open={showProcesses} onClose={() => setShowProcesses(false)} />
    </div>
  );
}

function Panel({
  title,
  value,
  control,
  children,
}: {
  title: string;
  value: string | null;
  control?: ReactNode;
  children: ReactNode;
}) {
  return (
    <div className={styles.panel}>
      <div className={styles.panelHead}>
        <span className={styles.panelTitle}>{title}</span>
        {control}
        <span className={styles.panelValue}>{value ?? '—'}</span>
      </div>
      {children}
    </div>
  );
}
