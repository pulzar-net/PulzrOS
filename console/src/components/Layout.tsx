import { Suspense, type CSSProperties } from 'react';
import { Link, NavLink, Outlet, useLocation } from 'react-router-dom';
import { LogOut, Network, RefreshCw, ShieldAlert } from 'lucide-react';
import { useQueryClient } from '@tanstack/react-query';
import { useSession } from '@/contexts/SessionContext';
import { NAV, NAV_GROUPS, type NavEntry, type Tone } from '@/nav';
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
  const available = (entries: NavEntry[]) =>
    entries
      .filter((entry) => features.has(entry.feature))
      .map((entry) => ({
        ...entry,
        children: entry.children?.filter((child) => features.has(child.feature)),
      }))
      .filter((entry) => !entry.children || entry.children.length > 0);
  // A heading whose entries this board has none of goes with them.
  const groups = NAV_GROUPS.map((group) => ({ ...group, entries: available(group.entries) }))
    .filter((group) => group.entries.length > 0);

  return (
    <div className={styles.shell}>
      <aside className={styles.sidebar}>
        <div className={styles.brand}>
          <Brand size="sm" />
        </div>

        <nav className={styles.nav}>
          {groups.map((group) => (
            <div key={group.label ?? ''} className={styles.group}>
              {group.label && <div className={styles.groupLabel}>{group.label}</div>}
              {group.entries.map(({ path, label, icon: Icon, tone, children, overview }) => {
                const inside = path !== '/' && location.pathname.startsWith(path);
                return (
                  <div key={path} className={styles.entry}>
                    <NavLink
                      to={children && !overview ? children[0].path : path}
                      end={path === '/'}
                      className={({ isActive }) =>
                        `${styles.navItem} ${isActive || inside ? styles.active : ''}`
                      }
                      style={{ '--tone': `var(--hue-${tone})` } as CSSProperties}
                    >
                      <Icon size={16} strokeWidth={1.9} />
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
            </div>
          ))}
        </nav>

        <div className={styles.foot}>
          {session?.kind === 'lan' && <LanAccess />}
          <div>{session?.subject}</div>
          {session?.kind !== 'lan' && (
            <div className={styles.footMeta}>
              {session?.kind === 'sso'
                ? 'via Pulzar'
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
            <div className={styles.topbarActions}>
              <Button
                variant="quiet"
                onClick={() => queryClient.invalidateQueries()}
                title="Re-read everything from the gateway"
              >
                <RefreshCw size={14} strokeWidth={2} />
                Refresh
              </Button>
              <Button variant="quiet" onClick={signOut}>
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
          // The area's hue, for its cards' icons and its tables' headers.
          style={{ '--tone': `var(--hue-${areaTone(location.pathname)})` } as CSSProperties}
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
    <div className={styles.lan} title="Closes on its own, or with pulzr-local-access close">
      <Network size={12} strokeWidth={2} />
      LAN access
      <span className={styles.lanClock}>{countdown(remaining)}</span>
    </div>
  );
}

/**
 * Shown on every page while a revoked claim waits to be replaced: the gateway
 * changed hands or was released, and Pulzar Cloud refuses its reports until the
 * new claim is adopted. Not dismissible, for the reason the one below is not.
 */
function ReclaimBanner() {
  return (
    <div className={styles.unadopted} role="status">
      <ShieldAlert size={15} strokeWidth={1.9} />
      <span>
        <strong>Claim revoked.</strong> Pulzar refuses this gateway&apos;s
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

/** The hue of the area a path is in: the longest nav path it starts with. */
function areaTone(pathname: string): Tone {
  const entry = [...NAV]
    .filter((e) => e.path === '/' ? pathname === '/' : pathname.startsWith(e.path))
    .sort((a, b) => b.path.length - a.path.length)[0];
  return entry?.tone ?? 'green';
}
