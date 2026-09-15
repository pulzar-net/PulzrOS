import { useState } from 'react';
import { useMutation, useQuery } from '@tanstack/react-query';
import { KeyRound, Power, Settings2 } from 'lucide-react';
import { api } from '@/services/api';
import type { SystemSummary } from '@/types';
import Card from '@/components/ui/Card';
import Fact, { FactList } from '@/components/Fact';
import Notice from '@/components/ui/Notice';
import Button from '@/components/ui/Button';
import { TextField } from '@/components/ui/Field';
import PageHeader from '@/components/PageHeader';
import Spinner from '@/components/ui/Spinner';
import ErrorState from '@/components/ErrorState';
import styles from './Pages.module.css';

export default function System() {
  const summary = useQuery({
    queryKey: ['system-summary'],
    queryFn: () => api.get<SystemSummary>('/system/summary'),
  });

  if (summary.isLoading) return <Spinner label="Reading system state" />;
  if (summary.isError) return <ErrorState error={summary.error} onRetry={summary.refetch} />;

  const system = summary.data!;
  const adopted = system.adoption.state === 'adopted';

  return (
    <div className="fade-in">
      <PageHeader title="System" />

      <PasswordCard adopted={adopted} />

      <Card title="Firmware" icon={Settings2}>
        <FactList>
          <Fact
            label="ParkezeOS"
            value={
              system.firmware.version
                ? `${system.firmware.version} (build ${system.firmware.build})`
                : null
            }
          />
          <Fact label="Commit" value={system.firmware.commit} mono />
          <Fact label="OpenWrt" value={system.firmware.openwrt} />
          <Fact label="Kernel" value={system.firmware.kernel} mono />
          <Fact label="Board" value={system.identity.boardName} />
        </FactList>
      </Card>

      <RebootCard />
    </div>
  );
}

function PasswordCard({ adopted }: { adopted: boolean }) {
  const [password, setPassword] = useState('');
  const [confirm, setConfirm] = useState('');

  const mismatch = confirm.length > 0 && password !== confirm;
  const tooShort = password.length > 0 && password.length < 12;

  const save = useMutation({
    mutationFn: () => api.post('/auth/password', { password }),
    onSuccess: () => {
      setPassword('');
      setConfirm('');
    },
  });

  return (
    <Card title="Local password" icon={KeyRound}>
      {adopted && (
        <Notice tone="info">
          This gateway is adopted, so local sign-in is normally disabled and
          this password is unused. It still matters: it is what applies if the
          gateway is ever released back to local management.
        </Notice>
      )}

      <TextField
        label="New password"
        type="password"
        autoComplete="new-password"
        value={password}
        onChange={(event) => setPassword(event.target.value)}
        hint="At least 12 characters."
      />
      <TextField
        label="Confirm"
        type="password"
        autoComplete="new-password"
        value={confirm}
        onChange={(event) => setConfirm(event.target.value)}
      />

      {mismatch && <Notice tone="error">The two passwords do not match.</Notice>}
      {save.isError && <Notice tone="error">{(save.error as Error).message}</Notice>}
      {save.isSuccess && <Notice tone="success">Password changed.</Notice>}

      <div className={styles.actions}>
        <Button
          variant="primary"
          disabled={!password || mismatch || tooShort}
          loading={save.isPending}
          onClick={() => save.mutate()}
        >
          Change password
        </Button>
      </div>
    </Card>
  );
}

function RebootCard() {
  const [confirming, setConfirming] = useState(false);

  const reboot = useMutation({
    mutationFn: () => api.post('/system/reboot'),
  });

  if (reboot.isSuccess) {
    return (
      <Card title="Power" icon={Power}>
        <Notice tone="info">
          Rebooting. This page will not reconnect on its own — reload it in a
          minute.
        </Notice>
      </Card>
    );
  }

  return (
    <Card title="Power" icon={Power}>
      <p className={styles.note}>
        A reboot drops every session and takes about a minute. The packet
        forwarder stops for that time and uplinks in flight are lost.
      </p>

      {reboot.isError && <Notice tone="error">{(reboot.error as Error).message}</Notice>}

      <div className={styles.row}>
        {confirming ? (
          <>
            <Button variant="danger" loading={reboot.isPending} onClick={() => reboot.mutate()}>
              Yes, reboot now
            </Button>
            <Button onClick={() => setConfirming(false)}>Cancel</Button>
          </>
        ) : (
          // Two steps rather than a window.confirm: this console is used on a
          // phone, where a native confirm is easy to dismiss the wrong way.
          <Button variant="danger" onClick={() => setConfirming(true)}>
            <Power size={14} strokeWidth={2} />
            Reboot gateway
          </Button>
        )}
      </div>
    </Card>
  );
}
