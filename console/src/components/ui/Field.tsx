import type { InputHTMLAttributes, ReactNode } from 'react';
import { useId } from 'react';
import Select, { type SelectOption } from './Select';
import styles from './Field.module.css';

/**
 * A labeled form control.
 *
 * The label is wired to the control with a generated id rather than by
 * wrapping, so a screen reader announces it and a tap on the label focuses the
 * input — which matters more here than usual, given how much of this console
 * is used one-handed on a phone.
 */
function Wrapper({
  label,
  hint,
  htmlFor,
  children,
}: {
  label: string;
  hint?: ReactNode;
  htmlFor: string;
  children: ReactNode;
}) {
  return (
    <div className={styles.field}>
      <label className={styles.label} htmlFor={htmlFor}>
        {label}
      </label>
      {children}
      {hint && <p className={styles.hint}>{hint}</p>}
    </div>
  );
}

export function TextField({
  label,
  hint,
  mono,
  ...rest
}: InputHTMLAttributes<HTMLInputElement> & {
  label: string;
  hint?: ReactNode;
  /** For identifiers, addresses and codes — anything read character by
      character or transcribed by hand. */
  mono?: boolean;
}) {
  const id = useId();
  return (
    <Wrapper label={label} hint={hint} htmlFor={id}>
      <input
        id={id}
        {...rest}
        className={`${styles.input} ${mono ? styles.mono : ''}`}
      />
    </Wrapper>
  );
}

export function SelectField<V extends string = string>({
  label,
  hint,
  value,
  onChange,
  options,
  disabled,
}: {
  label: string;
  hint?: ReactNode;
  value: V;
  onChange: (value: V) => void;
  options: SelectOption<V>[];
  disabled?: boolean;
}) {
  const id = useId();
  return (
    <Wrapper label={label} hint={hint} htmlFor={id}>
      <Select id={id} value={value} onChange={onChange} options={options} disabled={disabled} />
    </Wrapper>
  );
}

export function TextAreaField({
  label,
  hint,
  ...rest
}: React.TextareaHTMLAttributes<HTMLTextAreaElement> & {
  label: string;
  hint?: ReactNode;
}) {
  const id = useId();
  return (
    <Wrapper label={label} hint={hint} htmlFor={id}>
      <textarea id={id} {...rest} className={`${styles.input} ${styles.textarea}`} />
    </Wrapper>
  );
}

export function CheckboxField({
  label,
  hint,
  ...rest
}: InputHTMLAttributes<HTMLInputElement> & { label: string; hint?: ReactNode }) {
  const id = useId();
  return (
    <div className={styles.field}>
      <label className={styles.checkboxRow} htmlFor={id}>
        <input id={id} type="checkbox" {...rest} />
        <span className={styles.label}>{label}</span>
      </label>
      {hint && <p className={styles.hint}>{hint}</p>}
    </div>
  );
}
