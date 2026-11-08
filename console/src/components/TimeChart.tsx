import { useEffect, useMemo, useRef, useState } from 'react';
import uPlot from 'uplot';
import 'uplot/dist/uPlot.min.css';
import styles from './TimeChart.module.css';

export interface Series {
  name: string;
  /** A CSS colour, normally one of the --chart-* tokens. */
  color: string;
  values: (number | null)[];
}

/** The shortest a chart draws; in a card it grows to fill the card. */
const MIN_HEIGHT = 168;

/**
 * Every chart's value axis is this wide, whatever its labels. Sized to its
 * own labels, "0.4" left a 28px gutter and "112.9 MB" a 62px one, so the
 * plots in a column of cards started at different x and nothing lined up.
 */
const AXIS_WIDTH = 64;

/**
 * A line chart over time, by uPlot.
 *
 * A library now, not hand-drawn SVG: uPlot is about 20KB gzipped, which the
 * flash can carry, and it brings what the SVG did not — a crosshair shared by
 * every chart on a page (`sync`), canvas drawing that stays smooth at a day of
 * 20-second samples, and axes laid out the same way everywhere. Mark specs
 * follow the dataviz skill: 2px lines, a 10% wash under a single series,
 * hairline gridlines.
 *
 * It fills its container's width and height (never less than MIN_HEIGHT), so
 * a card that a grid row stretches gets a taller plot rather than a gap.
 * Multi-series charts draw no legend of their own: the card header carries
 * one (`Legend`), so the plot in every card starts at the same height.
 */
export default function TimeChart({
  times,
  series,
  format,
  max,
  stale,
  sync,
}: {
  /** Seconds since the epoch, one per sample. */
  times: number[];
  series: Series[];
  /** How a value reads on the axis and in the tooltip. */
  format: (value: number) => string;
  /** A fixed top for the axis — total memory, 100% — rather than the data's. */
  max?: number;
  /** Held at reduced opacity while a refetch is in flight. */
  stale?: boolean;
  /** Charts with the same key share one crosshair. */
  sync?: string;
}) {
  const box = useRef<HTMLDivElement>(null);
  const plot = useRef<uPlot | null>(null);
  const [size, setSize] = useState({ width: 0, height: 0 });
  const [hover, setHover] = useState<{ index: number; left: number } | null>(null);
  const dark = useDarkMode();

  useEffect(() => {
    const element = box.current;
    if (!element) return;
    const observer = new ResizeObserver(([entry]) =>
      setSize({ width: Math.floor(entry.contentRect.width), height: Math.floor(entry.contentRect.height) }));
    observer.observe(element);
    return () => observer.disconnect();
  }, []);

  const top = useMemo(() => {
    const peak = Math.max(max ?? 0, ...series.flatMap((s) => s.values.filter((v): v is number => v != null)));
    const ticks = niceTicks(max ?? peak);
    return ticks[ticks.length - 1] || 1;
  }, [series, max]);

  // A new chart when what it draws changes shape; new data alone is setData.
  const shape = `${series.map((s) => `${s.name}:${s.color}`).join('|')}/${top}/${dark}/${sync ?? ''}`;
  const enough = times.length >= 2;

  useEffect(() => {
    const element = box.current;
    if (!element || !enough || !size.width) return;
    const css = getComputedStyle(element);
    const token = (value: string) =>
      value.startsWith('var(') ? css.getPropertyValue(value.slice(4, -1)).trim() || '#888' : value;
    const axisColor = css.getPropertyValue('--text-tertiary').trim();
    const gridColor = css.getPropertyValue('--chart-grid').trim();
    const surface = css.getPropertyValue('--card-bg').trim();
    const axisFont = '10.5px Inter, -apple-system, BlinkMacSystemFont, sans-serif';
    const axis = {
      stroke: axisColor,
      font: axisFont,
      grid: { stroke: gridColor, width: 1 },
      ticks: { show: false },
    };
    const options: uPlot.Options = {
      width: size.width,
      height: Math.max(MIN_HEIGHT, size.height),
      padding: [10, 12, 0, 0],
      legend: { show: false },
      cursor: {
        sync: sync ? { key: sync } : undefined,
        // A vertical line only: a horizontal one, carried into the other
        // synced charts at the same height, marks nothing in them.
        y: false,
        points: { size: 8, width: 2, stroke: surface },
        drag: { x: false, y: false },
      },
      scales: { x: { time: true }, y: { range: [0, top] } },
      axes: [
        {
          ...axis,
          grid: { show: false },
          size: 26,
          space: 110,
          // One line per tick. uPlot's default adds the date under the first
          // label, which a 26px axis draws on top of the time.
          values: (_u, splits) => splits.map((t) => clock(t, times[times.length - 1] - times[0] > 86400)),
        },
        {
          ...axis,
          size: AXIS_WIDTH,
          splits: () => niceTicks(top),
          values: (_u, splits) => splits.map((v) => format(v)),
        },
      ],
      series: [
        {},
        ...series.map((s) => {
          const color = token(s.color);
          return {
            label: s.name,
            stroke: color,
            width: 2,
            fill: series.length === 1 ? withAlpha(color, 0.1) : undefined,
            points: { show: false },
            spanGaps: false,
          };
        }),
      ],
      hooks: {
        setCursor: [
          (u) => {
            const index = u.cursor.idx;
            setHover(index == null ? null : { index, left: u.valToPos(u.data[0][index], 'x') + u.bbox.left / devicePixelRatio });
          },
        ],
      },
    };
    plot.current = new uPlot(options, [times, ...series.map((s) => s.values)] as uPlot.AlignedData, element);
    return () => {
      plot.current?.destroy();
      plot.current = null;
    };
    // Data and size are applied below without rebuilding.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [shape, enough, size.width > 0]);

  useEffect(() => {
    plot.current?.setData([times, ...series.map((s) => s.values)] as uPlot.AlignedData);
  }, [times, series]);

  useEffect(() => {
    if (size.width) plot.current?.setSize({ width: size.width, height: Math.max(MIN_HEIGHT, size.height) });
  }, [size]);

  return (
    <div className={`${styles.chart} ${stale ? styles.stale : ''}`} ref={box} onPointerLeave={() => setHover(null)}>
      {!enough && <div className={styles.empty}>Collecting samples</div>}

      {enough && hover && (
        <div className={styles.tooltip} style={{ left: Math.min(Math.max(hover.left, 70), size.width - 70) }}>
          <div className={styles.when}>{moment(times[hover.index])}</div>
          {series.map((s) => (
            <div key={s.name} className={styles.row}>
              <span className={styles.lineKey} style={{ background: s.color }} />
              <strong>{s.values[hover.index] == null ? '—' : format(s.values[hover.index]!)}</strong>
              {series.length > 1 && <span className={styles.name}>{s.name}</span>}
            </div>
          ))}
        </div>
      )}

      {/* The same numbers without a pointer, for a screen reader. */}
      <table className={styles.srOnly}>
        <thead>
          <tr>
            <th>Time</th>
            {series.map((s) => (
              <th key={s.name}>{s.name}</th>
            ))}
          </tr>
        </thead>
        <tbody>
          {times.map((t, i) => (
            <tr key={t}>
              <td>{moment(t)}</td>
              {series.map((s) => (
                <td key={s.name}>{s.values[i] == null ? '—' : format(s.values[i]!)}</td>
              ))}
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

/** The key to a multi-series chart, for its card's header. */
export function Legend({ series }: { series: Pick<Series, 'name' | 'color'>[] }) {
  return (
    <span className={styles.legend}>
      {series.map((s) => (
        <span key={s.name} className={styles.key}>
          <span className={styles.swatch} style={{ background: s.color }} />
          {s.name}
        </span>
      ))}
    </span>
  );
}

/** Canvas cannot read CSS variables, so the chart is rebuilt when the theme flips. */
function useDarkMode() {
  const query = '(prefers-color-scheme: dark)';
  const [dark, setDark] = useState(() => window.matchMedia(query).matches);
  useEffect(() => {
    const media = window.matchMedia(query);
    const change = () => setDark(media.matches);
    media.addEventListener('change', change);
    return () => media.removeEventListener('change', change);
  }, []);
  return dark;
}

function withAlpha(color: string, alpha: number): string {
  const hex = color.match(/^#([0-9a-f]{6})$/i);
  if (!hex) return color;
  const n = parseInt(hex[1], 16);
  return `rgba(${n >> 16}, ${(n >> 8) & 255}, ${n & 255}, ${alpha})`;
}

/** Four clean ticks from zero: 0, 25, 50, 75, 100 rather than 0, 23.7, 47.4. */
function niceTicks(peak: number): number[] {
  if (!(peak > 0)) return [0, 1];
  const rough = peak / 4;
  const magnitude = 10 ** Math.floor(Math.log10(rough));
  const step = [1, 2, 2.5, 5, 10].map((m) => m * magnitude).find((s) => s >= rough)!;
  const ticks: number[] = [];
  for (let v = 0; v <= peak + step * 0.001; v += step) ticks.push(v);
  if (ticks[ticks.length - 1] < peak) ticks.push(ticks[ticks.length - 1] + step);
  return ticks;
}

function clock(t: number, dated = false): string {
  const date = new Date(t * 1000);
  const time = date.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
  return dated ? `${date.toLocaleDateString([], { month: 'short', day: 'numeric' })} ${time}` : time;
}

function moment(t: number): string {
  return new Date(t * 1000).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', second: '2-digit' });
}
