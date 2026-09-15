import { Component, type ErrorInfo, type ReactNode } from 'react';
import { AlertTriangle } from 'lucide-react';
import Button from './ui/Button';
import styles from './ErrorBoundary.module.css';

/**
 * Keeps one bad value from blanking the whole console.
 *
 * This is not hypothetical. The API declared `firmware.openwrt` as a string
 * and returned the object ubus hands back; React refused to render it, and
 * because nothing caught the throw, the entire page went white — no nav, no
 * error, no way to reach the page that would have shown the problem. On a
 * gateway that is the difference between "one card is wrong" and "the console
 * is down", and the person finding out is often standing in a car park.
 *
 * Scoped around the routed content rather than the whole app, so the sidebar
 * and the topbar survive and you can navigate to a page that still works.
 */
interface State {
  error: Error | null;
}

export default class ErrorBoundary extends Component<
  { children: ReactNode; onReset?: () => void },
  State
> {
  state: State = { error: null };

  static getDerivedStateFromError(error: Error): State {
    return { error };
  }

  componentDidCatch(error: Error, info: ErrorInfo) {
    // There is no error reporting service to call from a device on a pole, so
    // the browser console is where this goes — it is the only place somebody
    // debugging on the bench will look.
    console.error('Console render error:', error, info.componentStack);
  }

  render() {
    if (!this.state.error) return this.props.children;

    return (
      <div className={styles.wrap} role="alert">
        <AlertTriangle size={22} strokeWidth={1.7} className={styles.icon} />
        <h2 className={styles.title}>This page could not be displayed</h2>
        <p className={styles.detail}>{this.state.error.message}</p>
        <p className={styles.hint}>
          The rest of the console still works. If this page is the one you
          need, the gateway is reachable over SSH.
        </p>
        <Button
          onClick={() => {
            this.setState({ error: null });
            this.props.onReset?.();
          }}
        >
          Try again
        </Button>
      </div>
    );
  }
}
