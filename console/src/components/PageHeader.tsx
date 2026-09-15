import type { ReactNode } from 'react';
import styles from './PageHeader.module.css';

/**
 * A page title, and actions if the page has any.
 *
 * Deliberately no subtitle. Every page had one and none of them earned their
 * line: they either restated the title in a sentence ("How this gateway
 * reaches the network") or repeated a fact that the cards below already show
 * properly, with a label. A subtitle on every page is a caption on every
 * page, and it pushes the actual content down the screen on a console people
 * open to read one number.
 */
export default function PageHeader({
  title,
  actions,
}: {
  title: string;
  actions?: ReactNode;
}) {
  return (
    <header className={styles.header}>
      <h1 className={styles.title}>{title}</h1>
      {actions && <div className={styles.actions}>{actions}</div>}
    </header>
  );
}
