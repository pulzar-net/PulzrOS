import type { ReactNode } from 'react';
import styles from './Section.module.css';

/**
 * A titled part of a page: a heading with a rule under it, then its content.
 *
 * Not a box. These were bordered cards with shadows, which made every page a
 * stack of tiles and a configuration screen read like a dashboard. A rule and
 * whitespace separate sections well enough, including the side-by-side pairs
 * that the boxes were originally kept for.
 */
export default function Section({
  title,
  actions,
  note,
  children,
}: {
  title?: string;
  /** Controls for this section, at the end of the heading row. */
  actions?: ReactNode;
  /** Small print at the end of the heading row — a count, a state. */
  note?: ReactNode;
  children: ReactNode;
}) {
  return (
    <section className={styles.section}>
      {(title || actions || note) && (
        <header className={styles.header}>
          {title && (
            <h2 className={styles.title}>{title}</h2>
          )}
          {note && <span className={styles.note}>{note}</span>}
          {actions && <div className={styles.actions}>{actions}</div>}
        </header>
      )}
      <div className={styles.body}>{children}</div>
    </section>
  );
}
