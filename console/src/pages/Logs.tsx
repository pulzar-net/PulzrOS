import { useMemo, useState } from 'react';
import { useQuery } from '@tanstack/react-query';
import {
  createColumnHelper,
  getCoreRowModel,
  getFilteredRowModel,
  getSortedRowModel,
  useReactTable,
  type FilterFn,
  type SortingState,
} from '@tanstack/react-table';
import { api } from '@/services/api';
import { CheckboxField } from '@/components/ui/Field';
import Select from '@/components/ui/Select';
import Spinner from '@/components/ui/Spinner';
import ErrorState from '@/components/ErrorState';
import DataTable from '@/components/DataTable';
import styles from './Logs.module.css';

const SIZES = [200, 500, 1000, 2000];

interface Entry {
  index: number;
  time: string;
  level: string;
  facility: string;
  source: string;
  message: string;
}

// logread: "Sun Oct  4 15:31:14 2026 daemon.info lora[1234]: message". A line
// that does not fit — a continuation, a kernel oddity — is kept whole as the
// message rather than dropped.
const LINE = /^\w{3} (\w{3}) +(\d+) ([\d:]+) \d{4} (\w+)\.(\w+) ([^:[\]]+?)(?:\[\d+\])?: ?(.*)$/;

function parse(lines: string[]): Entry[] {
  return lines
    .filter((line) => line.trim())
    .map((line, index) => {
      const m = LINE.exec(line);
      if (!m) return { index, time: '', level: '', facility: '', source: '', message: line };
      return {
        index,
        time: `${m[1]} ${m[2]} ${m[3]}`,
        facility: m[4],
        level: m[5],
        source: m[6].trim(),
        message: m[7],
      };
    });
}

const SEVERITY: Record<string, number> = {
  emerg: 0, alert: 1, crit: 2, err: 3, warn: 4, warning: 4, notice: 5, info: 6, debug: 7,
};

const LEVELS = [
  { value: 'all', label: 'All levels' },
  { value: '4', label: 'Warnings and worse' },
  { value: '3', label: 'Errors only' },
];

/** At or above a severity; 'all' passes everything. */
const atLeast: FilterFn<Entry> = (row, id, value: string) =>
  value === 'all' || (SEVERITY[row.getValue<string>(id)] ?? 6) <= Number(value);

const column = createColumnHelper<Entry>();

const COLUMNS = [
  column.accessor('index', {
    header: 'Time',
    cell: (info) => info.row.original.time,
    size: 128,
  }),
  column.accessor('level', {
    header: 'Level',
    cell: (info) => <Level value={info.getValue()} />,
    filterFn: atLeast,
    size: 80,
  }),
  column.accessor('source', {
    header: 'Source',
    filterFn: 'equalsString',
    size: 190,
  }),
  // No size: it takes whatever the others leave. TanStack has no "unsized"
  // and clamps 0 up to its minimum, so the colgroup below skips this one.
  column.accessor('message', {
    header: 'Message',
    enableSorting: false,
  }),
];

export default function Logs() {
  const [lines, setLines] = useState(1000);
  const [follow, setFollow] = useState(true);
  const [search, setSearch] = useState('');
  const [level, setLevel] = useState('all');
  const [source, setSource] = useState('');
  const [sorting, setSorting] = useState<SortingState>([{ id: 'index', desc: true }]);

  const logs = useQuery({
    queryKey: ['logs', lines],
    queryFn: () => api.get<{ lines: string[] }>(`/system/logs?lines=${lines}`),
    // Only while following. A log page left open on a desk should not keep
    // waking a gateway that may be on a metered link.
    refetchInterval: follow ? 5000 : false,
  });

  const data = useMemo(() => parse(logs.data?.lines ?? []), [logs.data]);
  const sources = useMemo(
    () => Array.from(new Set(data.map((entry) => entry.source).filter(Boolean))).sort(),
    [data],
  );

  const table = useReactTable({
    data,
    columns: COLUMNS,
    state: {
      sorting,
      globalFilter: search,
      columnFilters: [
        { id: 'level', value: level },
        ...(source ? [{ id: 'source', value: source }] : []),
      ],
    },
    onSortingChange: setSorting,
    globalFilterFn: 'includesString',
    getCoreRowModel: getCoreRowModel(),
    getFilteredRowModel: getFilteredRowModel(),
    getSortedRowModel: getSortedRowModel(),
  });

  const rows = table.getRowModel().rows;

  return (
    <div className={`${styles.page} fade-in`}>
      <div className={styles.toolbar}>
        <input
          className={styles.search}
          placeholder="Search"
          value={search}
          onChange={(event) => setSearch(event.target.value)}
        />
        <Select inline aria-label="Level" value={level} onChange={setLevel} options={LEVELS} />
        <Select
          inline
          aria-label="Source"
          value={source}
          onChange={setSource}
          options={[
            { value: '', label: 'All sources' },
            ...sources.map((name) => ({ value: name, label: name })),
          ]}
        />
        <Select
          inline
          aria-label="Lines"
          value={String(lines)}
          onChange={(value) => setLines(Number(value))}
          options={SIZES.map((size) => ({ value: String(size), label: `Last ${size}` }))}
        />
        <CheckboxField
          label="Follow"
          checked={follow}
          onChange={(event) => setFollow(event.target.checked)}
        />
        <span className={styles.count}>
          {rows.length} of {data.length}
        </span>
      </div>

      {logs.isLoading ? (
        <Spinner label="Reading the log" />
      ) : logs.isError ? (
        <ErrorState error={logs.error} onRetry={logs.refetch} />
      ) : (
        <DataTable
          table={table}
          fill="message"
          rowClassName={(row) => styles[`sev${SEVERITY[row.original.level] ?? 6}`]}
          cellClassName={(id) => styles[id]}
        />
      )}
    </div>
  );
}

function Level({ value }: { value: string }) {
  const severity = SEVERITY[value] ?? 6;
  const tone = severity <= 3 ? styles.error : severity === 4 ? styles.warning : styles.quiet;
  return <span className={tone}>{value || '—'}</span>;
}
