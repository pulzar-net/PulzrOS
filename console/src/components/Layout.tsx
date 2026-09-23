import { Suspense } from 'react';
import { Link, NavLink, Outlet, useLocation } from 'react-router-dom';
import { LogOut, RefreshCw, ShieldAlert } from 'lucide-react';
import { useQueryClient } from '@tanstack/react-query';
import { useSession } from '@/contexts/SessionContext';
import { NAV } from '@/nav';
import RecoveryBanner from './RecoveryBanner';
import ErrorBoundary from './ErrorBoundary';
import Spinner from './ui/Spinner';
import Button from './ui/Button';
import Brand from './Brand';
import styles from './Layout.module.css';

export default function Layout({ unadopted }: { unadopted?: boolean } = {}) {
  const { session, signOut } = useSession();
  const location = useLocation();
  const queryClient = useQueryClient();

  const current = NAV.find((entry) => entry.path === location.pathname);

  return (
    <div className={styles.shell}>
      <aside className={styles.sidebar}>
        <div className={styles.brand}>
          <Brand size="sm" sub="Gateway" />
        </div>

        <nav className={styles.nav}>
          {NAV.map(({ path, label, icon: Icon }) => (
            <NavLink
              key={path}
              to={path}
              end={path === '/'}
              className={({ isActive }) =>
                `${styles.navItem} ${isActive ? styles.active : ''}`
              }
            >
              <Icon size={15} strokeWidth={2} />
              {label}
            </NavLink>
          ))}
        </nav>

        <div className={styles.foot}>
          <div>{session?.subject}</div>
          <div className={styles.footMeta}>
            {session?.kind === 'sso'
              ? 'via Parkeze'
              : session?.kind === 'recovery'
                ? 'recovery session'
                : 'local sign-in'}
          </div>
        </div>
      </aside>

      <div className={styles.main}>
        {session?.kind === 'recovery' && <RecoveryBanner />}
        {unadopted && <UnadoptedBanner />}

        <header className={styles.topbar}>
          <span className={styles.topbarTitle}>{current?.title ?? ''}</span>
          <div className={styles.topbarActions}>
            <Button
              onClick={() => queryClient.invalidateQueries()}
              title="Re-read everything from the gateway"
            >
              <RefreshCw size={14} strokeWidth={2} />
              Refresh
            </Button>
            <Button onClick={signOut}>
              <LogOut size={14} strokeWidth={2} />
              Sign out
            </Button>
          </div>
        </header>

        <main className={styles.content}>
          {/* Keyed on pathname so a route change remounts rather than
              reusing the previous page's Suspense boundary, which showed the
              old page's content under the new page's spinner. */}
          {/* Keyed the same way as the Suspense below, so a page that threw
              is retried cleanly when you navigate somewhere else rather than
              staying broken until a reload. */}
          <ErrorBoundary
            key={location.pathname}
            onReset={() => queryClient.invalidateQueries()}
          >
            <Suspense fallback={<Spinner label="Loading" />}>
              <Outlet />
            </Suspense>
          </ErrorBoundary>
        </main>
      </div>
    </div>
  );
}

/**
 * Shown on every page until the gateway belongs to somebody.
 *
 * Persistent and not dismissible, because the thing it is warning about is
 * persistent: nothing here is backed up, nobody is watching it, and the
 * settings being changed will be overwritten by the organization's on
 * adoption. A banner you can close is a banner that is closed on the one
 * screen where it mattered.
 */
function UnadoptedBanner() {
  return (
    <div className={styles.unadopted} role="status">
      <ShieldAlert size={15} strokeWidth={1.9} />
      <span>
        <strong>Not adopted.</strong> This gateway is not managed by any
        organization. Its configuration is local only, and adoption will
        replace it.
      </span>
      <Link className={styles.unadoptedAction} to="/adopt">
        Adopt it
      </Link>
    </div>
  );
}
