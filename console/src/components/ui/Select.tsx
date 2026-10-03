import { useCallback, useEffect, useId, useLayoutEffect, useMemo, useRef, useState, type KeyboardEvent } from 'react';
import { createPortal } from 'react-dom';
import { Check, ChevronDown } from 'lucide-react';
import styles from './Select.module.css';

export interface SelectOption<V extends string = string> {
  value: V;
  label: string;
  disabled?: boolean;
}

/** Lists longer than this get a filter box. */
const FILTER_AT = 12;

/**
 * The console's dropdown.
 *
 * Never the browser's own <select>: it draws its menu in the operating
 * system's style, which cannot be themed and, on a phone, takes over the
 * screen with a picker wheel that hides the form it belongs to. This is a
 * button and a listbox in the console's style, with the keyboard behavior
 * people expect from a select (arrows, Home/End, Enter, Escape, typing to
 * jump).
 *
 * The list is portaled to <body> and positioned against the button, so a card
 * or panel with overflow hidden cannot clip it.
 */
export default function Select<V extends string = string>({
  value,
  onChange,
  options,
  placeholder = 'Choose…',
  disabled,
  id,
  'aria-label': ariaLabel,
  inline,
}: {
  value: V | '' | null | undefined;
  onChange: (value: V) => void;
  options: SelectOption<V>[];
  placeholder?: string;
  disabled?: boolean;
  id?: string;
  'aria-label'?: string;
  /** Size to the chosen label (a card header) rather than fill the container (a form). */
  inline?: boolean;
}) {
  const listId = useId();
  const triggerRef = useRef<HTMLButtonElement>(null);
  const popoverRef = useRef<HTMLDivElement>(null);
  const listRef = useRef<HTMLDivElement>(null);
  const filterRef = useRef<HTMLInputElement>(null);
  const [open, setOpen] = useState(false);
  const [filter, setFilter] = useState('');
  const [active, setActive] = useState(0);
  const [place, setPlace] = useState<{ left: number; top: number; width: number; up: boolean; max: number } | null>(null);
  const typed = useRef({ text: '', at: 0 });

  const selected = options.find((o) => o.value === value) ?? null;
  const showFilter = options.length > FILTER_AT;
  const shown = useMemo(() => {
    const q = filter.trim().toLowerCase();
    return q ? options.filter((o) => o.label.toLowerCase().includes(q)) : options;
  }, [options, filter]);

  const measure = useCallback(() => {
    const r = triggerRef.current?.getBoundingClientRect();
    if (!r) return;
    const below = window.innerHeight - r.bottom - 8;
    const above = r.top - 8;
    const up = below < 220 && above > below;
    const width = Math.min(Math.max(r.width, 160), window.innerWidth - 16);
    setPlace({
      left: Math.max(8, Math.min(r.left, window.innerWidth - width - 8)),
      width,
      top: up ? r.top - 4 : r.bottom + 4,
      up,
      max: Math.max(120, Math.min(320, up ? above : below)),
    });
  }, []);

  const openList = () => {
    if (disabled) return;
    setFilter('');
    const i = options.findIndex((o) => o.value === value);
    setActive(i >= 0 ? i : options.findIndex((o) => !o.disabled));
    measure();
    setOpen(true);
  };

  const close = (focusTrigger = true) => {
    setOpen(false);
    if (focusTrigger) triggerRef.current?.focus();
  };

  const choose = (o: SelectOption<V> | undefined) => {
    if (!o || o.disabled) return;
    if (o.value !== value) onChange(o.value);
    close();
  };

  useLayoutEffect(() => {
    if (!open) return;
    (showFilter ? filterRef.current : listRef.current)?.focus();
  }, [open, showFilter]);

  useEffect(() => {
    if (!open) return;
    // pointerdown rather than mousedown so a tap outside closes it on a phone
    // before the tap lands on whatever is underneath.
    const onDown = (e: PointerEvent) => {
      const t = e.target as Node;
      if (popoverRef.current?.contains(t) || triggerRef.current?.contains(t)) return;
      close(false);
    };
    const onMove = () => measure();
    document.addEventListener('pointerdown', onDown);
    window.addEventListener('resize', onMove);
    window.addEventListener('scroll', onMove, true);
    return () => {
      document.removeEventListener('pointerdown', onDown);
      window.removeEventListener('resize', onMove);
      window.removeEventListener('scroll', onMove, true);
    };
  }, [open, measure]);

  // Keep the active option in view.
  useEffect(() => {
    if (!open) return;
    listRef.current?.querySelector<HTMLElement>(`[data-index="${active}"]`)?.scrollIntoView({ block: 'nearest' });
  }, [open, active]);

  const step = (from: number, dir: 1 | -1) => {
    for (let i = from + dir; i >= 0 && i < shown.length; i += dir) {
      if (!shown[i].disabled) return i;
    }
    return from;
  };

  // Keys the list handles stop here: Escape closes the list, not a panel
  // around it, and Enter picks an option rather than submitting the form.
  const onListKey = (e: KeyboardEvent) => {
    if (['ArrowDown', 'ArrowUp', 'Home', 'End', 'Enter', 'Escape'].includes(e.key)) e.stopPropagation();
    switch (e.key) {
      case 'ArrowDown': e.preventDefault(); setActive((a) => step(a, 1)); break;
      case 'ArrowUp': e.preventDefault(); setActive((a) => step(a, -1)); break;
      case 'Home': e.preventDefault(); setActive(step(-1, 1)); break;
      case 'End': e.preventDefault(); setActive(step(shown.length, -1)); break;
      case 'Enter': e.preventDefault(); choose(shown[active]); break;
      case 'Escape': e.preventDefault(); close(); break;
      case 'Tab': close(); break; // back to the trigger, so focus moves on to what follows it
      default:
        if (!showFilter && e.key.length === 1) {
          const now = Date.now();
          typed.current = { text: (now - typed.current.at < 600 ? typed.current.text : '') + e.key.toLowerCase(), at: now };
          const i = shown.findIndex((o) => !o.disabled && o.label.toLowerCase().startsWith(typed.current.text));
          if (i >= 0) setActive(i);
        }
    }
  };

  const onTriggerKey = (e: KeyboardEvent) => {
    if (e.key === 'ArrowDown' || e.key === 'ArrowUp' || e.key === 'Enter' || e.key === ' ') {
      e.preventDefault();
      e.stopPropagation();
      openList();
    }
  };

  return (
    <>
      <button
        ref={triggerRef}
        id={id}
        type="button"
        className={`${styles.trigger} ${inline ? styles.inline : ''}`}
        aria-haspopup="listbox"
        aria-expanded={open}
        aria-controls={open ? listId : undefined}
        aria-label={ariaLabel}
        disabled={disabled}
        onClick={() => (open ? close() : openList())}
        onKeyDown={onTriggerKey}
      >
        <span className={selected ? styles.value : styles.placeholder}>{selected?.label ?? placeholder}</span>
        <ChevronDown size={14} className={styles.chevron} aria-hidden />
      </button>
      {open &&
        place &&
        createPortal(
          <div
            ref={popoverRef}
            className={styles.popover}
            style={{
              left: place.left,
              width: place.width,
              ...(place.up ? { bottom: window.innerHeight - place.top } : { top: place.top }),
            }}
          >
            {showFilter && (
              <input
                ref={filterRef}
                className={styles.filter}
                value={filter}
                placeholder="Filter"
                aria-label="Filter options"
                onChange={(e) => {
                  setFilter(e.target.value);
                  setActive(0);
                }}
                onKeyDown={onListKey}
              />
            )}
            <div
              ref={listRef}
              id={listId}
              role="listbox"
              tabIndex={-1}
              className={styles.list}
              style={{ maxHeight: place.max }}
              aria-activedescendant={shown[active] ? `${listId}-${active}` : undefined}
              onKeyDown={onListKey}
            >
              {shown.length === 0 && <div className={styles.empty}>No matches</div>}
              {shown.map((option, index) => (
                <div
                  key={option.value}
                  id={`${listId}-${index}`}
                  data-index={index}
                  role="option"
                  aria-selected={option.value === value}
                  aria-disabled={option.disabled || undefined}
                  className={[
                    styles.option,
                    index === active ? styles.active : '',
                    option.disabled ? styles.disabled : '',
                  ].join(' ')}
                  onMouseEnter={() => !option.disabled && setActive(index)}
                  onMouseDown={(e) => e.preventDefault()}
                  onClick={() => choose(option)}
                >
                  <span className={styles.check}>{option.value === value && <Check size={13} />}</span>
                  {option.label}
                </div>
              ))}
            </div>
          </div>,
          document.body,
        )}
    </>
  );
}
