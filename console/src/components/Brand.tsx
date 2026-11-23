import styles from './Brand.module.css';

/**
 * The Pulzr mark and wordmark, in one place.
 *
 * The same two files app.pulzr.net draws (icon.svg and wordmark.svg), shipped
 * with the firmware rather than fetched: a gateway console has to render with
 * no internet at all, which is most of the point of it existing.
 */
const SIZES = {
  sm: { mark: 26, name: 14, sub: 11 },
  md: { mark: 30, name: 15, sub: 12 },
  lg: { mark: 36, name: 17, sub: 13 },
} as const;

export default function Brand({
  size = 'md',
  sub,
}: {
  size?: keyof typeof SIZES;
  /** Second line. Omitted entirely when absent — no placeholder, no filler. */
  sub?: string;
}) {
  const s = SIZES[size];
  return (
    <div className={styles.brand}>
      <img
        className={styles.mark}
        src="/icon.svg"
        width={s.mark}
        height={s.mark}
        alt=""
        /* Decorative: the name sits next to it in text, so announcing the
           image as well would just repeat it to a screen reader. */
        aria-hidden
      />
      <div className={styles.text}>
        {/* The wordmark is a mask filled with the text colour, so it follows
            the light and dark themes as the name in text did. */}
        <div className={styles.name} style={{ fontSize: s.name }} role="img" aria-label="Pulzr" />
        {sub && (
          <div className={styles.sub} style={{ fontSize: s.sub }}>
            {sub}
          </div>
        )}
      </div>
    </div>
  );
}
