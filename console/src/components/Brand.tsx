import styles from './Brand.module.css';

/**
 * The Parkeze mark, in one place.
 *
 * It was previously a letter "P" on a colored square, duplicated in three
 * files with three slightly different sizes. This is the real logo, shipped
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
        src="/logo.png"
        width={s.mark}
        height={s.mark}
        alt=""
        /* Decorative: the name sits next to it in text, so announcing the
           image as well would just repeat it to a screen reader. */
        aria-hidden
      />
      <div className={styles.text}>
        <div className={styles.name} style={{ fontSize: s.name }}>
          Parkeze
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
