import { useState } from 'react';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { CheckCircle2, Link2, QrCode, WifiOff } from 'lucide-react';
import { api } from '@/services/api';
import type { ClaimQr, ClaimStatus } from '@/types';
import Button from '@/components/ui/Button';
import Notice from '@/components/ui/Notice';
import Spinner from '@/components/ui/Spinner';
import { TextAreaField } from '@/components/ui/Field';
import ErrorState from '@/components/ErrorState';
import styles from './Onboarding.module.css';

/**
 * One-touch provisioning: scan, sign in, pick a site, done.
 *
 * This is the whole first-run experience and it is the screen an installer
 * sees most often, so it does one thing and says what is happening at every
 * step. No wizard, no Next button — the QR and the status are on one page,
 * because the installer is holding a phone in the other hand and flipping
 * between steps while transcribing nothing is the point.
 *
 * WHAT IT LOOKS LIKE FROM THE VAN
 *
 *   1. Power the gateway on, join its LAN, open the console.
 *   2. Scan the code with a phone. That opens parkeze.net.
 *   3. Sign in there, pick the organisation.
 *   4. This page notices, on its own, and turns green.
 *
 * Nobody types a credential into the gateway and nobody goes back to it.
 *
 * The gateway polls parkeze.net on its own backoff regardless — this page just
 * polls faster, because somebody is standing there watching it.
 */
export default function Onboarding() {
  const queryClient = useQueryClient();
  const [showOffline, setShowOffline] = useState(false);

  const status = useQuery({
    queryKey: ['claim-status'],
    queryFn: () => api.get<ClaimStatus>('/claim/status'),
    // Fast, because a human is waiting on it. The device's own poll is the
    // slow, backed-off one that runs whether or not this page is open.
    refetchInterval: (query) =>
      query.state.data?.adoption === 'adopted' ? false : 3000,
  });

  const qr = useQuery({
    queryKey: ['claim-qr'],
    queryFn: () => api.get<ClaimQr>('/claim/qr'),
    staleTime: Infinity,
  });

  const check = useMutation({
    mutationFn: () => api.post<ClaimStatus>('/claim/poll'),
    onSuccess: (next) => queryClient.setQueryData(['claim-status'], next),
  });

  if (status.isLoading) return <Spinner label="Preparing this gateway" />;
  if (status.isError) return <ErrorState error={status.error} onRetry={status.refetch} />;

  const claim = status.data!;

  if (claim.adoption === 'adopted') return <Adopted claim={claim} />;

  return (
    <div className={styles.wrap}>
      <div className={`${styles.card} fade-in`}>
        <header className={styles.head}>
          <div className={styles.mark}>P</div>
          <div>
            <h1 className={styles.title}>Claim this gateway</h1>
            <p className={styles.sub}>
              {claim.board ?? 'Parkeze gateway'} · {claim.hostname}
            </p>
          </div>
        </header>

        <div className={styles.qrPane}>
          {qr.isLoading && <Spinner label="Rendering code" />}
          {qr.isError && (
            <Notice tone="error">
              Could not render the claim code. The code below still works —
              type it into parkeze.net.
            </Notice>
          )}
          {qr.data && (
            <div
              className={styles.qr}
              // The SVG is rendered on the device by qrencode and is our own
              // output, not user content. Injected as markup because that is
              // what an SVG is; there is no path by which a remote party
              // supplies bytes that land here.
              dangerouslySetInnerHTML={{ __html: qr.data.svg }}
            />
          )}
        </div>

        <div className={styles.codeRow}>
          <span className={styles.codeLabel}>Or enter this code at parkeze.net/adopt</span>
          <code className={styles.code}>{claim.claimId}</code>
        </div>

        <ol className={styles.steps}>
          <li>Scan the code with your phone.</li>
          <li>Sign in to Parkeze and choose the organisation.</li>
          <li>
            This page finishes on its own — you do not need to come back to the
            gateway.
          </li>
        </ol>

        <div className={styles.statusRow}>
          <Spinner label="Waiting to be claimed" />
          <Button loading={check.isPending} onClick={() => check.mutate()}>
            Check now
          </Button>
        </div>

        {!claim.online && (
          <Notice tone="warning">
            <strong>This gateway has no internet yet.</strong> The code above
            still works — it carries everything parkeze.net needs, so you can
            scan it from a phone with signal. The gateway will finish adopting
            itself as soon as it gets an uplink.
          </Notice>
        )}

        {!claim.registered && claim.online && (
          <Notice tone="info">
            Registering with parkeze.net. The code works either way.
          </Notice>
        )}

        <div className={styles.escape}>
          {showOffline ? (
            <OfflineBundle onDone={() => status.refetch()} />
          ) : (
            <button className={styles.link} onClick={() => setShowOffline(true)}>
              <WifiOff size={13} strokeWidth={2} />
              This gateway will never have internet
            </button>
          )}
        </div>
      </div>
    </div>
  );
}

function Adopted({ claim }: { claim: ClaimStatus }) {
  return (
    <div className={styles.wrap}>
      <div className={`${styles.card} ${styles.done} fade-in`}>
        <CheckCircle2 size={40} strokeWidth={1.6} className={styles.tick} />
        <h1 className={styles.title}>Adopted</h1>
        <p className={styles.sub}>
          This gateway now belongs to <strong>{claim.org}</strong> and is managed
          from parkeze.net. Local sign-in has been turned off.
        </p>
        <Button variant="primary" onClick={() => window.location.reload()}>
          <Link2 size={14} strokeWidth={2} />
          Open the console
        </Button>
      </div>
    </div>
  );
}

/**
 * The escape hatch for a gateway that genuinely cannot reach parkeze.net —
 * a basement, an air-gapped site, a customer network that will not route.
 *
 * parkeze.net produces a signed adoption bundle; the operator carries it back
 * and pastes it here. The gateway verifies it against the fleet public key
 * baked into the image, so this is not a way to adopt a gateway into a
 * tailnet you do not own.
 */
function OfflineBundle({ onDone }: { onDone: () => void }) {
  const [bundle, setBundle] = useState('');

  const apply = useMutation({
    mutationFn: () => api.post('/claim/apply', { bundle: bundle.trim() }),
    onSuccess: onDone,
  });

  return (
    <>
      <p className={styles.escapeNote}>
        Claim the gateway on parkeze.net using the code above, then choose{' '}
        <strong>Offline adoption</strong> there. It will give you a bundle to
        paste here.
      </p>
      <TextAreaField
        label="Adoption bundle"
        placeholder="Paste the signed bundle from parkeze.net"
        spellCheck={false}
        autoCapitalize="off"
        autoCorrect="off"
        value={bundle}
        onChange={(event) => setBundle(event.target.value)}
      />
      {apply.isError && <Notice tone="error">{(apply.error as Error).message}</Notice>}
      <Button
        variant="primary"
        disabled={!bundle.trim()}
        loading={apply.isPending}
        onClick={() => apply.mutate()}
      >
        <QrCode size={14} strokeWidth={2} />
        Adopt this gateway
      </Button>
    </>
  );
}
