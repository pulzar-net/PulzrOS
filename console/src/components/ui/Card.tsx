import type { LucideIcon } from 'lucide-react';
import type { ReactNode } from 'react';
import styles from './Card.module.css';

/**
 * A titled box.
 *
 * The gateway console uses boxes where parkeze.net's `Section` uses a bare
 * heading, and that is a considered difference rather than drift: this console
 * is mostly read on a phone, in a car park, by somebody comparing two panels
 * that mean different things (the two backhaul paths, two concentrator slots).
 * A border is what keeps those apart on a 375px screen.
 */
export default function Card({
  title,
  icon: Icon,
  actions,
  note,
  children,
}: {
  title?: string;
  icon?: LucideIcon;
  /** Controls for this card, at the end of the header row. */
  actions?: ReactNode;
  /** Small print at the end of the header row — a count, a state. */
  note?: ReactNode;
  children: ReactNode;
}) {
  return (
    <section className={styles.card}>
      {title && (
        <header className={styles.header}>
          <h2 className={styles.title}>
            {Icon && <Icon size={14} strokeWidth={2} />}
            {title}
          </h2>
          {note && <span className={styles.note}>{note}</span>}
          {actions && <div className={styles.actions}>{actions}</div>}
        </header>
      )}
      <div className={styles.body}>{children}</div>
    </section>
  );
}
