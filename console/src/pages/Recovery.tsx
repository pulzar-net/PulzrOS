import { useEffect, useState } from 'react';
import { useMutation, useQuery } from '@tanstack/react-query';
import { api } from '@/services/api';
import { useSession } from '@/contexts/SessionContext';
import type { RecoveryChallenge, Session } from '@/types';

interface AdoptionCheck {
  checking?: boolean;
  adopted?: boolean;
  checked?: boolean;
  released?: boolean;
  reason?: string;
}
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
  const [checking, setChecking] = useState(false);

  // "Is this gateway still adopted?"
  //
  // Recovery is for an adopted gateway that cannot reach Parkeze. If it was
  // decommissioned from the console there is nobody left to sign the
  // challenge, and the operator should be claiming it again instead — but
  // from here that looks identical to a signature that keeps being refused.
  //
  // The answer comes from parkeze.net, not from this button. The device asks,
  // twice, over TLS, with its own credential; only that can return it to
  // adoption. Pressing this cannot unadopt a working gateway, and neither can
  // anyone else who reaches this screen.
  const check = useQuery({
    queryKey: ['adoption-check'],
    queryFn: () => api.get<AdoptionCheck>('/claim/check-adoption'),
    enabled: checking,
    refetchInterval: (query) =>
      (query.state.data as AdoptionCheck | undefined)?.checking === false ? false : 3000,
    retry: false,
  });

  const start = useMutation({
    mutationFn: () => api.post('/claim/check-adoption'),
    onSuccess: () => setChecking(true),
  });

  const result = check.data;
  // A gateway that came back unadopted has already released itself locally.
  // Reloading is what drops it to the adoption screen — which screen to show
  // is the router's decision from session state, not a navigation to make
  // from here. In an effect, not in render: a reload fired during render runs
  // again on every render until it lands.
  const released = result?.adopted === false && result?.released === true;
  useEffect(() => {
    if (released) window.location.reload();
  }, [released]);

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
      {challenge.isLoading && <Spinner label="Preparing a challenge" />}

      {challenge.isError && (
        <Notice tone="error">{(challenge.error as Error).message}</Notice>
      )}

      {challenge.data && (
        <>
          <div className={styles.step}>
            <span className={styles.stepLabel}>1. Give this code to Parkeze</span>
            <code className={styles.code}>{challenge.data.challenge.code}</code>
            <p className={styles.hint}>
              Expires in {Math.max(0, Math.round(challenge.data.challenge.expiresIn / 60))}{' '}
              minutes.
            </p>
          </div>

          <TextAreaField
            label="2. Paste the signature it gives you back"
            placeholder="Base64 signature from Parkeze"
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

          <div className={styles.step}>
            <Button
              loading={start.isPending || (checking && result?.checking !== false)}
              onClick={() => start.mutate()}
            >
              Check with Parkeze
            </Button>
            {result?.checked === false && result.reason && (
              <p className={styles.hint}>
                {result.reason === 'unreachable'
                  ? 'Could not reach Parkeze. Nothing changed.'
                  : `No answer: ${result.reason}. Nothing changed.`}
              </p>
            )}
            {result?.checked && result.adopted && (
              <p className={styles.hint}>Still adopted.</p>
            )}
          </div>
        </>
      )}
    </>
  );
}
