import { useEffect, useMemo, useRef, useState } from 'react';
import { useQuery } from '@tanstack/react-query';
import {
  createColumnHelper,
  getCoreRowModel,
  getFilteredRowModel,
  getSortedRowModel,
  useReactTable,
  type SortingState,
} from '@tanstack/react-table';
import { api } from '@/services/api';
import type { ProcessList } from '@/types';
import Dialog from '@/components/ui/Dialog';
import DataTable from '@/components/DataTable';
import Spinner from '@/components/ui/Spinner';
import ErrorState from '@/components/ErrorState';
import { bytes } from '@/lib/format';
import styles from './Processes.module.css';

interface Row {
  pid: number;
  name: string;
  command: string;
  state: string;
  threads: number;
  rss: number;
  /** Percent of the machine over the last poll; null until there are two. */
  cpu: number | null;
}

const STATES: Record<string, string> = {
  R: 'Running', S: 'Sleeping', D: 'Waiting', Z: 'Zombie', T: 'Stopped', I: 'Idle',
};

const column = createColumnHelper<Row>();

const COLUMNS = [
  column.accessor('pid', { header: 'PID', size: 70, meta: { numeric: true } }),
  column.accessor('name', { header: 'Name', size: 170 }),
  column.accessor('cpu', {
    header: 'CPU',
    size: 80,
    meta: { numeric: true },
    cell: (info) => (info.getValue() == null ? '—' : `${info.getValue()!.toFixed(1)}%`),
    sortUndefined: 'last',
  }),
  column.accessor('rss', {
    header: 'Memory',
    size: 96,
    meta: { numeric: true },
    cell: (info) => (info.getValue() ? bytes(info.getValue()) : '—'),
  }),
  column.accessor('threads', { header: 'Threads', size: 76, meta: { numeric: true } }),
  column.accessor('state', {
    header: 'State',
    size: 90,
    cell: (info) => STATES[info.getValue()] ?? info.getValue(),
  }),
  column.accessor('command', { header: 'Command', enableSorting: false }),
];

const POLL_MS = 3000;

export default function Processes({ open, onClose }: { open: boolean; onClose: () => void }) {
  const [search, setSearch] = useState('');
  const [sorting, setSorting] = useState<SortingState>([{ id: 'rss', desc: true }]);

  const list = useQuery({
    queryKey: ['system-processes'],
    queryFn: () => api.get<ProcessList>('/system/processes'),
    // Only while it is on screen.
    enabled: open,
    refetchInterval: open ? POLL_MS : false,
  });

  // CPU per process the way top works it out: the share of the machine's
  // ticks since the last poll that went to this process.
  const previous = useRef<ProcessList | null>(null);
  const [cpu, setCpu] = useState<Record<number, number>>({});
  useEffect(() => {
    const data = list.data;
    if (!data) return;
    const last = previous.current;
    if (last && data.total > last.total) {
      const before = new Map(last.processes.map((p) => [p.pid, p.ticks]));
      const elapsed = data.total - last.total;
      const next: Record<number, number> = {};
      for (const p of data.processes) {
        const was = before.get(p.pid);
        if (was != null) next[p.pid] = Math.max(0, ((p.ticks - was) / elapsed) * 100);
      }
      setCpu(next);
    }
    previous.current = data;
  }, [list.data]);

  const rows = useMemo<Row[]>(
    () =>
      (list.data?.processes ?? []).map((p) => ({
        pid: p.pid,
        name: p.name,
        command: p.command || `[${p.name}]`,
        state: p.state,
        threads: p.threads,
        rss: p.rss,
        cpu: cpu[p.pid] ?? null,
      })),
    [list.data, cpu],
  );

  const table = useReactTable({
    data: rows,
    columns: COLUMNS,
    state: { sorting, globalFilter: search },
    onSortingChange: setSorting,
    globalFilterFn: 'includesString',
    getRowId: (row) => String(row.pid),
    getCoreRowModel: getCoreRowModel(),
    getFilteredRowModel: getFilteredRowModel(),
    getSortedRowModel: getSortedRowModel(),
  });

  return (
    <Dialog
      open={open}
      onClose={onClose}
      title="Processes"
      actions={
        <>
          <input
            className={styles.search}
            placeholder="Search"
            value={search}
            onChange={(event) => setSearch(event.target.value)}
          />
          <span className={styles.count}>{table.getRowModel().rows.length}</span>
        </>
      }
    >
      {list.isLoading ? (
        <Spinner label="Reading processes" />
      ) : list.isError ? (
        <ErrorState error={list.error} onRetry={list.refetch} />
      ) : (
        <DataTable table={table} fill="command" cellClassName={(id) => styles[id]} />
      )}
    </Dialog>
  );
}
