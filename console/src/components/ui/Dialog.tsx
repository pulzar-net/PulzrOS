import { useEffect, useRef, type ReactNode } from 'react';
import { X } from 'lucide-react';
import styles from './Dialog.module.css';

/**
 * A modal on the browser's own <dialog>: focus trapping, Escape and the
 * backdrop come with the element rather than being rebuilt here.
 */
export default function Dialog({
  open,
  onClose,
  title,
  actions,
  footer,
  size = 'large',
  children,
}: {
  open: boolean;
  onClose: () => void;
  title: string;
  actions?: ReactNode;
  footer?: ReactNode;
  // compact sizes to its content: a question with a couple of facts, not a
  // table that needs the screen.
  size?: 'large' | 'compact';
  children: ReactNode;
}) {
  const ref = useRef<HTMLDialogElement>(null);

  useEffect(() => {
    const dialog = ref.current;
    if (!dialog) return;
    if (open && !dialog.open) dialog.showModal();
    if (!open && dialog.open) dialog.close();
  }, [open]);

  return (
    <dialog
      ref={ref}
      className={`${styles.dialog} ${size === 'compact' ? styles.compact : ''}`}
      onClose={onClose}
      // A click on the backdrop lands on the dialog element itself.
      onClick={(event) => event.target === event.currentTarget && onClose()}
    >
      {open && (
        <div className={styles.frame}>
          <header className={styles.header}>
            <h2 className={styles.title}>{title}</h2>
            <div className={styles.actions}>{actions}</div>
            <button className={styles.close} onClick={onClose} aria-label="Close">
              <X size={16} strokeWidth={2} />
            </button>
          </header>
          <div className={styles.body}>{children}</div>
          {footer && <footer className={styles.footer}>{footer}</footer>}
        </div>
      )}
    </dialog>
  );
}
