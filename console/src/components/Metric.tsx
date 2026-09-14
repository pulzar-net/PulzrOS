import styles from './Metric.module.css';
import type { ReactNode } from 'react';

/** One big number with its label and a line of context under it. */
export default function Metric({
  label,
  value,
  meta,
  tone,
}: {
  label: string;
  value: ReactNode;
  meta?: ReactNode;
  /** Colours the number for the states worth noticing across a room. */
  tone?: 'default' | 'warning' | 'error';
}) {
  return (
    <div className={styles.metric}>
      <div className={styles.label}>{label}</div>
      <div className={`${styles.value} ${tone && tone !== 'default' ? styles[tone] : ''}`}>
        {value ?? '—'}
      </div>
      {meta && <div className={styles.meta}>{meta}</div>}
    </div>
  );
}

export function MetricGrid({ children }: { children: ReactNode }) {
  return <div className={styles.grid}>{children}</div>;
}
