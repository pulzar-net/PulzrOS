import { useEffect, useState, type ReactNode } from 'react';
import { useMutation, useQuery } from '@tanstack/react-query';
import { ChevronRight, CircleCheck, CircleX, Plus, RefreshCw, ShieldCheck, Timer } from 'lucide-react';
import { api } from '@/services/api';
import type { AccessStatus, WifiNetwork } from '@/types';
import Dialog from '@/components/ui/Dialog';
import Button from '@/components/ui/Button';
import Notice from '@/components/ui/Notice';
import Spinner from '@/components/ui/Spinner';
import Badge from '@/components/ui/Badge';
import Fact, { FactList } from '@/components/Fact';
import { CheckboxField, SelectField, TextField } from '@/components/ui/Field';
import { explain, type WifiFailureInfo } from './WifiFailure';
import { SECURITY_NAMES, UPLINK_WARNING, commonName, fingerprint, signalBars } from './wifiFormat';
import styles from './Wifi.module.css';

/**
 * Joining a WiFi network, one question at a time: which network, what it
 * asks for, whether to trust its server (802.1X only), and whether it worked.
 *
 * It used to be a form under the page's state, with the scan list, every
 * field for every kind of network and the certificate question all on screen
 * at once, and the outcome left for the technician to find in the facts
 * above. Each step here shows only what that step needs, and the last one
 * stays until the gateway has either connected or said why not.
 */

type Step = 'network' | 'credentials' | 'certificate' | 'joining';
type Security = 'psk' | 'open' | 'eap';
type Method = 'peap' | 'ttls-pap' | 'ttls-mschapv2';

interface ProbeResult {
  state: 'none' | 'probing' | 'done' | 'failed';
  ssid?: string;
  error?: string;
  chain: { depth: number; subject: string; hash: string }[];
}

// How long the last step waits for the gateway to connect before saying it
// has not. An 802.1X join that is going to work has done so well inside this.
const JOIN_WAIT = 60_000;

export default function JoinWizard({
  open,
  rejoin,
  wifi,
  failure,
  onClose,
  onJoined,
  onFailureShown,
}: {
  open: boolean;
  /** A saved network the page has just rejoined: open on its outcome. */
  rejoin?: string;
  wifi: AccessStatus['wifi'];
  failure: WifiFailureInfo | null | undefined;
  onClose: () => void;
  onJoined: () => void;
  /** This failure has been shown here, so the page need not announce it. */
  onFailureShown: () => void;
}) {
  const [step, setStep] = useState<Step>('network');
  const [ssid, setSsid] = useState('');
  const [typed, setTyped] = useState(false);
  const [typedSecurity, setTypedSecurity] = useState<Security>('psk');
  const [passphrase, setPassphrase] = useState('');
  const [allowOpen, setAllowOpen] = useState(false);
  const [method, setMethod] = useState<Method>('peap');
  const [identity, setIdentity] = useState('');
  const [password, setPassword] = useState('');
  const [anonymousIdentity, setAnonymousIdentity] = useState('');
  const [showAnonymous, setShowAnonymous] = useState(false);
  const [probing, setProbing] = useState(false);
  const [failureBefore, setFailureBefore] = useState<string | null>(null);
  const [joinedAt, setJoinedAt] = useState(0);
  const [now, setNow] = useState(Date.now());

  // Every opening starts over. Reopened on a half-typed password from last
  // time, a wizard is just the old form again.
  useEffect(() => {
    if (!open) return;
    setStep(rejoin ? 'joining' : 'network');
    setSsid(rejoin ?? '');
    setTyped(false);
    setPassphrase('');
    setAllowOpen(false);
    setIdentity('');
    setPassword('');
    setAnonymousIdentity('');
    setShowAnonymous(false);
    setProbing(false);
    setFailureBefore(rejoin ? (failure?.at ?? null) : null);
    setJoinedAt(Date.now());
    // Only on opening: `failure` changing while it is open is the outcome
    // being waited for, not a reason to start again.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [open, rejoin]);

  const scan = useQuery({
    queryKey: ['wifi-scan'],
    queryFn: () =>
      api.get<{ capable: boolean; networks: WifiNetwork[]; error?: string }>('/access/scan'),
    enabled: open,
    // Scanning takes the radio away from whatever it is doing; not on a timer.
    refetchOnWindowFocus: false,
    staleTime: Infinity,
  });

  const scanned = typed ? undefined : scan.data?.networks.find((n) => n.ssid === ssid);
  const security: Security = scanned?.encryption ?? typedSecurity;
  const isEap = security === 'eap';
  const eapMethod = method === 'peap' ? 'peap' : 'ttls';
  const phase2 = method === 'ttls-pap' ? 'PAP' : 'MSCHAPV2';

  // The certificate check runs on the gateway in the background (the radio
  // has to come up and RADIUS has to answer), so it is started, then polled.
  const startProbe = useMutation({
    mutationFn: () =>
      api.post('/access/wifi/probe', {
        ssid: ssid.trim(),
        method: eapMethod,
        identity: identity.trim(),
        anonymousIdentity: anonymousIdentity.trim() || undefined,
      }),
    onSuccess: () => setProbing(true),
  });

  const probe = useQuery({
    queryKey: ['wifi-probe'],
    queryFn: () => api.get<ProbeResult>('/access/wifi/probe'),
    enabled: probing,
    refetchInterval: (query) => (query.state.data?.state === 'probing' ? 2000 : false),
    // A setup-AP caller loses the radio while the probe runs; keep asking.
    retry: true,
  });

  const result = probing && probe.data?.ssid === ssid.trim() ? probe.data : undefined;
  const checking = startProbe.isPending || (probing && (!result || result.state === 'probing'));
  const leaf = result?.state === 'done' ? result.chain.find((c) => c.depth === 0) : undefined;
  const issuer = result?.state === 'done' ? result.chain.find((c) => c.depth === 1) : undefined;
  const root =
    result?.state === 'done' && result.chain.length > 2
      ? result.chain.reduce((top, c) => (c.depth > top.depth ? c : top))
      : undefined;

  const join = useMutation({
    // The failure on record before this join, so the outcome step can tell a
    // new one from the one that may have prompted it.
    onMutate: () => setFailureBefore(failure?.at ?? null),
    mutationFn: () =>
      api.post<{ message: string }>('/access/wifi', {
        ssid: ssid.trim(),
        ...(isEap
          ? {
              eap: {
                method: eapMethod,
                phase2,
                identity: identity.trim(),
                anonymousIdentity: anonymousIdentity.trim() || undefined,
                password,
                certHash: leaf!.hash,
                certSubject: leaf!.subject,
              },
            }
          : { key: passphrase || undefined, allowOpen }),
      }),
    onSuccess: () => {
      setProbing(false);
      setJoinedAt(Date.now());
      setStep('joining');
      onJoined();
    },
  });

  // The outcome step re-renders on a clock as well as on the page's polls, so
  // it can say "not yet" once the wait is over.
  useEffect(() => {
    if (!open || step !== 'joining') return;
    const timer = setInterval(() => setNow(Date.now()), 2000);
    return () => clearInterval(timer);
  }, [open, step]);

  const fresh = step === 'joining' && failure && failure.at !== failureBefore ? failure : null;
  const connected = wifi.configured && wifi.ssid === ssid.trim() && wifi.up;
  const overdue = now - joinedAt > JOIN_WAIT;

  useEffect(() => {
    if (fresh && !connected) onFailureShown();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [fresh?.at, connected]);

  const choose = (network: WifiNetwork) => {
    setSsid(network.ssid);
    setTyped(false);
    setAllowOpen(false);
    setProbing(false);
    setStep('credentials');
  };

  const other = () => {
    setSsid('');
    setTyped(true);
    setProbing(false);
    setStep('credentials');
  };

  const checkCertificate = () => {
    setStep('certificate');
    startProbe.mutate();
  };

  const credentialsReady =
    !!ssid.trim() &&
    (isEap
      ? !!identity.trim() && !!password
      : security === 'psk'
        ? !!passphrase
        : allowOpen);

  const name = ssid.trim();
  const title =
    step === 'network'
      ? 'Join a network'
      : step === 'certificate'
        ? `Trust ${name}?`
        : step === 'joining'
          ? name
          : name ? `Join ${name}` : 'Join a network';

  let body: ReactNode = null;
  let footer: ReactNode = null;

  if (step === 'network') {
    const networks = (scan.data?.networks ?? []).slice().sort((a, b) => b.quality - a.quality);
    body = scan.data && !scan.data.capable ? (
      <Notice tone="info">This board has no WiFi radio.</Notice>
    ) : (
      <>
        {scan.data?.error && <Notice tone="info">{scan.data.error}</Notice>}
        {scan.isLoading && <Spinner label="Scanning" />}
        <ul className={`${styles.list} ${scan.isFetching && !scan.isLoading ? styles.stale : ''}`}>
          {networks.map((network) => {
            const bars = signalBars(network.signal);
            const Bars = bars.icon;
            const here = wifi.configured && wifi.ssid === network.ssid && wifi.up;
            return (
              <li key={network.ssid}>
                <button className={styles.network} onClick={() => choose(network)}>
                  <Bars size={16} strokeWidth={2} className={`${styles.bars} ${styles[bars.tone]}`} />
                  <span className={styles.ssid}>{network.ssid}</span>
                  {here && <span className={styles.current}>Connected</span>}
                  <span className={`${styles.tag} ${network.encryption === 'open' ? styles.open : ''}`}>
                    {SECURITY_NAMES[network.encryption]}
                  </span>
                  <ChevronRight size={14} strokeWidth={2} className={styles.chevron} />
                </button>
              </li>
            );
          })}
          <li>
            <button className={styles.network} onClick={other}>
              <Plus size={16} strokeWidth={2} className={styles.chevron} />
              <span className={styles.ssid}>Other Network</span>
              <ChevronRight size={14} strokeWidth={2} className={styles.chevron} />
            </button>
          </li>
        </ul>
      </>
    );
    footer = <Button onClick={onClose}>Cancel</Button>;
  }

  if (step === 'credentials') {
    const bars = signalBars(scanned?.signal);
    const Bars = bars.icon;
    body = (
      <div className={styles.fields}>
        {!typed && name && (
          <div className={styles.target}>
            <Bars size={16} strokeWidth={2} className={`${styles.bars} ${styles[bars.tone]}`} />
            <span className={styles.ssid}>{name}</span>
            <span className={styles.tag}>{SECURITY_NAMES[security]}</span>
          </div>
        )}
        {typed && (
          <>
            <TextField
              label="Network name"
              autoFocus
              value={ssid}
              onChange={(event) => setSsid(event.target.value)}
            />
            <SelectField<Security>
              label="Security"
              value={typedSecurity}
              onChange={setTypedSecurity}
              options={[
                { value: 'psk', label: 'Password' },
                { value: 'eap', label: 'Username and password' },
                { value: 'open', label: 'None' },
              ]}
            />
          </>
        )}

        {security === 'psk' && (
          <TextField
            label="Passphrase"
            type="password"
            autoComplete="off"
            autoFocus={!typed}
            value={passphrase}
            onChange={(event) => setPassphrase(event.target.value)}
          />
        )}

        {security === 'open' && (
          <>
            <Notice tone="warning">
              <strong>{name || 'This'}</strong> is an open network.
            </Notice>
            <CheckboxField
              label="Use this open network anyway"
              checked={allowOpen}
              onChange={(event) => setAllowOpen(event.target.checked)}
            />
          </>
        )}

        {isEap && (
          <>
            <SelectField<Method>
              label="Method"
              value={method}
              onChange={setMethod}
              options={[
                { value: 'peap', label: 'PEAP (MSCHAPv2)' },
                { value: 'ttls-pap', label: 'TTLS (PAP)' },
                { value: 'ttls-mschapv2', label: 'TTLS (MSCHAPv2)' },
              ]}
            />
            <TextField
              label="Username"
              autoComplete="off"
              autoFocus={!typed}
              value={identity}
              onChange={(event) => setIdentity(event.target.value)}
            />
            <TextField
              label="Password"
              type="password"
              autoComplete="off"
              value={password}
              onChange={(event) => setPassword(event.target.value)}
            />
            {showAnonymous ? (
              <TextField
                label="Anonymous identity"
                autoComplete="off"
                placeholder="anonymous@example.edu"
                value={anonymousIdentity}
                onChange={(event) => setAnonymousIdentity(event.target.value)}
              />
            ) : (
              <button className={styles.more} onClick={() => setShowAnonymous(true)}>
                Anonymous identity
              </button>
            )}
          </>
        )}

        {!isEap && join.isError && <Notice tone="error">{(join.error as Error).message}</Notice>}
      </div>
    );
    footer = (
      <>
        <Button onClick={() => setStep('network')}>Back</Button>
        {isEap ? (
          <Button variant="primary" disabled={!credentialsReady} onClick={checkCertificate}>
            Next
          </Button>
        ) : (
          <Button
            variant="primary"
            disabled={!credentialsReady}
            loading={join.isPending}
            onClick={() => join.mutate()}
          >
            Join
          </Button>
        )}
      </>
    );
  }

  // The question a phone asks on first join, asked before the password goes
  // anywhere. Going back forgets the probe, so the next attempt checks the
  // certificate again rather than trusting a stale one.
  if (step === 'certificate') {
    const failed = startProbe.isError
      ? (startProbe.error as Error).message
      : result?.state === 'failed'
        ? result.error
        : null;
    body = failed ? (
      <Notice tone="error">{failed}</Notice>
    ) : checking || !leaf ? (
      <Spinner label="Checking certificate" />
    ) : (
      <>
        <div className={styles.trust}>
          <div className={styles.trustHead}>
            <ShieldCheck size={16} strokeWidth={2} />
            {commonName(leaf.subject)}
          </div>
          <FactList>
            {issuer && <Fact label="Issued by" value={commonName(issuer.subject)} />}
            {root && <Fact label="Root" value={commonName(root.subject)} />}
            <Fact
              label="SHA-256"
              value={<span className={styles.fingerprint}>{fingerprint(leaf.hash)}</span>}
              mono
            />
          </FactList>
        </div>
        {join.isError && <Notice tone="error">{(join.error as Error).message}</Notice>}
      </>
    );
    footer = (
      <>
        <Button
          onClick={() => {
            setProbing(false);
            join.reset();
            setStep('credentials');
          }}
        >
          Back
        </Button>
        <Button
          variant="primary"
          disabled={!leaf || checking}
          loading={join.isPending}
          onClick={() => join.mutate()}
        >
          Trust and join
        </Button>
      </>
    );
  }

  if (step === 'joining') {
    if (connected) {
      const warning = UPLINK_WARNING[wifi.configured ? wifi.uplink : ''];
      body = (
        <div className={styles.outcome}>
          <CircleCheck size={40} strokeWidth={1.8} className={`${styles.outcomeIcon} ${styles.ok}`} />
          <div className={styles.outcomeTitle}>Connected to {name}</div>
          {warning && <Badge tone="warning">{warning}</Badge>}
          <p className={styles.explain}>{wifi.configured ? wifi.address : null}</p>
        </div>
      );
    } else if (fresh) {
      const why = explain(fresh, name);
      body = (
        <div className={styles.outcome}>
          <CircleX size={40} strokeWidth={1.8} className={`${styles.outcomeIcon} ${styles.bad}`} />
          <div className={styles.outcomeTitle}>{why.title}</div>
          <p className={styles.explain}>{why.meaning}</p>
          <p className={styles.explain}>{why.fix}</p>
        </div>
      );
    } else if (overdue) {
      body = (
        <div className={styles.outcome}>
          <Timer size={40} strokeWidth={1.8} className={`${styles.outcomeIcon} ${styles.wait}`} />
          <div className={styles.outcomeTitle}>{name} has not connected</div>
        </div>
      );
    } else {
      body = (
        <div className={styles.outcome}>
          <Spinner label={`Connecting to ${name}`} />
        </div>
      );
    }
    footer = (
      <>
        {fresh && !connected && !rejoin && (
          <Button onClick={() => setStep('credentials')}>Back</Button>
        )}
        <Button variant={connected ? 'primary' : 'default'} onClick={onClose}>
          {connected ? 'Done' : 'Close'}
        </Button>
      </>
    );
  }

  return (
    <Dialog
      open={open}
      onClose={onClose}
      size="compact"
      title={title}
      actions={
        step === 'network' && scan.data?.capable !== false ? (
          <Button loading={scan.isFetching} onClick={() => scan.refetch()}>
            <RefreshCw size={13} strokeWidth={2} />
            Scan
          </Button>
        ) : undefined
      }
      footer={footer}
    >
      <Steps at={step} eap={isEap} />
      {body}
    </Dialog>
  );
}

/** Where the wizard is: network, credentials, the certificate (802.1X only),
    the outcome. */
function Steps({ at, eap }: { at: Step; eap: boolean }) {
  const steps: Step[] = eap ? ['network', 'credentials', 'certificate', 'joining'] : ['network', 'credentials', 'joining'];
  const reached = steps.indexOf(at);
  return (
    <div className={styles.steps} aria-hidden>
      {steps.map((s, i) => (
        <span key={s} className={`${styles.step} ${i <= reached ? styles.done : ''}`} />
      ))}
    </div>
  );
}
