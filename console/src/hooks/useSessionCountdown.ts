import { useEffect, useState } from 'react';
import { useSession } from '@/contexts/SessionContext';

/**
 * Seconds left on a session that ends on a clock — recovery, or a LAN window —
 * counted down live, and the session dropped locally when it reaches zero.
 *
 * Dropping it here means the operator lands on the sign-in screen and sees
 * why, rather than a sudden wall of 401s on the next request.
 */
export function useSessionCountdown(fallback = 1800): number {
  const { session, clear } = useSession();
  const [remaining, setRemaining] = useState(session?.expiresIn ?? fallback);

  useEffect(() => {
    const timer = setInterval(() => {
      setRemaining((seconds) => {
        if (seconds <= 1) {
          clearInterval(timer);
          clear();
          return 0;
        }
        return seconds - 1;
      });
    }, 1000);
    return () => clearInterval(timer);
  }, [clear]);

  return remaining;
}
