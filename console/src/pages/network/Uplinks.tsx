import { useMemo, useState } from 'react';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { createColumnHelper, getCoreRowModel, useReactTable } from '@tanstack/react-table';
import { ArrowDown, ArrowUp, ListOrdered, Radar } from 'lucide-react';
import { api } from '@/services/api';
import type { Uplink, UplinkIface, UplinksStatus } from '@/types';
import Section from '@/components/ui/Section';
import Badge from '@/components/ui/Badge';
import Button from '@/components/ui/Button';
import Notice from '@/components/ui/Notice';
import Segmented from '@/components/ui/Segmented';
import { TextField } from '@/components/ui/Field';
import DataTable from '@/components/DataTable';
import Spinner from '@/components/ui/Spinner';
import ErrorState from '@/components/ErrorState';
import { duration, uplinkName } from '@/lib/format';
import styles from '../Pages.module.css';

/**
 * The uplink order, and tracking that moves off an uplink that carries
 * nothing (parkeze-uplinks). Failover only: one uplink carries traffic at a
 * time, the first in the order that answers.
 *
 * The WiFi's health is parkeze-wifi-uplink's portal check, so it has no
 * tracking switch. Cellular is untracked until somebody turns it on, because
 * every ping is billed. The order and tracking are in parkeze-uplinks' state,
 * which is what parkeze.net's `uplinks` op reads.
 */

const SWITCH = [
  { value: 'on', label: 'On' },
  { value: 'off', label: 'Off' },
] as const;

const column = createColumnHelper<Uplink>();

export default function Uplinks() {
  const queryClient = useQueryClient();
  const status = useQuery({
    queryKey: ['uplinks'],
    queryFn: () => api.get<UplinksStatus>('/uplinks/status'),
    refetchInterval: 10_000,
  });

  const refresh = () => {
    queryClient.invalidateQueries({ queryKey: ['uplinks'] });
    queryClient.invalidateQueries({ queryKey: ['backhaul'] });
  };
  const order = useMutation({
    mutationFn: (next: UplinkIface[]) => api.post('/uplinks/order', { order: next }),
    onSuccess: refresh,
  });
  const track = useMutation({
    mutationFn: (body: { iface: UplinkIface; on: boolean }) => api.post('/uplinks/track', body),
    onSuccess: refresh,
  });

  // Stable across renders, so the table keeps its cells; see Lan.tsx.
  const setOrder = order.mutate;
  const setTrack = track.mutate;
  const pending = order.isPending || track.isPending;
  const current = status.data?.order;
  const active = status.data?.active ?? null;

  const columns = useMemo(() => {
    const move = (iface: UplinkIface, by: number) => {
      if (!current) return;
      const next = [...current];
      const from = next.indexOf(iface);
      const to = from + by;
      if (from < 0 || to < 0 || to >= next.length) return;
      [next[from], next[to]] = [next[to], next[from]];
      setOrder(next);
    };
    return [
      column.display({
        id: 'position',
        header: '',
        size: 28,
        cell: (info) => info.row.index + 1,
      }),
      column.accessor('iface', {
        header: 'Uplink',
        size: 210,
        cell: (info) => (
          <span className={styles.status}>
            <span>{uplinkName(info.getValue(), info.row.original.device)}</span>
            {info.row.original.device && <span className={`mono ${styles.dim}`}>{info.row.original.device}</span>}
            {info.row.original.metered && <Badge tone="neutral">Metered</Badge>}
          </span>
        ),
      }),
      column.display({
        id: 'state',
        header: 'State',
        cell: (info) => <State uplink={info.row.original} active={active} />,
      }),
      column.display({
        id: 'tracking',
        header: 'Tracking',
        size: 120,
        cell: (info) => {
          const u = info.row.original;
          if (u.iface === 'wwifi') return 'Portal check';
          return (
            <Segmented
              aria-label={`Tracking for ${uplinkName(u.iface, u.device)}`}
              value={u.tracked ? 'on' : 'off'}
              options={[...SWITCH]}
              disabled={pending}
              onChange={(next) => setTrack({ iface: u.iface, on: next === 'on' })}
            />
          );
        },
      }),
      column.display({
        id: 'move',
        header: '',
        size: 108,
        cell: (info) => (
          <div className={styles.pair}>
            <Button
              aria-label={`Move ${uplinkName(info.row.original.iface, info.row.original.device)} up`}
              disabled={pending || info.row.index === 0}
              onClick={() => move(info.row.original.iface, -1)}
            >
              <ArrowUp size={14} strokeWidth={2} />
            </Button>
            <Button
              aria-label={`Move ${uplinkName(info.row.original.iface, info.row.original.device)} down`}
              disabled={pending || info.row.index === (current?.length ?? 0) - 1}
              onClick={() => move(info.row.original.iface, 1)}
            >
              <ArrowDown size={14} strokeWidth={2} />
            </Button>
          </div>
        ),
      }),
    ];
  }, [current, active, pending, setOrder, setTrack]);

  const table = useReactTable({
    data: status.data?.uplinks ?? [],
    columns,
    getRowId: (row) => row.iface,
    getCoreRowModel: getCoreRowModel(),
  });

  if (status.isLoading) return <Spinner label="Reading the uplinks" />;
  if (status.isError) return <ErrorState error={status.error} onRetry={status.refetch} />;

  const state = status.data!;
  const mutationError = (order.error ?? track.error) as Error | null;

  return (
    <div className="fade-in">
      {!state.active && <Notice tone="error">No uplink is up.</Notice>}

      <Section title="Order" icon={ListOrdered} wide>
        {mutationError && <Notice tone="error">{mutationError.message}</Notice>}
        <DataTable table={table} fill="state" />
      </Section>

      <Tracking state={state} onApplied={refresh} />
    </div>
  );
}

function State({ uplink, active }: { uplink: Uplink; active: UplinkIface | null }) {
  const since = uplink.since ? duration(Math.floor(Date.now() / 1000) - uplink.since) : null;
  if (uplink.state === 'down') return <Badge tone="neutral">Down</Badge>;
  if (uplink.state === 'offline') {
    return (
      <span className={styles.status}>
        <Badge tone="error">No answer</Badge>
        {since && <span className={styles.dim}>for {since}</span>}
      </span>
    );
  }
  if (uplink.state === 'portal') return <Badge tone="warning">Sign-in page</Badge>;
  if (uplink.iface === active) return <Badge tone="success">Carrying traffic</Badge>;
  return <Badge tone="neutral">Standby</Badge>;
}

function Tracking({ state, onApplied }: { state: UplinksStatus; onApplied: () => void }) {
  const t = state.tracking;
  const [ips, setIps] = useState(t.ips.join(', '));
  const [every, setEvery] = useState(String(t.interval));
  const [down, setDown] = useState(String(t.down));
  const [up, setUp] = useState(String(t.up));

  const apply = useMutation({
    mutationFn: () =>
      api.post('/uplinks/tracking', {
        ips: ips.split(',').map((ip) => ip.trim()).filter(Boolean),
        interval: Number(every),
        down: Number(down),
        up: Number(up),
      }),
    onSuccess: onApplied,
  });

  return (
    <Section title="Tracking" icon={Radar}>
      <div className={styles.form}>
        <TextField label="Ping" mono value={ips} placeholder="1.1.1.1, 8.8.8.8"
                   onChange={(event) => setIps(event.target.value)} />
        <TextField label="Every (seconds)" inputMode="numeric" value={every}
                   onChange={(event) => setEvery(event.target.value)} />
        <TextField label="Down after (misses)" inputMode="numeric" value={down}
                   onChange={(event) => setDown(event.target.value)} />
        <TextField label="Back after (answers)" inputMode="numeric" value={up}
                   onChange={(event) => setUp(event.target.value)} />
      </div>

      {apply.isError && <Notice tone="error">{(apply.error as Error).message}</Notice>}
      {apply.isSuccess && <Notice tone="success">Applied.</Notice>}

      <div className={styles.actions}>
        <Button variant="primary" loading={apply.isPending} onClick={() => apply.mutate()}>
          Apply
        </Button>
      </div>
    </Section>
  );
}
