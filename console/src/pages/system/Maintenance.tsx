import { useState } from 'react';
import { useMutation, useQuery } from '@tanstack/react-query';
import { KeyRound, PackageCheck, Power, Upload } from 'lucide-react';
import { api, upload } from '@/services/api';
import type { SystemSummary } from '@/types';
import Section from '@/components/ui/Section';
import Fact, { FactList } from '@/components/Fact';
import Notice from '@/components/ui/Notice';
import Button from '@/components/ui/Button';
import { TextField } from '@/components/ui/Field';
import Spinner from '@/components/ui/Spinner';
import ErrorState from '@/components/ErrorState';
import styles from '../Pages.module.css';

export default function Maintenance() {
  const summary = useQuery({
    queryKey: ['system-summary'],
    queryFn: () => api.get<SystemSummary>('/system/summary'),
  });

  if (summary.isLoading) return <Spinner label="Reading system state" />;
  if (summary.isError) return <ErrorState error={summary.error} onRetry={summary.refetch} />;

  const system = summary.data!;

  return (
    <div className="fade-in">
      <PasswordCard />

      <Section title="Firmware" icon={PackageCheck}>
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
        <FirmwareUpload />
      </Section>

      <RebootCard />
    </div>
  );
}

function PasswordCard() {
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
    <Section title="Local Password" icon={KeyRound}>
      <TextField
        label="New password"
        type="password"
        autoComplete="new-password"
        value={password}
        onChange={(event) => setPassword(event.target.value)}
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
    </Section>
  );
}

/**
 * Replacing the firmware in place, from a sysupgrade image.
 *
 * The gateway checks the image is for this board before it writes anything,
 * and keeps its settings and its identity across the upgrade. Two steps —
 * choose, then confirm — because the second one takes the gateway down.
 */
function FirmwareUpload() {
  const [file, setFile] = useState<File | null>(null);
  const [manifest, setManifest] = useState<File | null>(null);
  const [progress, setProgress] = useState(0);

  const send = useMutation({
    mutationFn: async (image: File) => {
      // Read here rather than in the api helper: it is a header, so it has to
      // be a string before the request starts, and File.text() is a promise.
      const headers = manifest
        ? { 'X-Parkeze-Manifest': (await manifest.text()).trim() }
        : undefined;
      return upload<{ target?: string; openwrt?: string; signed?: boolean }>(
        '/system/firmware', image, setProgress, headers,
      );
    },
  });

  if (send.isSuccess) {
    return (
      <Notice tone="info">
        Upgrading. Reload in a few minutes.
      </Notice>
    );
  }

  return (
    <>
      <div className={styles.row}>
        <label className={styles.fileButton}>
          <Upload size={14} strokeWidth={2} />
          {file ? file.name : 'Choose image'}
          <input
            type="file"
            accept=".bin,.img,.gz"
            hidden
            onChange={(event) => {
              setFile(event.target.files?.[0] ?? null);
              send.reset();
              setProgress(0);
            }}
          />
        </label>
        {file && (
          <label className={styles.fileButton}>
            <Upload size={14} strokeWidth={2} />
            {manifest ? manifest.name : 'Signature (optional)'}
            <input
              type="file"
              accept=".json"
              hidden
              onChange={(event) => {
                setManifest(event.target.files?.[0] ?? null);
                send.reset();
              }}
            />
          </label>
        )}
        {file && (
          <Button
            variant="danger"
            loading={send.isPending}
            onClick={() => send.mutate(file)}
          >
            Upgrade
          </Button>
        )}
      </div>

      {send.isPending && (
        <progress className={styles.progress} value={progress} max={1} />
      )}
      {send.isError && <Notice tone="error">{(send.error as Error).message}</Notice>}
    </>
  );
}

function RebootCard() {
  const [confirming, setConfirming] = useState(false);

  const reboot = useMutation({
    mutationFn: () => api.post('/system/reboot'),
  });

  if (reboot.isSuccess) {
    return (
      <Section title="Power" icon={Power}>
        <Notice tone="info">
          Rebooting. Reload in a minute.
        </Notice>
      </Section>
    );
  }

  return (
    <Section title="Power" icon={Power}>
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
    </Section>
  );
}
