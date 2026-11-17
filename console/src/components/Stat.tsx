import type { ReactNode } from 'react';
import styles from './Stat.module.css';

/**
 * A measured value, large, with its label above it.
 *
 * For the handful of numbers a card exists to show: packets heard, traffic
 * now, CPU. Everything else is a Fact. A stat with no source is left out by
 * its caller rather than shown as a dash: a tile reading "—" looks like a
 * reading of nothing.
 */
export default function Stat({
  label,
  value,
  unit,
  detail,
}: {
  label: string;
  value: ReactNode;
  unit?: string;
  /** A second figure that qualifies the first: "of 16", "since boot". */
  detail?: ReactNode;
}) {
  return (
    <div className={styles.stat}>
      <div className={styles.label}>{label}</div>
      <div className={styles.value}>
        {value}
        {unit && <span className={styles.unit}>{unit}</span>}
      </div>
      {detail != null && <div className={styles.detail}>{detail}</div>}
    </div>
  );
}

/** Stats side by side in one ruled strip, as many to a row as fit. */
export function StatGrid({ children }: { children: ReactNode }) {
  return <div className={styles.grid}>{children}</div>;
}
