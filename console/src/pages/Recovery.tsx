import { useState } from 'react';
import { useMutation, useQuery } from '@tanstack/react-query';
import { api } from '@/services/api';
import { useSession } from '@/contexts/SessionContext';
import type { RecoveryChallenge, Session } from '@/types';
import Button from '@/components/ui/Button';
import Notice from '@/components/ui/Notice';
import Spinner from '@/components/ui/Spinner';
import { TextAreaField } from '@/components/ui/Field';
import styles from './Login.module.css';

/**
 * Offline recovery: getting into an adopted gateway that cannot reach
 * parkeze.net.
 *
 * The gateway holds only a *public* key, so nothing stored on it grants
 * access — dump the flash of a stolen unit and you get nothing. Instead it
 * prints a challenge, an operator carries it to parkeze.net on a phone, and
 * brings back a signature over those exact bytes. See ParkezeOS docs/auth.md
 * for why a stored break-glass password would be the wrong answer.
 *
 * The screen is two numbered steps on one card, deliberately. Somebody using
 * this is standing at a cabinet in the rain with a phone in one hand; a wizard
 * with a Next button between the code and the field it pairs with would mean
 * flipping back and forth while transcribing.
 */
export default function Recovery({
  canGoBack,
  onBack,
}: {
  canGoBack: boolean;
  onBack: () => void;
}) {
  const { signIn } = useSession();
  const [signature, setSignature] = useState('');

  const challenge = useQuery({
    queryKey: ['recovery-challenge'],
    // A POST, because minting a challenge is not a read — it allocates a nonce
    // the gateway will accept exactly once.
    queryFn: () => api.post<RecoveryChallenge>('/auth/recovery/challenge'),
    // One challenge per visit. Refetching on focus would hand the operator a
    // new nonce halfway through transcribing the old one.
    refetchOnWindowFocus: false,
    retry: false,
    staleTime: Infinity,
  });

  const verify = useMutation({
    mutationFn: () =>
      api.post<Session>('/auth/recovery/verify', { signature: signature.trim() }),
    onSuccess: signIn,
  });

  return (
    <>
      <h1 className={styles.title}>Recovery access</h1>
      <p className={styles.sub}>
        For an adopted gateway that cannot reach parkeze.net. You will need a
        second device with internet and a Parkeze network-admin account.
      </p>

      {challenge.isLoading && <Spinner label="Preparing a challenge" />}

      {challenge.isError && (
        <Notice tone="error">{(challenge.error as Error).message}</Notice>
      )}

      {challenge.data && (
        <>
          <div className={styles.step}>
            <span className={styles.stepLabel}>1. Give this code to parkeze.net</span>
            <code className={styles.code}>{challenge.data.challenge.code}</code>
            <p className={styles.hint}>
              Expires in {Math.max(0, Math.round(challenge.data.challenge.expiresIn / 60))}{' '}
              minutes. On parkeze.net: Fleet → this gateway → Console access.
            </p>
          </div>

          <TextAreaField
            label="2. Paste the signature it gives you back"
            placeholder="Base64 signature from parkeze.net"
            spellCheck={false}
            autoCapitalize="off"
            autoCorrect="off"
            value={signature}
            onChange={(event) => setSignature(event.target.value)}
          />

          {verify.isError && (
            <Notice tone="error">{(verify.error as Error).message}</Notice>
          )}

          <div className={styles.row}>
            <Button
              variant="primary"
              disabled={!signature.trim()}
              loading={verify.isPending}
              onClick={() => verify.mutate()}
            >
              Unlock
            </Button>
            <div className={styles.spacer} />
            {canGoBack && <Button onClick={onBack}>Back to sign in</Button>}
          </div>
        </>
      )}
    </>
  );
}
