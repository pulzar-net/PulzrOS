import Notice from '@/components/ui/Notice';
import Button from '@/components/ui/Button';
import { countdown } from '@/lib/format';
import type { useApplyChange } from '@/hooks/useApplyChange';

/** Where a change stands, from useApplyChange. */
export default function ApplyChangeNotice({ change }: { change: ReturnType<typeof useApplyChange> }) {
  if (change.error) return <Notice tone="error">{change.error}</Notice>;
  if (change.phase === 'confirming') {
    return (
      <Notice tone="warning">
        Reaching the gateway again. Undone in {countdown(change.left)} if nothing does.{' '}
        <Button onClick={change.undo}>Undo Now</Button>
      </Notice>
    );
  }
  if (change.phase === 'kept') return <Notice tone="success">Applied.</Notice>;
  if (change.phase === 'undone') return <Notice tone="warning">Undone. The previous settings are back.</Notice>;
  return null;
}
