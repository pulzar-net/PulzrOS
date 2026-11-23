import styles from './Segmented.module.css';

export interface SegmentedOption<V extends string | number> {
  value: V;
  label: string;
}

/**
 * A row of buttons where exactly one is chosen: a time range, a policy. Two to
 * four options read faster this way than behind a dropdown, and one tap
 * changes it.
 */
export default function Segmented<V extends string | number>({
  value,
  options,
  onChange,
  disabled,
  size,
  'aria-label': ariaLabel,
}: {
  value: V;
  options: SegmentedOption<V>[];
  onChange: (value: V) => void;
  disabled?: boolean;
  /** small fits a table row at the table's own height. */
  size?: 'small';
  'aria-label': string;
}) {
  return (
    <div className={`${styles.segmented} ${size ? styles.small : ''}`} role="group" aria-label={ariaLabel}>
      {options.map((option) => (
        <button
          key={option.value}
          type="button"
          className={option.value === value ? styles.on : undefined}
          aria-pressed={option.value === value}
          disabled={disabled}
          onClick={() => option.value !== value && onChange(option.value)}
        >
          {option.label}
        </button>
      ))}
    </div>
  );
}
