import { useMemo } from 'react';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { createColumnHelper, getCoreRowModel, useReactTable } from '@tanstack/react-table';
import { ArrowDown, ArrowDownUp, ArrowUp, Gauge, History, type LucideIcon } from 'lucide-react';
import { api } from '@/services/api';
import type { SpeedResult, SpeedtestStatus } from '@/types';
import Section from '@/components/ui/Section';
import Badge from '@/components/ui/Badge';
import Button from '@/components/ui/Button';
import Notice from '@/components/ui/Notice';
import Segmented from '@/components/ui/Segmented';
import DataTable from '@/components/DataTable';
import TimeChart, { Legend, type Series } from '@/components/TimeChart';
import Spinner from '@/components/ui/Spinner';
import ErrorState from '@/components/ErrorState';
import { uplinkName } from '@/lib/format';
import styles from '../Pages.module.css';
import own from './SpeedTest.module.css';

/**
 * Speed tests (pulzr-speedtest): each free uplink straight to the nearest
 * LibreSpeed server, and the management tunnel as Pulzr Cloud measures it,
 * side by side. Never over cellular.
 */

const SCHEDULES = [
  { value: 'off', label: 'Off' },
  { value: 'daily', label: 'Daily' },
  { value: 'weekly', label: 'Weekly' },
] as const;

const COLORS = ['var(--chart-down)', 'var(--chart-1)', 'var(--text-tertiary)'];
const TUNNEL_COLOR = 'var(--chart-up)';

const name = (r: SpeedResult) => (r.test === 'tunnel' ? 'Tunnel' : uplinkName(r.iface ?? '', r.device));
const mbps = (v: number | null | undefined) => (v == null ? '—' : `${v >= 100 ? v.toFixed(0) : v.toFixed(1)} Mb/s`);
const when = (t: number) => new Date(t * 1000).toLocaleString([], { month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit' });

const column = createColumnHelper<SpeedResult>();

export default function SpeedTest() {
  const queryClient = useQueryClient();
  const status = useQuery({
    queryKey: ['speedtest'],
    queryFn: () => api.get<SpeedtestStatus>('/speedtest/status'),
    refetchInterval: (query) => (query.state.data?.running ? 3000 : 30_000),
  });
  const refresh = () => queryClient.invalidateQueries({ queryKey: ['speedtest'] });
  const run = useMutation({ mutationFn: () => api.post('/speedtest/run'), onSuccess: refresh });
  const schedule = useMutation({
    mutationFn: (every: string) => api.post('/speedtest/schedule', { every }),
    onSuccess: refresh,
  });

  const history = status.data?.history ?? [];

  // Latest of each: one per uplink, and the tunnel.
  const latest = useMemo(() => {
    const by = new Map<string, SpeedResult>();
    for (const r of history) by.set(r.test === 'tunnel' ? 'tunnel' : `direct:${r.iface}`, r);
    return [...by.values()].sort((a, b) => (a.test === b.test ? name(a).localeCompare(name(b)) : a.test === 'direct' ? -1 : 1));
  }, [history]);

  // One point per run: a run's tests land within a few minutes of each other.
  const chart = useMemo(() => {
    const ok = history.filter((r) => !r.error);
    const runs: { at: number; results: SpeedResult[] }[] = [];
    for (const r of ok) {
      const last = runs[runs.length - 1];
      if (last && r.at - last.at < 600) last.results.push(r);
      else runs.push({ at: r.at, results: [r] });
    }
    const keys = [...new Set(ok.map((r) => (r.test === 'tunnel' ? 'tunnel' : `direct:${r.iface}`)))]
      .sort((a, b) => (a === 'tunnel' ? 1 : b === 'tunnel' ? -1 : a.localeCompare(b)));
    const label = (key: string) => name(ok.find((r) => (r.test === 'tunnel' ? 'tunnel' : `direct:${r.iface}`) === key)!);
    const series = (pick: (r: SpeedResult) => number | undefined): Series[] =>
      keys.map((key, i) => ({
        name: label(key),
        color: key === 'tunnel' ? TUNNEL_COLOR : COLORS[i % COLORS.length],
        values: runs.map((run) => pick(run.results.find((r) => (r.test === 'tunnel' ? 'tunnel' : `direct:${r.iface}`) === key) ?? {} as SpeedResult) ?? null),
      }));
    return {
      times: runs.map((r) => r.at),
      download: series((r) => r.downloadMbps),
      upload: series((r) => r.uploadMbps),
    };
  }, [history]);

  const columns = useMemo(() => [
    column.accessor('at', { header: 'When', size: 150, cell: (info) => when(info.getValue()) }),
    column.display({ id: 'test', header: 'Test', size: 150, cell: (info) => name(info.row.original) }),
    column.accessor('downloadMbps', { header: 'Down', size: 100, cell: (info) => mbps(info.getValue()) }),
    column.accessor('uploadMbps', { header: 'Up', size: 100, cell: (info) => mbps(info.getValue()) }),
    column.accessor('pingMs', { header: 'Ping', size: 80, cell: (info) => (info.getValue() == null ? '—' : `${Math.round(info.getValue()!)} ms`) }),
    column.display({
      id: 'server',
      header: 'Server',
      cell: (info) => {
        const r = info.row.original;
        if (r.error) return <Badge tone="error">{r.error}</Badge>;
        return r.test === 'tunnel' ? 'Pulzr Cloud' : r.server ?? '—';
      },
    }),
  ], []);

  const rows = useMemo(() => [...history].reverse(), [history]);
  const table = useReactTable({ data: rows, columns, getRowId: (r, i) => `${r.at}-${i}`, getCoreRowModel: getCoreRowModel() });

  if (status.isLoading) return <Spinner label="Reading the speed tests" />;
  if (status.isError) return <ErrorState error={status.error} onRetry={status.refetch} />;

  const state = status.data!;
  const mutationError = (run.error ?? schedule.error) as Error | null;

  return (
    <div className="fade-in">
      {state.running && <Notice tone="info">Testing.</Notice>}
      {!state.running && !state.uplinks.length && <Notice tone="info">No wired or WiFi uplink to test.</Notice>}
      {mutationError && <Notice tone="error">{mutationError.message}</Notice>}

      {/* The last result of each, as a speed test app leads: the two
          numbers large, everything else small under them. */}
      {latest.length > 0 && (
        <div className={own.tiles}>
          {latest.map((r) => (
            <Result key={r.test === 'tunnel' ? 'tunnel' : r.iface!} result={r} />
          ))}
        </div>
      )}

      {/* The line beside the tunnel, on one scale: where they differ, the
          tunnel is the slow part, not the site's internet. */}
      {latest.filter((r) => !r.error).length > 1 && (
        <Section title="Line and Tunnel" icon={ArrowDownUp} wide>
          <Compare results={latest.filter((r) => !r.error)} />
        </Section>
      )}

      <Section title="Schedule" icon={History} wide
               actions={<Button variant="primary" loading={run.isPending} disabled={!!state.running || !state.uplinks.length}
                                onClick={() => run.mutate()}>Run Now</Button>}>
        <div className={own.schedule}>
          <Segmented aria-label="Speed test schedule" value={state.schedule.every} options={[...SCHEDULES]}
                     disabled={schedule.isPending} onChange={(every) => schedule.mutate(every)} />
          {state.schedule.every !== 'off' && <span className={styles.dim}>at {state.schedule.at}</span>}
        </div>
      </Section>

      {chart.times.length >= 2 && (
        <>
          <Section title="Download" icon={Gauge} fill actions={<Legend series={chart.download} />}>
            <TimeChart times={chart.times} series={chart.download} format={(v) => `${Math.round(v)} Mb/s`} sync="speed" />
          </Section>
          <Section title="Upload" icon={Gauge} fill actions={<Legend series={chart.upload} />}>
            <TimeChart times={chart.times} series={chart.upload} format={(v) => `${Math.round(v)} Mb/s`} sync="speed" />
          </Section>
        </>
      )}

      {rows.length > 0 && (
        <Section title="History" icon={History} wide>
          <DataTable table={table} fill="server" cellClassName={() => own.cell} />
        </Section>
      )}
    </div>
  );
}

/** One test's latest result: down and up large, ping and where small. */
function Result({ result: r }: { result: SpeedResult }) {
  const Icon = r.test === 'tunnel' ? ArrowDownUp : Gauge;
  const where = r.test === 'tunnel'
    ? `over ${uplinkName(r.iface ?? (r.via === 'wifi' ? 'wwifi' : 'wan'), r.device)}`
    : r.server;
  return (
    <div className={own.tile}>
      <div className={own.tileHead}>
        <span className={own.tileIcon}><Icon size={14} strokeWidth={2} /></span>
        <span className={own.tileName}>{name(r)}</span>
        <span className={own.tileWhen}>{when(r.at)}</span>
      </div>
      {r.error ? <Notice tone="error">{r.error}</Notice> : (
        <>
          <div className={own.figures}>
            <Figure icon={ArrowDown} label="Down" value={r.downloadMbps} tone="down" />
            <Figure icon={ArrowUp} label="Up" value={r.uploadMbps} tone="up" />
          </div>
          <div className={own.tileFoot}>
            {[r.pingMs == null ? null : `${Math.round(r.pingMs)} ms ping`,
              r.jitterMs == null ? null : `${r.jitterMs.toFixed(1)} ms jitter`,
              where].filter(Boolean).join(' · ')}
          </div>
        </>
      )}
    </div>
  );
}

function Figure({ icon: Icon, label, value, tone }: {
  icon: LucideIcon; label: string; value: number | undefined; tone: 'down' | 'up';
}) {
  return (
    <div className={own.figure}>
      <span className={`${own.figureLabel} ${own[tone]}`}><Icon size={13} strokeWidth={2.2} />{label}</span>
      <span className={own.figureValue}>
        {value == null ? '—' : value >= 100 ? value.toFixed(0) : value.toFixed(1)}
        <span className={own.unit}>Mb/s</span>
      </span>
    </div>
  );
}

/** Each result's down and up as bars on one scale. */
function Compare({ results }: { results: SpeedResult[] }) {
  const top = Math.max(1, ...results.flatMap((r) => [r.downloadMbps ?? 0, r.uploadMbps ?? 0]));
  return (
    <div className={own.compare}>
      {(['downloadMbps', 'uploadMbps'] as const).map((key) => (
        <div key={key} className={own.compareGroup}>
          <div className={own.compareTitle}>{key === 'downloadMbps' ? 'Down' : 'Up'}</div>
          {results.map((r) => (
            <div key={`${key}:${r.test}:${r.iface}`} className={own.bar}>
              <span className={own.barName}>{name(r)}</span>
              <span className={own.barTrack}>
                <span className={`${own.barFill} ${r.test === 'tunnel' ? own.tunnel : ''}`}
                      style={{ width: `${Math.max(2, ((r[key] ?? 0) / top) * 100)}%` }} />
              </span>
              <span className={own.barValue}>{mbps(r[key])}</span>
            </div>
          ))}
        </div>
      ))}
    </div>
  );
}
