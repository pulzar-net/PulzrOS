import styles from './Spinner.module.css';

export default function Spinner({ label }: { label?: string }) {
  return (
    <div className={styles.wrap} role="status">
      <span className={styles.spinner} aria-hidden />
      {label && <span className={styles.label}>{label}</span>}
    </div>
  );
}
