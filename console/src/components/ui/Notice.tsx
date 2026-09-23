import { AlertTriangle, CheckCircle2, Info, XCircle } from 'lucide-react';
import type { ReactNode } from 'react';
import styles from './Notice.module.css';

export type NoticeTone = 'info' | 'success' | 'warning' | 'error';

const ICONS = {
  info: Info,
  success: CheckCircle2,
  warning: AlertTriangle,
  error: XCircle,
} as const;

/**
 * An inline message.
 *
 * Carries an icon as well as a color for the same reason Badge carries a
 * word: the difference between "applied" and "failed" must not rest on hue
 * alone.
 */
export default function Notice({
  tone = 'info',
  children,
}: {
  tone?: NoticeTone;
  children: ReactNode;
}) {
  const Icon = ICONS[tone];
  return (
    <div className={`${styles.notice} ${styles[tone]}`} role={tone === 'error' ? 'alert' : undefined}>
      <Icon size={15} strokeWidth={1.9} className={styles.icon} />
      <div>{children}</div>
    </div>
  );
}
