import { useEffect, useMemo, useRef, useState } from 'react';
import styles from './TimeChart.module.css';

export interface Series {
  name: string;
  /** A CSS colour, normally one of the --chart-* tokens. */
  color: string;
  values: (number | null)[];
}

const HEIGHT = 168;
const PAD = { top: 10, right: 12, bottom: 22 };

/**
 * A line chart over time, drawn as plain SVG.
 *
 * Its own rather than a charting library: the console ships on a 16MB flash
 * with a bundle budget, and this needs four things a library would bring
 * hundreds of kilobytes for — an axis, a line, a wash under it, and a
 * crosshair. Mark specs follow the dataviz skill: 2px lines, a 10% area for a
 * single series, hairline solid gridlines, an end dot ringed in the surface.
 */
export default function TimeChart({
  times,
  series,
  format,
  max,
  stale,
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
}) {
  const box = useRef<HTMLDivElement>(null);
  const [width, setWidth] = useState(0);
  const [hover, setHover] = useState<number | null>(null);

  useEffect(() => {
    const element = box.current;
    if (!element) return;
    const observer = new ResizeObserver(([entry]) => setWidth(entry.contentRect.width));
    observer.observe(element);
    return () => observer.disconnect();
  }, []);

  const geometry = useMemo(() => {
    if (!width || times.length < 2) return null;
    const plotH = HEIGHT - PAD.top - PAD.bottom;
    const t0 = times[0];
    const t1 = times[times.length - 1];
    const peak = Math.max(
      max ?? 0,
      ...series.flatMap((s) => s.values.filter((v): v is number => v != null)),
    );
    const ticks = niceTicks(max ?? peak);
    const top = ticks[ticks.length - 1] || 1;
    // As wide as the widest tick label needs, measured rather than fixed: a
    // fixed gutter clipped "120 MB" to "0 MB".
    const left = Math.max(28, Math.max(...ticks.map((t) => format(t).length)) * 6.2 + 12);
    const plotW = width - left - PAD.right;
    const x = (t: number) => left + ((t - t0) / Math.max(1, t1 - t0)) * plotW;
    const y = (v: number) => PAD.top + plotH - (v / top) * plotH;
    return { left, plotW, plotH, t0, t1, ticks, x, y };
  }, [width, times, series, max, format]);

  const paths = useMemo(() => {
    if (!geometry) return [];
    return series.map((s) => {
      let line = '';
      let started = false;
      s.values.forEach((value, i) => {
        if (value == null) {
          started = false;
          return;
        }
        line += `${started ? 'L' : 'M'}${geometry.x(times[i]).toFixed(1)},${geometry.y(value).toFixed(1)}`;
        started = true;
      });
      const base = geometry.y(0).toFixed(1);
      const first = s.values.findIndex((v) => v != null);
      const last = s.values.length - 1 - [...s.values].reverse().findIndex((v) => v != null);
      const area =
        first >= 0 && series.length === 1
          ? `${line}L${geometry.x(times[last]).toFixed(1)},${base}L${geometry.x(times[first]).toFixed(1)},${base}Z`
          : null;
      return { line, area, last };
    });
  }, [geometry, series, times]);

  const onMove = (event: React.PointerEvent<SVGSVGElement>) => {
    if (!geometry) return;
    const rect = event.currentTarget.getBoundingClientRect();
    const px = event.clientX - rect.left;
    const t = geometry.t0 + ((px - geometry.left) / geometry.plotW) * (geometry.t1 - geometry.t0);
    // Snap to the nearest sample: readers aim at a time, not at a 2px line.
    let nearest = 0;
    for (let i = 1; i < times.length; i++) {
      if (Math.abs(times[i] - t) < Math.abs(times[nearest] - t)) nearest = i;
    }
    setHover(nearest);
  };

  const hoverX = geometry && hover != null ? geometry.x(times[hover]) : null;

  return (
    <div className={`${styles.chart} ${stale ? styles.stale : ''}`} ref={box}>
      {series.length > 1 && (
        <div className={styles.legend}>
          {series.map((s) => (
            <span key={s.name} className={styles.key}>
              <span className={styles.swatch} style={{ background: s.color }} />
              {s.name}
            </span>
          ))}
        </div>
      )}

      {!geometry ? (
        <div className={styles.empty} style={{ height: HEIGHT }}>
          {times.length < 2 ? 'Collecting samples' : ''}
        </div>
      ) : (
        <svg
          width={width}
          height={HEIGHT}
          role="img"
          aria-hidden
          onPointerMove={onMove}
          onPointerLeave={() => setHover(null)}
        >
          {geometry.ticks.map((tick) => (
            <g key={tick}>
              <line
                className={styles.grid}
                x1={geometry.left}
                x2={width - PAD.right}
                y1={geometry.y(tick)}
                y2={geometry.y(tick)}
              />
              <text className={styles.axis} x={geometry.left - 8} y={geometry.y(tick)} dy="0.32em" textAnchor="end">
                {format(tick)}
              </text>
            </g>
          ))}

          {timeTicks(geometry.t0, geometry.t1, geometry.plotW).map((t) => (
            <text key={t} className={styles.axis} x={geometry.x(t)} y={HEIGHT - 6} textAnchor="middle">
              {clock(t, geometry.t1 - geometry.t0)}
            </text>
          ))}

          {paths.map((p, i) => (
            <g key={series[i].name}>
              {p.area && <path d={p.area} fill={series[i].color} opacity={0.1} />}
              <path
                d={p.line}
                fill="none"
                stroke={series[i].color}
                strokeWidth={2}
                strokeLinejoin="round"
                strokeLinecap="round"
              />
            </g>
          ))}

          {hoverX == null &&
            paths.map((p, i) => {
              const value = series[i].values[p.last];
              return value == null ? null : (
                <circle
                  key={series[i].name}
                  className={styles.dot}
                  cx={geometry.x(times[p.last])}
                  cy={geometry.y(value)}
                  r={4}
                  fill={series[i].color}
                />
              );
            })}

          {hoverX != null && (
            <>
              <line className={styles.crosshair} x1={hoverX} x2={hoverX} y1={PAD.top} y2={PAD.top + geometry.plotH} />
              {series.map((s) => {
                const value = s.values[hover!];
                return value == null ? null : (
                  <circle key={s.name} className={styles.dot} cx={hoverX} cy={geometry.y(value)} r={4} fill={s.color} />
                );
              })}
            </>
          )}
        </svg>
      )}

      {geometry && hover != null && hoverX != null && (
        <div
          className={styles.tooltip}
          style={{
            left: Math.min(Math.max(hoverX, 70), width - 70),
          }}
        >
          <div className={styles.when}>{clock(times[hover], 0, true)}</div>
          {series.map((s) => (
            <div key={s.name} className={styles.row}>
              <span className={styles.lineKey} style={{ background: s.color }} />
              <strong>{s.values[hover] == null ? '—' : format(s.values[hover]!)}</strong>
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
              <td>{clock(t, 0, true)}</td>
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

/** Round clock times across the span, about one per 110px. */
function timeTicks(t0: number, t1: number, plotW: number): number[] {
  const count = Math.max(2, Math.floor(plotW / 110));
  const raw = (t1 - t0) / count;
  const step = [60, 300, 600, 900, 1800, 3600, 7200, 10800, 21600].find((s) => s >= raw) ?? 21600;
  const ticks: number[] = [];
  for (let t = Math.ceil(t0 / step) * step; t <= t1; t += step) ticks.push(t);
  return ticks;
}

function clock(t: number, span: number, seconds = false): string {
  const date = new Date(t * 1000);
  const time = date.toLocaleTimeString([], {
    hour: '2-digit',
    minute: '2-digit',
    second: seconds ? '2-digit' : undefined,
  });
  return span > 86400 ? `${date.toLocaleDateString([], { month: 'short', day: 'numeric' })} ${time}` : time;
}
