import { Suspense } from 'react';
import { Link, NavLink, Outlet, useLocation } from 'react-router-dom';
import { LogOut, Network, RefreshCw, ShieldAlert } from 'lucide-react';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { api } from '@/services/api';
import type { SystemSummary } from '@/types';
import { useSession } from '@/contexts/SessionContext';
import { NAV } from '@/nav';
import RecoveryBanner from './RecoveryBanner';
import { useSessionCountdown } from '@/hooks/useSessionCountdown';
import { useFeatures } from '@/hooks/useFeatures';
import { countdown } from '@/lib/format';
import ErrorBoundary from './ErrorBoundary';
import Spinner from './ui/Spinner';
import Button from './ui/Button';
import Brand from './Brand';
import styles from './Layout.module.css';

export default function Layout({
  unadopted,
  reclaiming,
}: { unadopted?: boolean; reclaiming?: boolean } = {}) {
  const { session, signOut } = useSession();
  const location = useLocation();
  const queryClient = useQueryClient();
  const features = useFeatures();
  const nav = NAV.filter((entry) => features.has(entry.feature)).map((entry) => ({
    ...entry,
    children: entry.children?.filter((child) => features.has(child.feature)),
  }));

  // Which gateway this is, on every page. The page's own name is already its
  // heading; repeating it up here said the same thing twice per screen.
  const summary = useQuery({
    queryKey: ['system-summary'],
    queryFn: () => api.get<SystemSummary>('/system/summary'),
  });

  return (
    <div className={styles.shell}>
      <aside className={styles.sidebar}>
        <div className={styles.brand}>
          <Brand size="sm" />
        </div>

        <nav className={styles.nav}>
          {nav.map(({ path, label, icon: Icon, children }) => {
            const inside = path !== '/' && location.pathname.startsWith(path);
            return (
              <div key={path}>
                <NavLink
                  to={children ? children[0].path : path}
                  end={path === '/'}
                  className={({ isActive }) =>
                    `${styles.navItem} ${isActive || inside ? styles.active : ''}`
                  }
                >
                  <Icon size={15} strokeWidth={2} />
                  {label}
                </NavLink>
                {children && inside && (
                  <div className={styles.subnav}>
                    {children.map((child) => (
                      <NavLink
                        key={child.path}
                        to={child.path}
                        className={({ isActive }) =>
                          `${styles.subItem} ${isActive ? styles.subActive : ''}`
                        }
                      >
                        {child.label}
                      </NavLink>
                    ))}
                  </div>
                )}
              </div>
            );
          })}
        </nav>

        <div className={styles.foot}>
          {session?.kind === 'lan' && <LanAccess />}
          <div>{session?.subject}</div>
          {session?.kind !== 'lan' && (
            <div className={styles.footMeta}>
              {session?.kind === 'sso'
                ? 'via Parkeze'
                : session?.kind === 'recovery'
                  ? 'recovery session'
                  : 'local sign-in'}
            </div>
          )}
        </div>
      </aside>

      <div className={styles.main}>
        <div className={styles.top}>
          <header className={styles.topbar}>
            <span className={styles.topbarTitle}>{summary.data?.identity.hostname ?? ''}</span>
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

          {/* Under the top bar, not over it: above, they pushed the bar down
              and its rule stopped lining up with the one under the logo. */}
          {session?.kind === 'recovery' && <RecoveryBanner />}
          {unadopted && <UnadoptedBanner />}
          {reclaiming && <ReclaimBanner />}
        </div>

        <main
          className={`${styles.content} ${
            NAV.flatMap((entry) => [entry, ...(entry.children ?? [])]).some(
              (entry) => entry.wide && location.pathname.startsWith(entry.path),
            )
              ? styles.wide
              : ''
          }`}
        >
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
 * A LAN window's countdown, in the sidebar.
 *
 * Not a banner across the page like recovery: a LAN window is something
 * somebody at the bench opened on purpose and is working inside, so the clock
 * only needs to be findable, not in the way.
 */
function LanAccess() {
  const remaining = useSessionCountdown();
  return (
    <div className={styles.lan} title="Closes on its own, or with parkeze-local-access close">
      <Network size={12} strokeWidth={2} />
      LAN access
      <span className={styles.lanClock}>{countdown(remaining)}</span>
    </div>
  );
}

/**
 * Shown on every page while a revoked claim waits to be replaced: the gateway
 * changed hands or was released, and parkeze.net refuses its reports until the
 * new claim is adopted. Not dismissible, for the reason the one below is not.
 */
function ReclaimBanner() {
  return (
    <div className={styles.unadopted} role="status">
      <ShieldAlert size={15} strokeWidth={1.9} />
      <span>
        <strong>Claim revoked.</strong> Parkeze refuses this gateway&apos;s
        reports until its new claim is adopted.
      </span>
      <Link className={styles.unadoptedAction} to="/adopt">
        Show the claim
      </Link>
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
