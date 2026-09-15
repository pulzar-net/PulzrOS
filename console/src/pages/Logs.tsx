import { useEffect, useRef, useState } from 'react';
import { useQuery } from '@tanstack/react-query';
import { ScrollText } from 'lucide-react';
import { api } from '@/services/api';
import Card from '@/components/ui/Card';
import { CheckboxField, SelectField } from '@/components/ui/Field';
import PageHeader from '@/components/PageHeader';
import Spinner from '@/components/ui/Spinner';
import ErrorState from '@/components/ErrorState';
import styles from './Pages.module.css';

const SIZES = [100, 200, 400, 1000];

export default function Logs() {
  const [lines, setLines] = useState(400);
  const [follow, setFollow] = useState(true);
  const [filter, setFilter] = useState('');
  const viewRef = useRef<HTMLPreElement>(null);

  const logs = useQuery({
    queryKey: ['logs', lines],
    queryFn: () => api.get<{ lines: string[] }>(`/system/logs?lines=${lines}`),
    // Only while following. A log page left open on a desk should not keep
    // waking a gateway that may be on a metered link — the request itself is
    // local, but the gateway is not always the only thing listening.
    refetchInterval: follow ? 5000 : false,
  });

  const visible = (logs.data?.lines ?? []).filter((line) =>
    filter ? line.toLowerCase().includes(filter.toLowerCase()) : true,
  );

  // Stick to the bottom while following, which is where new lines arrive.
  useEffect(() => {
    if (follow && viewRef.current) {
      viewRef.current.scrollTop = viewRef.current.scrollHeight;
    }
  }, [visible.length, follow]);

  return (
    <div className="fade-in">
      <PageHeader title="Logs" />

      <Card
        title="System log"
        icon={ScrollText}
        note={`${visible.length} lines`}
        actions={
          <>
            <SelectField
              label=""
              value={String(lines)}
              onChange={(event) => setLines(Number(event.target.value))}
            >
              {SIZES.map((size) => (
                <option key={size} value={size}>
                  Last {size}
                </option>
              ))}
            </SelectField>
            <CheckboxField
              label="Follow"
              checked={follow}
              onChange={(event) => setFollow(event.target.checked)}
            />
          </>
        }
      >
        <input
          className={styles.filter}
          placeholder="Filter — try 'lora', 'tailscale', 'concentrator'"
          value={filter}
          onChange={(event) => setFilter(event.target.value)}
        />

        {logs.isLoading ? (
          <Spinner label="Reading the log" />
        ) : logs.isError ? (
          <ErrorState error={logs.error} onRetry={logs.refetch} />
        ) : (
          <pre className={styles.log} ref={viewRef}>
            {visible.length ? visible.join('\n') : 'Nothing matches.'}
          </pre>
        )}
      </Card>
    </div>
  );
}
