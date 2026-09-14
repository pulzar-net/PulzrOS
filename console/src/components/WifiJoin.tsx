import { useState } from 'react';
import { useMutation, useQuery } from '@tanstack/react-query';
import { Lock, RefreshCw, Unlock, Wifi } from 'lucide-react';
import { api } from '@/services/api';
import type { WifiNetwork } from '@/types';
import Card from './ui/Card';
import Notice from './ui/Notice';
import Button from './ui/Button';
import Spinner from './ui/Spinner';
import { CheckboxField, TextField } from './ui/Field';
import styles from './WifiJoin.module.css';

/**
 * Put this gateway onto a WiFi network.
 *
 * The other half of the setup AP: an installer associates to the gateway's own
 * radio and uses this to hand it credentials for the site's network.
 *
 * The scan is best-effort. Most of these boards have a single radio, and while
 * it is hosting the setup AP it usually cannot also survey the air — so a failed
 * scan is a normal state with a normal explanation, not an error, and the SSID
 * can always be typed instead.
 */
export default function WifiJoin() {
  const [ssid, setSsid] = useState('');
  const [passphrase, setPassphrase] = useState('');
  const [allowOpen, setAllowOpen] = useState(false);

  const scan = useQuery({
    queryKey: ['wifi-scan'],
    queryFn: () => api.get<{ capable: boolean; networks: WifiNetwork[]; error?: string }>(
      '/access/scan',
    ),
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
  });

  const selected = scan.data?.networks.find((network) => network.ssid === ssid);
  const isOpen = selected?.encryption === 'open';

  if (scan.data && !scan.data.capable) return null;

  return (
    <Card
      title="Join a WiFi network"
      icon={Wifi}
      actions={
        <Button loading={scan.isFetching} onClick={() => scan.refetch()}>
          <RefreshCw size={13} strokeWidth={2} />
          Scan
        </Button>
      }
    >
      <p className={styles.note}>
        Gives this gateway a wired-equivalent uplink over WiFi. It sits between
        ethernet and cellular in preference — better than paying for data, worse
        than a cable.
      </p>

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

      <TextField
        label="Network name"
        value={ssid}
        onChange={(event) => setSsid(event.target.value)}
        hint="Pick one above, or type it — a hidden network will not appear in a scan."
      />

      {!isOpen && (
        <TextField
          label="Passphrase"
          type="password"
          autoComplete="off"
          value={passphrase}
          onChange={(event) => setPassphrase(event.target.value)}
          hint="8 to 63 characters. Stored on the gateway and never shown again."
        />
      )}

      {isOpen && (
        <>
          <Notice tone="warning">
            <strong>{ssid}</strong> has no password. Everything this gateway
            sends — its management traffic included — would cross it in the
            clear, and anyone in range could inject into it.
          </Notice>
          <CheckboxField
            label="I understand, use this open network anyway"
            checked={allowOpen}
            onChange={(event) => setAllowOpen(event.target.checked)}
          />
        </>
      )}

      {join.isError && <Notice tone="error">{(join.error as Error).message}</Notice>}
      {join.isSuccess && <Notice tone="success">{join.data.message}</Notice>}

      <div className={styles.actions}>
        <Button
          variant="primary"
          disabled={!ssid.trim() || (isOpen && !allowOpen) || (!isOpen && !passphrase)}
          loading={join.isPending}
          onClick={() => join.mutate()}
        >
          Join
        </Button>
      </div>
    </Card>
  );
}
