import { useMemo } from 'react';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { createColumnHelper, getCoreRowModel, useReactTable } from '@tanstack/react-table';
import { ArrowDownUp, Gauge, History } from 'lucide-react';
import { api } from '@/services/api';
import type { SpeedResult, SpeedtestStatus } from '@/types';
import Section from '@/components/ui/Section';
import Badge from '@/components/ui/Badge';
import Button from '@/components/ui/Button';
import Notice from '@/components/ui/Notice';
import Segmented from '@/components/ui/Segmented';
import Fact, { FactList } from '@/components/Fact';
import DataTable from '@/components/DataTable';
import TimeChart, { Legend, type Series } from '@/components/TimeChart';
import Spinner from '@/components/ui/Spinner';
import ErrorState from '@/components/ErrorState';
import { uplinkName } from '@/lib/format';
import styles from '../Pages.module.css';

/**
 * Speed tests (parkeze-speedtest): each free uplink straight to the nearest
 * LibreSpeed server, and the management tunnel as Pulzr Net measures it,
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
        return r.test === 'tunnel' ? 'Pulzr Net' : r.server ?? '—';
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

      {latest.map((r) => (
        <Section key={r.test === 'tunnel' ? 'tunnel' : r.iface!} title={name(r)} icon={r.test === 'tunnel' ? ArrowDownUp : Gauge}
                 note={<span className={styles.dim}>{when(r.at)}</span>}>
          {r.error ? <Notice tone="error">{r.error}</Notice> : (
            <FactList>
              <Fact label="Down" value={mbps(r.downloadMbps)} />
              <Fact label="Up" value={mbps(r.uploadMbps)} />
              <Fact label="Ping" value={r.pingMs == null ? null : `${Math.round(r.pingMs)} ms`} />
              <Fact label={r.test === 'tunnel' ? 'Over' : 'Server'}
                    value={r.test === 'tunnel' ? uplinkName(r.iface ?? (r.via === 'wifi' ? 'wwifi' : 'wan'), r.device) : r.server} />
            </FactList>
          )}
        </Section>
      ))}

      <Section title="Schedule" icon={History}
               actions={<Button variant="primary" loading={run.isPending} disabled={!!state.running || !state.uplinks.length}
                                onClick={() => run.mutate()}>Run Now</Button>}>
        <Segmented aria-label="Speed test schedule" value={state.schedule.every} options={[...SCHEDULES]}
                   disabled={schedule.isPending} onChange={(every) => schedule.mutate(every)} />
        <FactList>
          <Fact label="At" value={state.schedule.every === 'off' ? null : state.schedule.at} />
        </FactList>
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
          <DataTable table={table} fill="server" />
        </Section>
      )}
    </div>
  );
}
