import type { ButtonHTMLAttributes, ReactNode } from 'react';
import styles from './Button.module.css';

type Variant = 'default' | 'primary' | 'danger' | 'quiet';

export default function Button({
  variant = 'default',
  size,
  loading,
  children,
  ...rest
}: ButtonHTMLAttributes<HTMLButtonElement> & {
  variant?: Variant;
  /** small fits a table row at the table's own height. */
  size?: 'small';
  /** Disables and shows a spinner. A submit that can be pressed twice will be. */
  loading?: boolean;
  children: ReactNode;
}) {
  return (
    <button
      type="button"
      {...rest}
      className={`${styles.btn} ${styles[variant]} ${size ? styles.small : ''} ${rest.className ?? ''}`}
      disabled={rest.disabled || loading}
    >
      {loading && <span className={styles.spinner} aria-hidden />}
      {children}
    </button>
  );
}
