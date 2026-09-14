import type { ButtonHTMLAttributes, ReactNode } from 'react';
import styles from './Button.module.css';

type Variant = 'default' | 'primary' | 'danger';

export default function Button({
  variant = 'default',
  loading,
  children,
  ...rest
}: ButtonHTMLAttributes<HTMLButtonElement> & {
  variant?: Variant;
  /** Disables and shows a spinner. A submit that can be pressed twice will be. */
  loading?: boolean;
  children: ReactNode;
}) {
  return (
    <button
      type="button"
      {...rest}
      className={`${styles.btn} ${styles[variant]} ${rest.className ?? ''}`}
      disabled={rest.disabled || loading}
    >
      {loading && <span className={styles.spinner} aria-hidden />}
      {children}
    </button>
  );
}
