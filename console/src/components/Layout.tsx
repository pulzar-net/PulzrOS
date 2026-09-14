import { Suspense } from 'react';
import { NavLink, Outlet, useLocation } from 'react-router-dom';
import { LogOut, RefreshCw } from 'lucide-react';
import { useQueryClient } from '@tanstack/react-query';
import { useSession } from '@/contexts/SessionContext';
import { NAV } from '@/nav';
import RecoveryBanner from './RecoveryBanner';
import Spinner from './ui/Spinner';
import Button from './ui/Button';
import styles from './Layout.module.css';

export default function Layout() {
  const { session, signOut } = useSession();
  const location = useLocation();
  const queryClient = useQueryClient();

  const current = NAV.find((entry) => entry.path === location.pathname);

  return (
    <div className={styles.shell}>
      <aside className={styles.sidebar}>
        <div className={styles.brand}>
          <div className={styles.mark}>P</div>
          <div>
            <div className={styles.brandName}>Parkeze</div>
            <div className={styles.brandSub}>Gateway</div>
          </div>
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
              ? 'via parkeze.net'
              : session?.kind === 'recovery'
                ? 'recovery session'
                : 'local sign-in'}
          </div>
        </div>
      </aside>

      <div className={styles.main}>
        {session?.kind === 'recovery' && <RecoveryBanner />}

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
          <Suspense key={location.pathname} fallback={<Spinner label="Loading" />}>
            <Outlet />
          </Suspense>
        </main>
      </div>
    </div>
  );
}
