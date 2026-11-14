import { useCallback, useEffect, useRef, useState } from 'react';
import { useQueryClient } from '@tanstack/react-query';
import { api } from '@/services/api';

/**
 * A port change, kept only once this browser reaches the gateway again.
 *
 * pulzr-ports applies a layout at once and undoes it unless it is confirmed
 * inside its window. The confirm comes from here, after the change has had
 * time to take effect: if it gets through, whoever made the change can still
 * reach the gateway and it is kept; if the change cut them off, nothing gets
 * through and the gateway puts the old layout back on its own. The same holds
 * through Pulzar Cloud, where the request rides the tunnel the change may have
 * moved.
 */
export type PortsPhase = 'idle' | 'confirming' | 'kept' | 'undone';

interface Applied {
  pending: { until: number; in: number; confirmableIn: number };
}

export function usePortsChange() {
  const queryClient = useQueryClient();
  const [phase, setPhase] = useState<PortsPhase>('idle');
  const [left, setLeft] = useState(0);
  const [error, setError] = useState<string | null>(null);
  const [applying, setApplying] = useState(false);
  const run = useRef(0);

  useEffect(() => () => { run.current++; }, []);

  const refresh = useCallback(() => {
    for (const key of ['ports', 'network-status', 'backhaul', 'uplinks', 'lan']) {
      queryClient.invalidateQueries({ queryKey: [key] });
    }
  }, [queryClient]);

  const apply = useCallback(async (path: string, body: unknown) => {
    const mine = ++run.current;
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
    setPhase('confirming');
    const deadline = Date.now() + applied.pending.in * 1000;
    const from = Date.now() + applied.pending.confirmableIn * 1000;
    const tick = () => setLeft(Math.max(0, Math.round((deadline - Date.now()) / 1000)));
    tick();
    const timer = window.setInterval(tick, 1000);
    const sleep = (ms: number) => new Promise((resolve) => window.setTimeout(resolve, ms));
    try {
      await sleep(Math.max(0, from - Date.now()));
      while (run.current === mine && Date.now() < deadline) {
        try {
          const answer = await api.post<{ confirmed: boolean }>('/ports/confirm');
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

  const undo = useCallback(async () => {
    run.current++;
    try {
      await api.post('/ports/revert');
      setPhase('undone');
    } catch (e) {
      setError((e as Error).message);
    }
    refresh();
  }, [refresh]);

  return { apply, undo, phase, left, error, applying, reset: () => setPhase('idle') };
}
