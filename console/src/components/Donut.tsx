import styles from './Donut.module.css';

const SIZE = 104;
const STROKE = 12;
const R = (SIZE - STROKE) / 2;
const C = 2 * Math.PI * R;
// The 2px surface gap between the used and free arcs, in arc length.
const GAP = 2;

/**
 * Used against free as a ring, the percentage in its middle.
 *
 * The free arc is a light step of the used arc's own hue, so the whole ring
 * reads as one quantity. Amber past 80% and red past 95%, the levels where a
 * full overlay or SD card starts to break things — always with the figure in
 * the middle, never colour alone.
 */
export default function Donut({
  used,
  total,
  label,
  detail,
  fixed,
}: {
  used: number;
  total: number;
  label: string;
  detail: string;
  /** Read-only and full by design: drawn neutral, never as a warning. */
  fixed?: boolean;
}) {
  const ratio = total > 0 ? Math.min(1, used / total) : 0;
  const tone = fixed ? styles.fixed : ratio > 0.95 ? styles.high : ratio > 0.8 ? styles.mid : styles.ok;
  const usedLength = Math.max(0, ratio * C - (ratio > 0 && ratio < 1 ? GAP : 0));
  const freeLength = Math.max(0, (1 - ratio) * C - (ratio > 0 && ratio < 1 ? GAP : 0));
  const percent = ratio * 100;

  return (
    <figure className={`${styles.donut} ${tone}`}>
      <svg width={SIZE} height={SIZE} viewBox={`0 0 ${SIZE} ${SIZE}`} role="img" aria-label={`${label}: ${detail}`}>
        <g transform={`rotate(-90 ${SIZE / 2} ${SIZE / 2})`}>
          {freeLength > 0 && (
            <circle
              className={styles.free}
              cx={SIZE / 2}
              cy={SIZE / 2}
              r={R}
              strokeWidth={STROKE}
              strokeDasharray={`${freeLength} ${C}`}
              strokeDashoffset={-(ratio * C + (ratio > 0 ? GAP / 2 : 0))}
            >
              <title>Free</title>
            </circle>
          )}
          {usedLength > 0 && (
            <circle
              className={styles.used}
              cx={SIZE / 2}
              cy={SIZE / 2}
              r={R}
              strokeWidth={STROKE}
              strokeDasharray={`${usedLength} ${C}`}
              strokeDashoffset={ratio < 1 ? -GAP / 2 : 0}
            >
              <title>Used</title>
            </circle>
          )}
        </g>
        <text className={styles.percent} x="50%" y="50%" dy="0.35em" textAnchor="middle">
          {fixed ? 'RO' : percent < 1 && percent > 0 ? '<1%' : `${Math.round(percent)}%`}
        </text>
      </svg>
      <figcaption>
        <span className={styles.label}>{label}</span>
        <span className={styles.detail}>{detail}</span>
      </figcaption>
    </figure>
  );
}
