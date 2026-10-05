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
import { CheckboxField, TextField } from '@/components/ui/Field';
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
export default function Wifi() {
  const queryClient = useQueryClient();
  const access = useQuery({
    queryKey: ['access'],
    queryFn: () => api.get<AccessStatus>('/access/status'),
    refetchInterval: 15_000,
  });

  const forget = useMutation({
    mutationFn: () => api.post<{ message: string }>('/access/wifi/forget'),
    onSuccess: () =>
      setTimeout(() => queryClient.invalidateQueries({ queryKey: ['access'] }), 3000),
  });

  if (access.isLoading) return <Spinner label="Reading WiFi state" />;
  if (access.isError) return <ErrorState error={access.error} onRetry={access.refetch} />;

  const wifi = access.data!.wifi;

  return (
    <div className="fade-in">
      {wifi.configured && (
        <Section
          actions={
            <Button loading={forget.isPending} onClick={() => forget.mutate()}>
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
          </FactList>
          {forget.isError && <Notice tone="error">{(forget.error as Error).message}</Notice>}
        </Section>
      )}

      <Join
        title={wifi.configured ? 'Join a different network' : undefined}
        onJoined={() =>
          setTimeout(() => queryClient.invalidateQueries({ queryKey: ['access'] }), 4000)
        }
      />
    </div>
  );
}

function Join({ title, onJoined }: { title?: string; onJoined: () => void }) {
  const [ssid, setSsid] = useState('');
  const [passphrase, setPassphrase] = useState('');
  const [allowOpen, setAllowOpen] = useState(false);

  const scan = useQuery({
    queryKey: ['wifi-scan'],
    queryFn: () =>
      api.get<{ capable: boolean; networks: WifiNetwork[]; error?: string }>('/access/scan'),
    // Scanning takes the radio away from whatever it is doing; not on a timer.
    refetchOnWindowFocus: false,
    staleTime: Infinity,
  });

  const join = useMutation({
    mutationFn: () =>
      api.post<{ message: string }>('/access/wifi', {
        ssid: ssid.trim(),
        key: passphrase || undefined,
        allowOpen,
      }),
    onSuccess: onJoined,
  });

  const selected = scan.data?.networks.find((network) => network.ssid === ssid);
  const isOpen = selected?.encryption === 'open';

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
      {scan.isFetching && <Spinner label="Scanning" />}
      {scan.data?.error && <Notice tone="info">{scan.data.error}</Notice>}

      {!!scan.data?.networks.length && (
        <ul className={styles.list}>
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
                  }}
                >
                  {network.encryption === 'open' ? (
                    <Unlock size={13} strokeWidth={2} className={styles.open} />
                  ) : (
                    <Lock size={13} strokeWidth={2} />
                  )}
                  <span className={styles.ssid}>{network.ssid}</span>
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
          onChange={(event) => setSsid(event.target.value)}
        />

        {!isOpen && (
          <TextField
            label="Passphrase"
            type="password"
            autoComplete="off"
            value={passphrase}
            onChange={(event) => setPassphrase(event.target.value)}
          />
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

      {join.isError && <Notice tone="error">{(join.error as Error).message}</Notice>}
      {join.isSuccess && <Notice tone="success">{join.data.message}</Notice>}

      <div className={pageStyles.actions}>
        <Button
          variant="primary"
          disabled={!ssid.trim() || (isOpen && !allowOpen) || (!isOpen && !passphrase)}
          loading={join.isPending}
          onClick={() => join.mutate()}
        >
          Join
        </Button>
      </div>
    </Section>
  );
}
