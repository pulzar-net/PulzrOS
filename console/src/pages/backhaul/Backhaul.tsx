import { useState } from 'react';
import { Link } from 'react-router-dom';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import {
  DndContext,
  KeyboardSensor,
  PointerSensor,
  closestCenter,
  useSensor,
  useSensors,
  type Announcements,
  type DragEndEvent,
} from '@dnd-kit/core';
import {
  SortableContext,
  arrayMove,
  sortableKeyboardCoordinates,
  useSortable,
  verticalListSortingStrategy,
} from '@dnd-kit/sortable';
import { restrictToParentElement, restrictToVerticalAxis } from '@dnd-kit/modifiers';
import { CSS } from '@dnd-kit/utilities';
import { ArrowDown, ArrowUp, ChevronRight, Gauge, GripVertical, Network, Radar } from 'lucide-react';
import { api } from '@/services/api';
import type {
  AccessStatus,
  BackhaulStatus,
  NetworkStatus,
  PortsStatus,
  SpeedResult,
  SpeedtestStatus,
  UplinkIface,
  UplinksStatus,
} from '@/types';
import Section from '@/components/ui/Section';
import Badge from '@/components/ui/Badge';
import Button from '@/components/ui/Button';
import Dialog from '@/components/ui/Dialog';
import Notice from '@/components/ui/Notice';
import Segmented from '@/components/ui/Segmented';
import { TextField } from '@/components/ui/Field';
import Spinner from '@/components/ui/Spinner';
import ErrorState from '@/components/ErrorState';
import ApplyChangeNotice from '@/components/ApplyChangeNotice';
import { useApplyChange, type Pending } from '@/hooks/useApplyChange';
import { useFeatures } from '@/hooks/useFeatures';
import { useCellular } from '@/hooks/useCellular';
import { duration } from '@/lib/format';
import { uplinkRows, type LinkRow } from '@/lib/uplinks';
import pages from '../Pages.module.css';
import styles from './Backhaul.module.css';

/**
 * Every backhaul connection on one card, in the order failover tries them,
 * each the way into its own settings page. Dragging one sets the order.
 *
 * The order is pulzr-uplinks' (POST /uplinks/order), the one that sets each
 * uplink's route metric and that tracking ranks on; scripts/test-router.sh
 * posts this page's body through the console API and checks the tracker
 * fails over in that order. It is applied like any uplink change, so an order
 * that cuts this browser off is undone unless it reaches the gateway again.
 *
 * A board without failover has fixed paths, Ethernet then WiFi then
 * cellular, so there is nothing to drag and no Tracking card.
 *
 * Each row can run a speed test of that connection alone, whatever its place
 * in the order: pulzr-speedtest binds the test to the uplink's own device and
 * changes no route. A metered one asks first, with the data it will cost.
 */

const SWITCH = [
  { value: 'on', label: 'On' },
  { value: 'off', label: 'Off' },
] as const;

export default function Backhaul() {
  const features = useFeatures();
  const failover = features.has('failover');
  const cellular = useCellular();
  const queryClient = useQueryClient();
  const change = useApplyChange();

  const order = useQuery({
    queryKey: ['uplinks'],
    queryFn: () => api.get<UplinksStatus>('/uplinks/status'),
    refetchInterval: 10_000,
    enabled: failover,
  });
  const paths = useQuery({
    queryKey: ['backhaul'],
    queryFn: () => api.get<BackhaulStatus>('/network/backhaul'),
    refetchInterval: 15_000,
  });
  const ports = useQuery({
    queryKey: ['ports'],
    queryFn: () => api.get<PortsStatus>('/ports/status'),
    refetchInterval: 15_000,
  });
  const access = useQuery({
    queryKey: ['access'],
    queryFn: () => api.get<AccessStatus>('/access/status'),
    refetchInterval: 15_000,
    enabled: features.has('wifi'),
  });
  const network = useQuery({
    queryKey: ['network-status'],
    queryFn: () => api.get<NetworkStatus>('/network/status'),
    refetchInterval: 15_000,
    enabled: features.has('cellular'),
  });

  const speedtests = features.has('speedtest');
  const speed = useQuery({
    queryKey: ['speedtest'],
    queryFn: () => api.get<SpeedtestStatus>('/speedtest/status'),
    refetchInterval: (query) => (query.state.data?.running ? 3000 : 30_000),
    enabled: speedtests,
  });
  const runTest = useMutation({
    mutationFn: (body: { iface: string; metered: boolean }) => api.post('/speedtest/run', body),
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ['speedtest'] }),
  });
  // The metered connection whose cost is being asked about.
  const [confirm, setConfirm] = useState<LinkRow | null>(null);

  // The order as dropped, shown until the gateway's answer replaces it, so a
  // row does not jump back for the length of a round trip.
  const [dropped, setDropped] = useState<UplinkIface[] | null>(null);

  const refresh = () => {
    queryClient.invalidateQueries({ queryKey: ['uplinks'] });
    queryClient.invalidateQueries({ queryKey: ['backhaul'] });
  };
  const save = useMutation({
    mutationFn: (next: UplinkIface[]) =>
      api.post<UplinksStatus & { pending?: Pending }>('/uplinks/order', { order: next }),
    onSuccess: ({ pending, ...status }) => {
      queryClient.setQueryData(['uplinks'], status);
      change.watch(pending);
      refresh();
    },
    onSettled: () => setDropped(null),
  });
  const track = useMutation({
    mutationFn: (body: { iface: UplinkIface; on: boolean }) =>
      api.post<{ pending?: Pending }>('/uplinks/track', body),
    onSuccess: (answer) => {
      change.watch(answer.pending);
      refresh();
    },
  });

  const sensors = useSensors(
    useSensor(PointerSensor, { activationConstraint: { distance: 4 } }),
    useSensor(KeyboardSensor, { coordinateGetter: sortableKeyboardCoordinates }),
  );

  const loading = failover ? order.isLoading : paths.isLoading;
  const failed = failover ? order : paths;
  if (features.loading || loading) return <Spinner label="Reading the uplinks" />;
  if (failed.isError) return <ErrorState error={failed.error} onRetry={failed.refetch} />;

  const rows = uplinkRows(
    {
      paths: paths.data,
      order: failover ? order.data : undefined,
      ports: ports.data,
      access: access.data,
      network: network.data,
      cellular: cellular.shown,
    },
    features,
  );
  const byKey = new Map(rows.map((row) => [row.key, row]));
  const shown = dropped ? dropped.map((key) => byKey.get(key)).filter((row): row is LinkRow => !!row) : rows;
  const busy = save.isPending || track.isPending || change.phase === 'confirming';
  const sortable = failover && rows.length > 1;
  const nameOf = (id: string | number) => byKey.get(String(id))?.name ?? String(id);
  const announcements: Announcements = {
    onDragStart: ({ active }) => `Picked up ${nameOf(active.id)}.`,
    onDragOver: ({ active, over }) =>
      over ? `${nameOf(active.id)} is at position ${shown.findIndex((r) => r.key === over.id) + 1}.` : undefined,
    onDragEnd: ({ active, over }) =>
      over ? `${nameOf(active.id)} dropped at position ${shown.findIndex((r) => r.key === over.id) + 1}.` : undefined,
    onDragCancel: ({ active }) => `${nameOf(active.id)} put back.`,
  };

  const onDragEnd = ({ active, over }: DragEndEvent) => {
    if (!over || active.id === over.id) return;
    const keys = shown.map((row) => row.key);
    const next = arrayMove(keys, keys.indexOf(String(active.id)), keys.indexOf(String(over.id)));
    setDropped(next);
    // An uplink left off the list (cellular with no modem in) keeps its
    // place: the dropped order fills the places of the ones shown.
    const visible = new Set(keys);
    const queue = [...next];
    const full = order.data?.order ?? keys;
    save.mutate(full.map((key) => (visible.has(key) ? queue.shift()! : key)));
  };

  const latest = new Map<string, SpeedResult>();
  for (const r of speed.data?.history ?? []) if (r.test === 'direct' && r.iface) latest.set(r.iface, r);
  const running = speed.data?.running ?? null;
  const cost = confirm && speed.data?.metered.find((m) => m.iface === confirm.iface);
  const test = (row: LinkRow) => {
    if (!row.iface) return;
    if (row.metered) setConfirm(row);
    else runTest.mutate({ iface: row.iface, metered: false });
  };

  const mutationError = (save.error ?? track.error ?? runTest.error) as Error | null;
  const anyUp = failover ? !!order.data?.active : rows.some((row) => row.active);

  return (
    <div className="fade-in">
      <ApplyChangeNotice change={change} />
      {!anyUp && <Notice tone="error">No uplink is up.</Notice>}

      <Section title="Connections" icon={Network} wide>
        {mutationError && <Notice tone="error">{mutationError.message}</Notice>}
        <DndContext
          sensors={sensors}
          collisionDetection={closestCenter}
          modifiers={[restrictToVerticalAxis, restrictToParentElement]}
          accessibility={{
            announcements,
            screenReaderInstructions: {
              draggable: 'Space picks a connection up, the arrow keys move it, space drops it, escape puts it back.',
            },
          }}
          onDragEnd={onDragEnd}
        >
          <SortableContext items={shown.map((row) => row.key)} strategy={verticalListSortingStrategy}>
            <ol className={styles.rows}>
              {shown.map((row, i) => (
                <Connection
                  key={row.key}
                  row={row}
                  position={failover ? i + 1 : null}
                  sortable={sortable}
                  disabled={busy}
                  speed={speedtests ? {
                    latest: row.iface ? latest.get(row.iface) : undefined,
                    testing: !!running && (running.iface ? running.iface === row.iface : !row.metered && row.tone !== 'neutral'),
                    // One test at a time, and only out of a connection that is up.
                    disabled: !!running || runTest.isPending || !row.iface || row.state === 'Down' || row.state === 'No modem'
                      || row.uplink?.state === 'portal',
                    onTest: () => test(row),
                  } : undefined}
                />
              ))}
            </ol>
          </SortableContext>
        </DndContext>
      </Section>

      <Dialog
        open={!!confirm}
        onClose={() => setConfirm(null)}
        title={`Speed test over ${confirm?.name ?? ''}`}
        size="compact"
        footer={
          <>
            <Button onClick={() => setConfirm(null)}>Cancel</Button>
            <Button
              variant="primary"
              onClick={() => {
                if (confirm?.iface) runTest.mutate({ iface: confirm.iface, metered: true });
                setConfirm(null);
              }}
            >
              Run
            </Button>
          </>
        }
      >
        {cost
          ? `About ${cost.estimateMB} MB of billed data, ${cost.seconds} s each way${cost.from === 'last test' ? ', from its last test' : ''}.`
          : 'Billed data.'}
      </Dialog>

      {failover && order.data && (
        <Tracking
          status={order.data}
          rows={rows}
          disabled={busy}
          onTrack={(iface, on) => track.mutate({ iface, on })}
          onApplied={(pending) => {
            change.watch(pending);
            refresh();
          }}
        />
      )}
    </div>
  );
}

interface RowSpeed {
  latest?: SpeedResult;
  testing: boolean;
  disabled: boolean;
  onTest: () => void;
}

function Connection({
  row, position, sortable, disabled, speed,
}: {
  row: LinkRow;
  /** Its place in the failover order; null on fixed paths. */
  position: number | null;
  sortable: boolean;
  disabled: boolean;
  /** Absent on a board without speed tests. */
  speed?: RowSpeed;
}) {
  const { attributes, listeners, setNodeRef, setActivatorNodeRef, transform, transition, isDragging } =
    useSortable({ id: row.key, disabled: !sortable || disabled });
  const detail = row.detail.filter(Boolean).join(' · ');
  const u = row.uplink;
  const since = u?.state === 'offline' && u.since ? duration(Math.floor(Date.now() / 1000) - u.since) : null;

  return (
    <li
      ref={setNodeRef}
      style={{ transform: CSS.Translate.toString(transform), transition }}
      className={`${styles.row} ${row.active ? styles.inUse : ''} ${isDragging ? styles.dragging : ''}`}
    >
      {sortable && (
        <button
          type="button"
          ref={setActivatorNodeRef}
          className={styles.handle}
          aria-label={`Move ${row.name}`}
          disabled={disabled}
          {...attributes}
          {...listeners}
        >
          <GripVertical size={16} strokeWidth={1.9} />
        </button>
      )}
      {position != null && <span className={styles.position}>{position}</span>}
      <Link to={row.to} className={styles.main} aria-label={`${row.name} settings`}>
        <row.icon size={16} strokeWidth={1.9} className={styles.icon} />
        <span className={styles.text}>
          <span className={styles.name}>
            {row.name}
            {row.active && <span className={styles.tag}>In use</span>}
          </span>
          {detail && <span className={styles.detail}>{detail}</span>}
          {speed?.latest && <SpeedLine result={speed.latest} />}
        </span>
        <span className={styles.state}>
          {since && <span className={styles.since}>for {since}</span>}
          <Badge tone={row.tone}>{row.state}</Badge>
        </span>
        <ChevronRight size={16} strokeWidth={1.9} className={styles.go} />
      </Link>
      {speed && (
        <Button
          className={styles.test}
          aria-label={`Test the speed of ${row.name}`}
          title="Speed test"
          loading={speed.testing}
          disabled={speed.disabled}
          onClick={speed.onTest}
        >
          {!speed.testing && <Gauge size={14} strokeWidth={2} />}
        </Button>
      )}
    </li>
  );
}

/** The connection's last speed test: down, up, ping and how long ago. */
function SpeedLine({ result: r }: { result: SpeedResult }) {
  const ago = duration(Math.max(0, Math.floor(Date.now() / 1000) - r.at));
  if (r.error) return <span className={styles.detail}>Speed test {ago} ago: {r.error}</span>;
  return (
    <span className={`${styles.detail} ${styles.speed}`}>
      <ArrowDown size={11} strokeWidth={2.4} />{r.downloadMbps?.toFixed(1)}
      <ArrowUp size={11} strokeWidth={2.4} />{r.uploadMbps?.toFixed(1)} Mb/s
      {r.pingMs != null && <> · {Math.round(r.pingMs)} ms</>} · {ago} ago
    </span>
  );
}

/**
 * Which uplinks are pinged and how. The WiFi's health is pulzr-wifi-uplink's
 * portal check, so it has no switch. Cellular is untracked until somebody
 * turns it on, because every ping is billed.
 */
function Tracking({
  status, rows, disabled, onTrack, onApplied,
}: {
  status: UplinksStatus;
  rows: LinkRow[];
  disabled: boolean;
  onTrack: (iface: UplinkIface, on: boolean) => void;
  onApplied: (pending?: Pending) => void;
}) {
  const t = status.tracking;
  const [ips, setIps] = useState(t.ips.join(', '));
  const [every, setEvery] = useState(String(t.interval));
  const [down, setDown] = useState(String(t.down));
  const [up, setUp] = useState(String(t.up));

  const apply = useMutation({
    mutationFn: () =>
      api.post<{ pending?: Pending }>('/uplinks/tracking', {
        ips: ips.split(',').map((ip) => ip.trim()).filter(Boolean),
        interval: Number(every),
        down: Number(down),
        up: Number(up),
      }),
    onSuccess: (answer) => onApplied(answer.pending),
  });

  return (
    <Section title="Tracking" icon={Radar}>
      <div className={styles.switches}>
        {rows.map((row) => row.uplink && (
          <div key={row.key} className={styles.switch}>
            <span>{row.name}</span>
            {row.uplink.iface === 'wwifi' ? (
              <span className={pages.dim}>Portal check</span>
            ) : (
              <Segmented
                aria-label={`Tracking for ${row.name}`}
                value={row.uplink.tracked ? 'on' : 'off'}
                options={[...SWITCH]}
                disabled={disabled}
                onChange={(next) => onTrack(row.uplink!.iface, next === 'on')}
              />
            )}
          </div>
        ))}
      </div>

      <div className={pages.form}>
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

      <div className={pages.actions}>
        <Button variant="primary" loading={apply.isPending} onClick={() => apply.mutate()}>
          Apply
        </Button>
      </div>
    </Section>
  );
}
