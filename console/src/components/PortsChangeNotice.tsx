import Notice from '@/components/ui/Notice';
import Button from '@/components/ui/Button';
import { countdown } from '@/lib/format';
import type { usePortsChange } from '@/hooks/usePortsChange';

/** Where a port change stands, from usePortsChange. */
export default function PortsChangeNotice({ change }: { change: ReturnType<typeof usePortsChange> }) {
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
  if (change.phase === 'undone') return <Notice tone="warning">Undone. The previous ports are back.</Notice>;
  return null;
}
