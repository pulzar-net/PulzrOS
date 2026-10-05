import type { ReactNode } from 'react';
import { NavLink } from 'react-router-dom';
import styles from './Tabs.module.css';

export interface Tab {
  to: string;
  label: ReactNode;
}

/**
 * Tabs that are links, so each one has a URL: a reload, the back button and a
 * link pasted to a colleague all land on the same tab.
 *
 * `primary` is the underlined row across a page — one per forwarder. `secondary`
 * is the smaller row under it, for the parts of the thing the primary row chose.
 */
export default function Tabs({
  tabs,
  variant = 'primary',
  actions,
}: {
  tabs: Tab[];
  variant?: 'primary' | 'secondary';
  /** Controls for whatever the tabs show, at the end of the row. */
  actions?: ReactNode;
}) {
  return (
    <div className={`${styles.row} ${styles[variant]}`}>
      <nav className={styles.tabs}>
        {tabs.map((tab) => (
          <NavLink
            key={tab.to}
            to={tab.to}
            className={({ isActive }) => `${styles.tab} ${isActive ? styles.active : ''}`}
          >
            {tab.label}
          </NavLink>
        ))}
      </nav>
      {actions && <div className={styles.actions}>{actions}</div>}
    </div>
  );
}
