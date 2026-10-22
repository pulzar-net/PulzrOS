import { useState } from 'react';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { Lock, Unlock } from 'lucide-react';
import { api } from '@/services/api';
import type { AccessStatus } from '@/types';
import Section from '@/components/ui/Section';
import { StatusBadge } from '@/components/ui/Badge';
import Fact, { FactList } from '@/components/Fact';
import Notice from '@/components/ui/Notice';
import Button from '@/components/ui/Button';
import Spinner from '@/components/ui/Spinner';
import ErrorState from '@/components/ErrorState';
import WifiFailure, { explain, useFailurePopup, type WifiFailureInfo } from './WifiFailure';
import JoinWizard from './JoinWizard';
import { UPLINK_WARNING, commonName } from './wifiFormat';
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

interface WifiDetail {
  configured: boolean;
  /** The network's sign-in page, while it has one. */
  portal?: string | null;
  identity?: string;
  method?: string;
  certSubject?: string;
  certHash?: string;
  failure?: WifiFailureInfo | null;
  saved: SavedNetwork[];
}

export default function Wifi() {
  const queryClient = useQueryClient();
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
    mutationFn: (ssid: string) => api.post<{ message: string }>('/access/wifi/forget', { ssid }),
    onSuccess: () => refresh(3000),
  });

  const rejoin = useMutation({
    mutationFn: (ssid: string) =>
      api.post<{ message: string }>('/access/wifi', { ssid, saved: true }),
    onSuccess: (_, ssid) => {
      refresh(4000);
      setWizard({ rejoin: ssid });
    },
  });

  // The window is opened by the click itself and pointed at the proxy once the
  // ticket arrives: one opened after an await is a popup, and browsers block
  // those. Its opener is cut first, because what loads in it is the portal's.
  // Where popups are blocked outright, this tab goes instead.
  const signIn = useMutation({
    mutationFn: async (target: Window | null) => {
      try {
        const ticket = await api.post<SigninTicket>('/access/wifi/signin');
        if (target) {
          target.opener = null;
          target.location.href = signinUrl(ticket);
        } else {
          window.location.assign(signinUrl(ticket));
        }
      } catch (error) {
        target?.close();
        throw error;
      }
    },
  });

  if (access.isLoading) return <Spinner label="Reading WiFi state" />;
  if (access.isError) return <ErrorState error={access.error} onRetry={access.refetch} />;

  const wifi = access.data!.wifi;
  const info = detail.data;
  const blocked = wifi.configured && wifi.up && (wifi.uplink === 'portal' || wifi.uplink === 'offline');
  const others = (info?.saved ?? []).filter((network) => !network.active);
  const problem = wifi.configured && !wifi.up ? info?.failure : null;

  const joinButton = (
    <Button variant={wifi.configured ? 'default' : 'primary'} onClick={() => setWizard({})}>
      {wifi.configured ? 'Change network' : 'Join a network'}
    </Button>
  );

  return (
    <div className="fade-in">
      {wifi.configured ? (
        <Section
          actions={
            <>
              {blocked && (
                <Button
                  variant="primary"
                  loading={signIn.isPending}
                  onClick={() => signIn.mutate(window.open('about:blank', '_blank'))}
                >
                  Sign in
                </Button>
              )}
              {joinButton}
              <Button
                loading={forget.isPending && forget.variables === wifi.ssid}
                onClick={() => forget.mutate(wifi.ssid)}
              >
                Forget
              </Button>
            </>
          }
        >
          <FactList>
            <Fact label="Network" value={wifi.ssid} />
            <Fact
              label="State"
              value={
                <StatusBadge
                  ok={wifi.up}
                  okLabel="Connected"
                  badLabel="Not connected"
                  warn={wifi.up ? UPLINK_WARNING[wifi.uplink] : undefined}
                />
              }
            />
            {problem && (
              <Fact
                label="Problem"
                value={
                  <button className={styles.problem} onClick={failure.show}>
                    {explain(problem, wifi.ssid).title}
                  </button>
                }
              />
            )}
            {wifi.up && <Fact label="Address" value={wifi.address} mono />}
            {wifi.up && <Fact label="Signal" value={wifi.signal != null ? `${wifi.signal} dBm` : null} />}
            {wifi.mac && <Fact label="MAC" value={wifi.mac} mono />}
            {info?.portal && <Fact label="Sign-in page" value={info.portal} mono />}
            {info?.identity && <Fact label="Username" value={info.identity} />}
            {info?.certSubject && (
              <Fact label="Certificate" value={commonName(info.certSubject)} mono />
            )}
          </FactList>
          {blocked && (
            <Notice tone="warning">
              {wifi.uplink === 'portal'
                ? `${wifi.ssid} wants a sign-in before it carries traffic.`
                : `${wifi.ssid} is connected and nothing answers through it.`}
            </Notice>
          )}
          {forget.isError && <Notice tone="error">{(forget.error as Error).message}</Notice>}
          {signIn.isError && <Notice tone="error">{(signIn.error as Error).message}</Notice>}
          <WifiFailure
            failure={problem}
            ssid={wifi.ssid}
            open={failure.open && !wizard}
            onClose={failure.close}
          />
        </Section>
      ) : (
        <Section actions={joinButton}>
          <Notice tone="info">Not on a WiFi network.</Notice>
        </Section>
      )}

      {others.length > 0 && (
        <Section title="Saved Networks">
          <ul className={styles.list}>
            {others.map((network) => (
              <li key={network.ssid} className={styles.savedRow}>
                {network.security === 'open' ? (
                  <Unlock size={13} strokeWidth={2} className={styles.open} />
                ) : (
                  <Lock size={13} strokeWidth={2} />
                )}
                <span className={styles.ssid}>{network.ssid}</span>
                {network.security === 'eap' && <span className={styles.signal}>802.1X</span>}
                <Button
                  loading={rejoin.isPending && rejoin.variables === network.ssid}
                  onClick={() => rejoin.mutate(network.ssid)}
                >
                  Join
                </Button>
                <Button
                  loading={forget.isPending && forget.variables === network.ssid}
                  onClick={() => forget.mutate(network.ssid)}
                >
                  Forget
                </Button>
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
        onJoined={() => refresh(4000)}
        onFailureShown={failure.close}
      />
    </div>
  );
}

interface SigninTicket {
  port: number;
  path: string;
  /** How this page reached the gateway, which decides how to reach the proxy. */
  via: 'local' | 'parkeze.net';
}

// The sign-in proxy is another origin on purpose (lib/signin.uc on the
// gateway). Here that is this address on its own port; through parkeze.net it
// is another device host, which parkeze.net mints when asked at /__signin.
function signinUrl(ticket: SigninTicket) {
  if (ticket.via === 'parkeze.net') return `/__signin?next=${encodeURIComponent(ticket.path)}`;
  return `https://${window.location.hostname}:${ticket.port}${ticket.path}`;
}
