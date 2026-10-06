import { useState } from 'react';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { Lock, RefreshCw, Unlock } from 'lucide-react';
import { api } from '@/services/api';
import type { AccessStatus, WifiNetwork } from '@/types';
import Section from '@/components/ui/Section';
import { StatusBadge } from '@/components/ui/Badge';
import Fact, { FactList } from '@/components/Fact';
import Notice from '@/components/ui/Notice';
import Button from '@/components/ui/Button';
import Spinner from '@/components/ui/Spinner';
import ErrorState from '@/components/ErrorState';
import { CheckboxField, SelectField, TextField } from '@/components/ui/Field';
import pageStyles from '../Pages.module.css';
import styles from './Wifi.module.css';

/**
 * WiFi as an uplink: between ethernet and cellular in preference — better than
 * paying for data, worse than a cable.
 *
 * The scan is best-effort. Most of these boards have a single radio, and while
 * it is hosting the setup AP it usually cannot also survey the air — so a failed
 * scan is a normal state with a normal explanation, not an error, and the SSID
 * can always be typed instead.
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
  identity?: string;
  method?: string;
  certSubject?: string;
  certHash?: string;
  saved: SavedNetwork[];
}

export default function Wifi() {
  const queryClient = useQueryClient();
  const access = useQuery({
    queryKey: ['access'],
    queryFn: () => api.get<AccessStatus>('/access/status'),
    refetchInterval: 15_000,
  });
  // Behind sign-in, unlike /access/status: the username, the pinned
  // certificate and the saved networks.
  const detail = useQuery({
    queryKey: ['wifi-detail'],
    queryFn: () => api.get<WifiDetail>('/access/wifi'),
    refetchInterval: 15_000,
  });

  const refresh = (delay: number) =>
    setTimeout(() => {
      queryClient.invalidateQueries({ queryKey: ['access'] });
      queryClient.invalidateQueries({ queryKey: ['wifi-detail'] });
    }, delay);

  const forget = useMutation({
    mutationFn: (ssid: string) => api.post<{ message: string }>('/access/wifi/forget', { ssid }),
    onSuccess: () => refresh(3000),
  });

  const rejoin = useMutation({
    mutationFn: (ssid: string) =>
      api.post<{ message: string }>('/access/wifi', { ssid, saved: true }),
    onSuccess: () => refresh(4000),
  });

  if (access.isLoading) return <Spinner label="Reading WiFi state" />;
  if (access.isError) return <ErrorState error={access.error} onRetry={access.refetch} />;

  const wifi = access.data!.wifi;
  const info = detail.data;
  const others = (info?.saved ?? []).filter((network) => !network.active);

  return (
    <div className="fade-in">
      {wifi.configured && (
        <Section
          actions={
            <Button
              loading={forget.isPending && forget.variables === wifi.ssid}
              onClick={() => forget.mutate(wifi.ssid)}
            >
              Forget network
            </Button>
          }
        >
          <FactList>
            <Fact label="Network" value={wifi.ssid} />
            <Fact
              label="State"
              value={<StatusBadge ok={wifi.up} okLabel="Connected" badLabel="Not connected" />}
            />
            <Fact label="Address" value={wifi.address} mono />
            <Fact label="Signal" value={wifi.signal != null ? `${wifi.signal} dBm` : null} />
            {info?.identity && <Fact label="Username" value={info.identity} />}
            {info?.certSubject && (
              <Fact label="Certificate" value={commonName(info.certSubject)} mono />
            )}
            {info?.certHash && (
              <Fact
                label="SHA-256"
                value={<span className={styles.fingerprint}>{fingerprint(info.certHash)}</span>}
                mono
              />
            )}
          </FactList>
          {forget.isError && <Notice tone="error">{(forget.error as Error).message}</Notice>}
        </Section>
      )}

      {others.length > 0 && (
        <Section title="Saved networks">
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
          {rejoin.isSuccess && <Notice tone="success">{rejoin.data.message}</Notice>}
        </Section>
      )}

      <Join
        title={wifi.configured ? 'Join a different network' : undefined}
        onJoined={() => refresh(4000)}
      />
    </div>
  );
}

type Security = 'psk' | 'open' | 'eap';
type Method = 'peap' | 'ttls-pap' | 'ttls-mschapv2';

interface ProbeResult {
  state: 'none' | 'probing' | 'done' | 'failed';
  ssid?: string;
  error?: string;
  chain: { depth: number; subject: string; hash: string }[];
}

function commonName(subject: string) {
  return subject.match(/CN=([^/,]+)/)?.[1] ?? subject;
}

function fingerprint(hash: string) {
  return hash.toUpperCase().match(/../g)?.join(':') ?? hash;
}

function Join({ title, onJoined }: { title?: string; onJoined: () => void }) {
  const [ssid, setSsid] = useState('');
  const [passphrase, setPassphrase] = useState('');
  const [allowOpen, setAllowOpen] = useState(false);
  const [typedSecurity, setTypedSecurity] = useState<Security>('psk');
  const [method, setMethod] = useState<Method>('peap');
  const [identity, setIdentity] = useState('');
  const [anonymousIdentity, setAnonymousIdentity] = useState('');
  const [password, setPassword] = useState('');
  const [probing, setProbing] = useState(false);

  const scan = useQuery({
    queryKey: ['wifi-scan'],
    queryFn: () =>
      api.get<{ capable: boolean; networks: WifiNetwork[]; error?: string }>('/access/scan'),
    // Scanning takes the radio away from whatever it is doing; not on a timer.
    refetchOnWindowFocus: false,
    staleTime: Infinity,
  });

  const selected = scan.data?.networks.find((network) => network.ssid === ssid);
  const security: Security = selected?.encryption ?? typedSecurity;
  const isOpen = security === 'open';
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

  const join = useMutation({
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
    onSuccess: onJoined,
  });

  const resetProbe = () => setProbing(false);

  if (scan.data && !scan.data.capable) {
    return <Notice tone="info">This board has no WiFi radio.</Notice>;
  }

  return (
    <Section
      title={title}
      actions={
        <Button loading={scan.isFetching} onClick={() => scan.refetch()}>
          <RefreshCw size={13} strokeWidth={2} />
          Scan
        </Button>
      }
    >
      {scan.data?.error && <Notice tone="info">{scan.data.error}</Notice>}

      {!!scan.data?.networks.length && (
        <ul className={`${styles.list} ${scan.isFetching ? styles.stale : ''}`}>
          {scan.data.networks
            .slice()
            .sort((a, b) => b.quality - a.quality)
            .map((network) => (
              <li key={network.ssid}>
                <button
                  className={`${styles.network} ${ssid === network.ssid ? styles.selected : ''}`}
                  onClick={() => {
                    setSsid(network.ssid);
                    setAllowOpen(false);
                    resetProbe();
                  }}
                >
                  {network.encryption === 'open' ? (
                    <Unlock size={13} strokeWidth={2} className={styles.open} />
                  ) : (
                    <Lock size={13} strokeWidth={2} />
                  )}
                  <span className={styles.ssid}>{network.ssid}</span>
                  {network.encryption === 'eap' && <span className={styles.signal}>802.1X</span>}
                  <span className={styles.signal}>{network.signal} dBm</span>
                </button>
              </li>
            ))}
        </ul>
      )}

      <div className={pageStyles.form}>
        <TextField
          label="Network name"
          value={ssid}
          onChange={(event) => {
            setSsid(event.target.value);
            resetProbe();
          }}
        />

        {!selected && (
          <SelectField<Security>
            label="Security"
            value={typedSecurity}
            onChange={(value) => {
              setTypedSecurity(value);
              resetProbe();
            }}
            options={[
              { value: 'psk', label: 'Password' },
              { value: 'eap', label: 'Username and password' },
              { value: 'open', label: 'None' },
            ]}
          />
        )}

        {security === 'psk' && (
          <TextField
            label="Passphrase"
            type="password"
            autoComplete="off"
            value={passphrase}
            onChange={(event) => setPassphrase(event.target.value)}
          />
        )}

        {isEap && (
          <>
            <SelectField<Method>
              label="Method"
              value={method}
              onChange={(value) => {
                setMethod(value);
                resetProbe();
              }}
              options={[
                { value: 'peap', label: 'PEAP (MSCHAPv2)' },
                { value: 'ttls-pap', label: 'TTLS (PAP)' },
                { value: 'ttls-mschapv2', label: 'TTLS (MSCHAPv2)' },
              ]}
            />
            <TextField
              label="Username"
              autoComplete="off"
              value={identity}
              onChange={(event) => {
                setIdentity(event.target.value);
                resetProbe();
              }}
            />
            <TextField
              label="Password"
              type="password"
              autoComplete="off"
              value={password}
              onChange={(event) => setPassword(event.target.value)}
            />
            <TextField
              label="Anonymous identity"
              autoComplete="off"
              placeholder="anonymous@example.edu"
              value={anonymousIdentity}
              onChange={(event) => {
                setAnonymousIdentity(event.target.value);
                resetProbe();
              }}
            />
          </>
        )}
      </div>

      {isOpen && (
        <>
          <Notice tone="warning">
            <strong>{ssid}</strong> is an open network.
          </Notice>
          <CheckboxField
            label="Use this open network anyway"
            checked={allowOpen}
            onChange={(event) => setAllowOpen(event.target.checked)}
          />
        </>
      )}

      {isEap && leaf && (
        <FactList>
          <Fact label="Server" value={commonName(leaf.subject)} mono />
          {issuer && <Fact label="Issued by" value={commonName(issuer.subject)} />}
          <Fact
            label="SHA-256"
            value={<span className={styles.fingerprint}>{fingerprint(leaf.hash)}</span>}
            mono
          />
        </FactList>
      )}
      {isEap && result?.state === 'failed' && <Notice tone="error">{result.error}</Notice>}
      {startProbe.isError && <Notice tone="error">{(startProbe.error as Error).message}</Notice>}

      {join.isError && <Notice tone="error">{(join.error as Error).message}</Notice>}
      {join.isSuccess && <Notice tone="success">{join.data.message}</Notice>}

      <div className={pageStyles.actions}>
        {isEap && !leaf ? (
          <Button
            variant="primary"
            disabled={!ssid.trim() || !identity.trim() || !password}
            loading={checking}
            onClick={() => startProbe.mutate()}
          >
            {checking ? 'Checking certificate' : 'Check certificate'}
          </Button>
        ) : (
          <Button
            variant="primary"
            disabled={
              !ssid.trim() ||
              (isOpen && !allowOpen) ||
              (security === 'psk' && !passphrase) ||
              (isEap && (!password || !identity.trim()))
            }
            loading={join.isPending}
            onClick={() => join.mutate()}
          >
            {isEap ? 'Trust and join' : 'Join'}
          </Button>
        )}
      </div>
    </Section>
  );
}
