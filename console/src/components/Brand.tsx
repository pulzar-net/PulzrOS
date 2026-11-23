import styles from './Brand.module.css';

/**
 * The Pulzr mark and the PulzrOS wordmark, in one place.
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
        {/* PulzrOS: the Pulzr wordmark with OS set beside it in the accent,
            the way the product is named on the gateway (owner, 23 Nov 2026). */}
        <div className={styles.word} style={{ fontSize: s.name }} role="img" aria-label="PulzrOS">
          <div className={styles.name} />
          <span className={styles.os} aria-hidden>OS</span>
        </div>
        {sub && (
          <div className={styles.sub} style={{ fontSize: s.sub }}>
            {sub}
          </div>
        )}
      </div>
    </div>
  );
}
