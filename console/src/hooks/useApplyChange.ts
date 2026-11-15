import { useCallback, useEffect, useRef, useState } from 'react';
import { useQueryClient } from '@tanstack/react-query';
import { api } from '@/services/api';

/**
 * A network change, kept only once this browser reaches the gateway again.
 *
 * The gateway (pulzr-apply) applies a port layout, a cellular or Wi-Fi change,
 * an uplink order or the DNS upstream at once and undoes it unless it is
 * confirmed inside its window. The confirm comes from here, after the change
 * has had time to take effect: if it gets through, whoever made the change can
 * still reach the gateway and it is kept; if the change cut them off, nothing
 * gets through and the gateway puts the old configuration back on its own. The
 * same holds through Pulzar Cloud, where the request rides the tunnel the
 * change may have moved.
 *
 * `apply` posts the change and confirms it. A page that posts its own
 * mutation hands the answer's `pending` to `watch`. An answer without one
 * (a gateway that predates the window) needs no confirm.
 */
export type ApplyPhase = 'idle' | 'confirming' | 'kept' | 'undone';

export interface Pending {
  until: number;
  in: number;
  confirmableIn: number;
}

interface Applied {
  pending?: Pending | null;
}

export function useApplyChange() {
  const queryClient = useQueryClient();
  const [phase, setPhase] = useState<ApplyPhase>('idle');
  const [left, setLeft] = useState(0);
  const [error, setError] = useState<string | null>(null);
  const [applying, setApplying] = useState(false);
  const run = useRef(0);

  useEffect(() => () => { run.current++; }, []);

  const refresh = useCallback(() => {
    for (const key of ['ports', 'network-status', 'backhaul', 'uplinks', 'lan', 'access', 'wifi-detail', 'dns']) {
      queryClient.invalidateQueries({ queryKey: [key] });
    }
  }, [queryClient]);

  const watch = useCallback(async (pending: Pending | null | undefined) => {
    if (!pending) return;
    const mine = ++run.current;
    setError(null);
    setPhase('confirming');
    const deadline = Date.now() + pending.in * 1000;
    const from = Date.now() + pending.confirmableIn * 1000;
    const tick = () => setLeft(Math.max(0, Math.round((deadline - Date.now()) / 1000)));
    tick();
    const timer = window.setInterval(tick, 1000);
    const sleep = (ms: number) => new Promise((resolve) => window.setTimeout(resolve, ms));
    try {
      await sleep(Math.max(0, from - Date.now()));
      while (run.current === mine && Date.now() < deadline) {
        try {
          const answer = await api.post<{ confirmed: boolean }>('/apply/confirm');
          if (run.current !== mine) return;
          // false: nothing was pending any more, so it was undone or kept
          // elsewhere; past the deadline it can only have been undone.
          setPhase(answer.confirmed || Date.now() < deadline ? 'kept' : 'undone');
          refresh();
          return;
        } catch {
          await sleep(2000);
        }
      }
      if (run.current === mine) {
        setPhase('undone');
        refresh();
      }
    } finally {
      window.clearInterval(timer);
    }
  }, [refresh]);

  const apply = useCallback(async (path: string, body: unknown) => {
    setError(null);
    setApplying(true);
    let applied: Applied;
    try {
      applied = await api.post<Applied>(path, body);
    } catch (e) {
      setApplying(false);
      setError((e as Error).message);
      return;
    }
    setApplying(false);
    await watch(applied.pending);
  }, [watch]);

  const undo = useCallback(async () => {
    run.current++;
    try {
      await api.post('/apply/revert');
      setPhase('undone');
    } catch (e) {
      setError((e as Error).message);
    }
    refresh();
  }, [refresh]);

  return { apply, watch, undo, phase, left, error, applying, reset: () => setPhase('idle') };
}
