import { useEffect, useState } from 'react';
import { ShieldAlert } from 'lucide-react';
import { useSession } from '@/contexts/SessionContext';
import { countdown } from '@/lib/format';
import styles from './RecoveryBanner.module.css';

/**
 * The bar shown for the whole of a recovery session.
 *
 * A recovery session is an exceptional state — somebody got into an
 * unreachable gateway with a signature from parkeze.net — and it must not feel
 * like a normal login. Hence a persistent bar rather than a toast, and a live
 * countdown rather than a static "expires in 30 minutes": the session ends
 * mid-edit otherwise, and nothing on screen warned it was about to.
 */
export default function RecoveryBanner() {
  const { session, clear } = useSession();
  const [remaining, setRemaining] = useState(session?.expiresIn ?? 1800);

  useEffect(() => {
    const timer = setInterval(() => {
      setRemaining((seconds) => {
        if (seconds <= 1) {
          clearInterval(timer);
          // The gateway will refuse the next request anyway; dropping to the
          // login screen here means the operator sees why rather than a
          // sudden wall of 401s.
          clear();
          return 0;
        }
        return seconds - 1;
      });
    }, 1000);
    return () => clearInterval(timer);
  }, [clear]);

  return (
    <div className={styles.bar} role="status">
      <span className={styles.text}>
        <ShieldAlert size={15} strokeWidth={1.9} />
        <strong>Recovery session</strong>
        <span className={styles.detail}>
          — granted by parkeze.net for offline access. Normal sign-in resumes
          once this gateway is back online.
        </span>
      </span>
      <span className={styles.clock}>{countdown(remaining)} left</span>
    </div>
  );
}
