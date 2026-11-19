import { useState } from 'react';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { Lock, Unlock, Wifi as WifiIcon, WifiOff } from 'lucide-react';
import { api } from '@/services/api';
import type { AccessStatus } from '@/types';
import Section from '@/components/ui/Section';
import Badge from '@/components/ui/Badge';
import Fact from '@/components/Fact';
import { duration } from '@/lib/format';
import Notice from '@/components/ui/Notice';
import Button from '@/components/ui/Button';
import Spinner from '@/components/ui/Spinner';
import ErrorState from '@/components/ErrorState';
import ApplyChangeNotice from '@/components/ApplyChangeNotice';
import { useApplyChange, type Pending } from '@/hooks/useApplyChange';
import WifiFailure, { explain, useFailurePopup, type WifiFailureInfo } from './WifiFailure';
import JoinWizard from './JoinWizard';
import { useWifiSignIn } from './signin';
import { SECURITY_NAMES, commonName, signalBars } from './wifiFormat';
import styles from './Wifi.module.css';

/**
 * WiFi as an uplink: between ethernet and cellular in preference — better than
 * paying for data, worse than a cable.
 *
 * The page is the network the gateway is on and the ones it remembers.
 * Joining another is JoinWizard's, in a dialog, so that the page is not a
 * form with the state of the gateway above it.
 */
interface SavedNetwork {
  ssid: string;
  security: 'psk' | 'open' | 'eap';
  identity?: string;
  certSubject?: string;
  certHash?: string;
  lastJoined: number | null;
  active: boolean;
}

/** pulzr-wifi-uplink's answer. `reason` ends the sentence that starts with
    the network's name; null when open or when the badge says it all. */
interface UplinkCheck {
  state: 'open' | 'portal' | 'offline' | 'unchecked';
  step?: string | null;
  reason?: string | null;
  checkedAt?: number | null;
}

/** The last switch roam() made. `at` is Unix seconds. */
interface Roam {
  at: number;
  from: string;
  to: string;
  reason: string;
}

interface WifiDetail {
  configured: boolean;
  /** The network's sign-in page, while it has one. */
  portal?: string | null;
  uplink?: UplinkCheck;
  roam?: Roam | null;
  identity?: string;
  method?: string;
  certSubject?: string;
  certHash?: string;
  failure?: WifiFailureInfo | null;
  saved: SavedNetwork[];
}

export default function Wifi() {
  const queryClient = useQueryClient();
  const change = useApplyChange();
  // For a minute after a join or a rejoin, ask every two seconds: whether it
  // worked, and why not, should land while somebody is still looking.
  const [watchUntil, setWatchUntil] = useState(0);
  const interval = () => (Date.now() < watchUntil ? 2000 : 15_000);
  const access = useQuery({
    queryKey: ['access'],
    queryFn: () => api.get<AccessStatus>('/access/status'),
    refetchInterval: interval,
  });
  // Behind sign-in, unlike /access/status: the username, the pinned
  // certificate and the saved networks.
  const detail = useQuery({
    queryKey: ['wifi-detail'],
    queryFn: () => api.get<WifiDetail>('/access/wifi'),
    refetchInterval: interval,
  });
  const failure = useFailurePopup(detail.data?.failure);
  // The join wizard, and the saved network it opened on, when it did.
  const [wizard, setWizard] = useState<{ rejoin?: string } | null>(null);

  const refresh = (delay: number) => {
    setWatchUntil(Date.now() + 60_000);
    return setTimeout(() => {
      queryClient.invalidateQueries({ queryKey: ['access'] });
      queryClient.invalidateQueries({ queryKey: ['wifi-detail'] });
    }, delay);
  };

  const forget = useMutation({
    mutationFn: (ssid: string) => api.post<{ message: string; pending?: Pending }>('/access/wifi/forget', { ssid }),
    onSuccess: (answer) => {
      change.watch(answer.pending);
      refresh(3000);
    },
  });

  const rejoin = useMutation({
    mutationFn: (ssid: string) =>
      api.post<{ message: string; pending?: Pending }>('/access/wifi', { ssid, saved: true }),
    onSuccess: (answer, ssid) => {
      change.watch(answer.pending);
      refresh(4000);
      setWizard({ rejoin: ssid });
    },
  });

  const signIn = useWifiSignIn();

  // A check now rather than at the next minute; the answer arrives with the
  // two-second polling refresh() starts.
  const recheck = useMutation({
    mutationFn: () => api.post<{ ok: boolean }>('/access/wifi/check'),
    onSuccess: () => {
      refresh(5000);
    },
  });

  if (access.isLoading) return <Spinner label="Reading WiFi state" />;
  if (access.isError) return <ErrorState error={access.error} onRetry={access.refetch} />;

  const wifi = access.data!.wifi;
  const info = detail.data;
  // A portal that drops the probe rather than redirecting it reads as offline,
  // so Sign In is offered for both: the proxy finds the page (lib/signin.uc).
  const blocked = wifi.configured && wifi.up && (wifi.uplink === 'portal' || wifi.uplink === 'offline');
  const reason = blocked && info?.uplink?.state === wifi.uplink ? info.uplink.reason : null;
  // Only while the gateway is still on the network it moved to.
  const roamed = wifi.configured && info?.roam && info.roam.to === wifi.ssid ? info.roam : null;
  const others = (info?.saved ?? []).filter((network) => !network.active);
  const problem = wifi.configured && !wifi.up ? info?.failure : null;

  const status = !wifi.configured ? null
    : !wifi.up ? { label: 'Not connected', tone: 'error' as const }
    : wifi.uplink === 'portal' ? { label: 'Sign-in needed', tone: 'warning' as const }
    : wifi.uplink === 'offline' ? { label: 'No internet', tone: 'warning' as const }
    : wifi.uplink === 'unchecked' ? { label: 'Checking', tone: 'neutral' as const }
    : { label: 'Connected', tone: 'success' as const };
  const bars = signalBars(wifi.configured && wifi.up ? wifi.signal : null);
  const Bars = bars.icon;

  return (
    <div className="fade-in">
      <ApplyChangeNotice change={change} />
      {wifi.configured ? (
        <Section wide>
          <div className={styles.hero}>
            <span className={`${styles.badge} ${styles[bars.tone]} ${!wifi.up ? styles.down : ''}`}>
              <Bars size={26} strokeWidth={2} />
            </span>
            <div className={styles.heroText}>
              <div className={styles.heroTitle}>
                <span className={styles.heroSsid}>{wifi.ssid}</span>
                {status && <Badge tone={status.tone}>{status.label}</Badge>}
              </div>
              <div className={styles.heroMeta}>
                {[
                  wifi.up ? wifi.address : null,
                  wifi.up && wifi.signal != null ? `${bars.word}, ${wifi.signal} dBm` : null,
                  SECURITY_NAMES[wifi.security],
                ].filter(Boolean).join(' · ')}
              </div>
              {problem && (
                <button className={styles.problem} onClick={failure.show}>
                  {explain(problem, wifi.ssid).title}
                </button>
              )}
            </div>
            <div className={styles.heroActions}>
              {blocked && (
                <Button
                  variant="primary"
                  loading={signIn.isPending}
                  onClick={signIn.start}
                >
                  Sign In
                </Button>
              )}
              {blocked && (
                <Button loading={recheck.isPending} onClick={() => recheck.mutate()}>
                  Check Again
                </Button>
              )}
              <Button onClick={() => setWizard({})}>Change Network</Button>
              <Button
                variant="quiet"
                loading={forget.isPending && forget.variables === wifi.ssid}
                onClick={() => forget.mutate(wifi.ssid)}
              >
                Forget
              </Button>
            </div>
          </div>

          {(wifi.mac || info?.portal || info?.identity || info?.certSubject) && (
            <div className={styles.details}>
              {wifi.mac && <Fact label="MAC" value={wifi.mac} mono />}
              {info?.identity && <Fact label="Username" value={info.identity} />}
              {info?.certSubject && <Fact label="Certificate" value={commonName(info.certSubject)} mono />}
              {info?.portal && <Fact label="Sign-in page" value={info.portal} mono />}
            </div>
          )}

          {reason && <Notice tone="warning">{`${wifi.ssid}: ${reason}`}</Notice>}
          {roamed && (
            <Notice tone="info">
              {`Left ${roamed.from} at ${clock(roamed.at)}: ${roamed.reason}. Joined ${roamed.to}.`}
            </Notice>
          )}
          {forget.isError && <Notice tone="error">{(forget.error as Error).message}</Notice>}
          {recheck.isError && <Notice tone="error">{(recheck.error as Error).message}</Notice>}
          {signIn.isError && <Notice tone="error">{(signIn.error as Error).message}</Notice>}
          <WifiFailure
            failure={problem}
            ssid={wifi.ssid}
            open={failure.open && !wizard}
            onClose={failure.close}
          />
        </Section>
      ) : (
        <Section wide>
          <div className={styles.empty}>
            <span className={`${styles.badge} ${styles.down}`}><WifiOff size={26} strokeWidth={2} /></span>
            <div className={styles.emptyTitle}>No WiFi Network</div>
            <Button variant="primary" onClick={() => setWizard({})}>Join a Network</Button>
          </div>
        </Section>
      )}

      {others.length > 0 && (
        <Section title="Saved Networks" icon={WifiIcon} wide>
          <ul className={styles.saved}>
            {others.map((network) => (
              <li key={network.ssid} className={styles.savedRow}>
                {network.security === 'open' ? (
                  <Unlock size={14} strokeWidth={2} className={styles.open} />
                ) : (
                  <Lock size={14} strokeWidth={2} className={styles.lock} />
                )}
                <span className={styles.ssid}>{network.ssid}</span>
                <span className={styles.tag}>{SECURITY_NAMES[network.security]}</span>
                <span className={styles.when}>
                  {network.lastJoined ? `Joined ${duration(Math.floor(Date.now() / 1000) - network.lastJoined)} ago` : ''}
                </span>
                <span className={styles.rowActions}>
                  <button
                    className={styles.rowAction}
                    disabled={rejoin.isPending}
                    onClick={() => rejoin.mutate(network.ssid)}
                  >
                    {rejoin.isPending && rejoin.variables === network.ssid ? 'Joining' : 'Join'}
                  </button>
                  <button
                    className={`${styles.rowAction} ${styles.quiet}`}
                    disabled={forget.isPending}
                    onClick={() => forget.mutate(network.ssid)}
                  >
                    Forget
                  </button>
                </span>
              </li>
            ))}
          </ul>
          {rejoin.isError && <Notice tone="error">{(rejoin.error as Error).message}</Notice>}
        </Section>
      )}

      <JoinWizard
        open={!!wizard}
        rejoin={wizard?.rejoin}
        wifi={wifi}
        failure={info?.failure}
        onClose={() => setWizard(null)}
        onJoined={(pending) => {
          change.watch(pending);
          refresh(4000);
        }}
        onFailureShown={failure.close}
      />
    </div>
  );
}

function clock(seconds: number) {
  return new Date(seconds * 1000).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
}
