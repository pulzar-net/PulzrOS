import { ShieldAlert } from 'lucide-react';
import { countdown } from '@/lib/format';
import { useSessionCountdown } from '@/hooks/useSessionCountdown';
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
  const remaining = useSessionCountdown();

  return (
    <div className={styles.bar} role="status">
      <span className={styles.text}>
        <ShieldAlert size={15} strokeWidth={1.9} />
        <strong>Recovery session</strong>
        <span className={styles.detail}>
          — granted by Parkeze for offline access. Normal sign-in resumes
          once this gateway is back online.
        </span>
      </span>
      <span className={styles.clock}>{countdown(remaining)} left</span>
    </div>
  );
}
