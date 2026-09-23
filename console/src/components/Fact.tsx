import type { ReactNode } from 'react';
import styles from './Fact.module.css';

/**
 * One labeled fact.
 *
 * Every page here is mostly a list of these, so they share one component and
 * therefore one label column width — without it the same field sits at a
 * different indent depending which page you opened, which is exactly the sort
 * of thing that makes a console feel unfinished.
 */
export default function Fact({
  label,
  value,
  mono,
}: {
  label: string;
  value: ReactNode;
  /** Identifiers and addresses, which are read character by character. */
  mono?: boolean;
}) {
  const empty = value === null || value === undefined || value === '';
  return (
    <div className={styles.fact}>
      <span className={styles.label}>{label}</span>
      <span className={mono && !empty ? styles.mono : styles.value}>
        {empty ? <span className={styles.muted}>—</span> : value}
      </span>
    </div>
  );
}

export function FactList({ children }: { children: ReactNode }) {
  return <dl className={styles.list}>{children}</dl>;
}
