import type { ReactNode } from 'react';
import styles from './Badge.module.css';

export type Tone = 'success' | 'warning' | 'error' | 'neutral' | 'info';

/**
 * A status pill.
 *
 * Always color *plus a word*, never color alone — roughly one man in twelve
 * cannot separate the green from the red, and "is this gateway up" is exactly
 * the question you do not want answered ambiguously.
 */
export default function Badge({
  tone = 'neutral',
  children,
}: {
  tone?: Tone;
  children: ReactNode;
}) {
  return <span className={`${styles.badge} ${styles[tone]}`}>{children}</span>;
}

/**
 * The common case: a boolean with a word for each side.
 *
 * `warn` overrides both — for the states that are neither good nor broken,
 * like a gateway running on half its concentrators.
 */
export function StatusBadge({
  ok,
  okLabel = 'Up',
  badLabel = 'Down',
  warn,
}: {
  ok: boolean;
  okLabel?: string;
  badLabel?: string;
  warn?: string;
}) {
  if (warn) return <Badge tone="warning">{warn}</Badge>;
  return <Badge tone={ok ? 'success' : 'error'}>{ok ? okLabel : badLabel}</Badge>;
}
