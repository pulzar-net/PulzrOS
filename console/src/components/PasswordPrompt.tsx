import { useState } from 'react';
import { useMutation } from '@tanstack/react-query';
import { KeyRound } from 'lucide-react';
import { api } from '@/services/api';
import { useSession } from '@/contexts/SessionContext';
import Button from './ui/Button';
import Notice from './ui/Notice';
import { TextField } from './ui/Field';
import Brand from './Brand';
import styles from '@/pages/Login.module.css';

/**
 * Forced password change on first sign-in.
 *
 * A gateway ships with a password generated on first boot and printed on the
 * serial banner — unique per unit, but written down somewhere and readable by
 * anyone who has been near the device. Until it is replaced, the console is
 * not reachable.
 *
 * This is a gate rather than a banner deliberately. The previous PulzrOS
 * shipped one fleet-wide default and relied on people changing it, which is
 * the same as not having a password.
 */
export default function PasswordPrompt() {
  const { session, signIn, signOut } = useSession();
  const [password, setPassword] = useState('');
  const [confirm, setConfirm] = useState('');

  const mismatch = confirm.length > 0 && password !== confirm;
  const tooShort = password.length > 0 && password.length < 12;

  const save = useMutation({
    mutationFn: () => api.post('/auth/password', { password }),
    onSuccess: () => {
      if (session) signIn({ ...session, mustChangePassword: false });
    },
  });

  return (
    <div className={styles.wrap}>
      <div className={`${styles.card} fade-in`}>
        <div className={styles.brand}>
          <Brand size="md" sub="Gateway console" />
        </div>

        <h1 className={styles.title}>Choose a password</h1>

        <TextField
          label="New password"
          type="password"
          autoComplete="new-password"
          autoFocus
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

        <div className={styles.row}>
          <Button
            variant="primary"
            disabled={!password || mismatch || tooShort}
            loading={save.isPending}
            onClick={() => save.mutate()}
          >
            <KeyRound size={14} strokeWidth={2} />
            Set password
          </Button>
          <div className={styles.spacer} />
          <Button onClick={signOut}>Sign out</Button>
        </div>
      </div>
    </div>
  );
}
