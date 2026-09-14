import { AlertTriangle } from 'lucide-react';
import Button from './ui/Button';
import styles from './ErrorState.module.css';

/**
 * What a page shows when its data would not load.
 *
 * Always offers a retry. Half the failures this console sees are a gateway
 * that was rebooting, or a shell session that took the API down for two
 * seconds — a dead end with no way forward turns those into a page refresh and
 * a re-login.
 */
export default function ErrorState({
  error,
  onRetry,
}: {
  error: unknown;
  onRetry?: () => void;
}) {
  const message = error instanceof Error ? error.message : 'Something went wrong.';
  return (
    <div className={styles.state} role="alert">
      <AlertTriangle size={22} strokeWidth={1.7} className={styles.icon} />
      <p className={styles.message}>{message}</p>
      {onRetry && <Button onClick={onRetry}>Try again</Button>}
    </div>
  );
}
