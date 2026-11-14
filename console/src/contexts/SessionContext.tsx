import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useState,
  type ReactNode,
} from 'react';
import { api, setCsrfToken, setUnauthenticatedHandler } from '@/services/api';
import type { Session } from '@/types';

/**
 * Who is signed in, and how.
 *
 * "How" matters as much as "who" here, which is why `kind` is carried around
 * rather than collapsed into a boolean. A recovery session is an exceptional
 * state — granted by Pulzar Cloud to get into a gateway whose backhaul is dead —
 * and the UI banners it, counts it down, and ends it visibly. Treating it as
 * just another login would hide the one thing about it that matters.
 */

interface SessionValue {
  session: Session | null;
  /** Null while the boot-time probe is still running, so the app can avoid
      flashing the login screen at somebody who is already signed in. */
  loading: boolean;
  signIn: (session: Session) => void;
  signOut: () => Promise<void>;
  /** Clears local state without calling the API. Used when the gateway has
      already told us the session is gone. */
  clear: () => void;
}

const SessionContext = createContext<SessionValue | null>(null);

export function SessionProvider({ children }: { children: ReactNode }) {
  const [session, setSession] = useState<Session | null>(null);
  const [loading, setLoading] = useState(true);

  const clear = useCallback(() => {
    setSession(null);
    setCsrfToken(null);
  }, []);

  const signIn = useCallback((next: Session) => {
    setSession(next);
    setCsrfToken(next.csrf);
  }, []);

  const signOut = useCallback(async () => {
    try {
      await api.post('/auth/logout');
    } catch {
      // The cookie is gone from our side either way, and a failed logout must
      // not strand somebody on a page they can no longer use.
    }
    clear();
  }, [clear]);

  // Resume an existing session before rendering anything, so a page refresh
  // does not look like a logout.
  useEffect(() => {
    let cancelled = false;
    api
      .session()
      .then((existing) => {
        if (!cancelled) signIn(existing);
      })
      .catch(() => {
        /* not signed in — the normal first-visit path */
      })
      .finally(() => {
        if (!cancelled) setLoading(false);
      });
    return () => {
      cancelled = true;
    };
  }, [signIn]);

  // Let the API layer drop us to the login screen when the gateway says the
  // session is gone, without every caller having to handle it.
  useEffect(() => {
    setUnauthenticatedHandler(clear);
    return () => setUnauthenticatedHandler(null);
  }, [clear]);

  const value = useMemo(
    () => ({ session, loading, signIn, signOut, clear }),
    [session, loading, signIn, signOut, clear],
  );

  return <SessionContext.Provider value={value}>{children}</SessionContext.Provider>;
}

export function useSession() {
  const value = useContext(SessionContext);
  if (!value) throw new Error('useSession must be used inside a SessionProvider');
  return value;
}
