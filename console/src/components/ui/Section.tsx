import type { ReactNode } from 'react';
import type { LucideIcon } from 'lucide-react';
import styles from './Section.module.css';

/**
 * A titled part of a page, as a card. See Section.module.css for why it is a
 * card again, and Layout.module.css for how a page lays its cards out.
 */
export default function Section({
  title,
  icon: Icon,
  actions,
  note,
  wide,
  fill,
  children,
}: {
  title?: string;
  /** Marks the card at a glance, beside its title. */
  icon?: LucideIcon;
  /** Controls for this section, at the end of the heading row. */
  actions?: ReactNode;
  /** Small print at the end of the heading row — a count, a state. */
  note?: ReactNode;
  /** The full width of the page: a table or a chart. */
  wide?: boolean;
  /** Its content takes the card's whole height: a chart, in a row of taller cards. */
  fill?: boolean;
  children: ReactNode;
}) {
  return (
    <section className={`${styles.section} ${wide ? styles.wide : ''} ${fill ? styles.fill : ''}`}>
      {(title || actions || note) && (
        <header className={styles.header}>
          {Icon && (
            <span className={styles.icon}>
              <Icon size={15} strokeWidth={2} />
            </span>
          )}
          {title && <h2 className={styles.title}>{title}</h2>}
          {note && <span className={styles.note}>{note}</span>}
          {actions && <div className={styles.actions}>{actions}</div>}
        </header>
      )}
      <div className={styles.body}>{children}</div>
    </section>
  );
}
