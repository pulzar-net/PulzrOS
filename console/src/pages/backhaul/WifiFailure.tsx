import { useState } from 'react';
import Dialog from '@/components/ui/Dialog';
import Button from '@/components/ui/Button';
import Fact, { FactList } from '@/components/Fact';
import styles from './Wifi.module.css';

/** Why the uplink is not up, as lib/wififail.uc read it from wpa_supplicant. */
export interface WifiFailureInfo {
  code: string;
  /** The server's own words, or the method it wanted, when there are any. */
  detail?: string | null;
  /** Syslog time of the failure; one failure is announced once. */
  at: string;
}

interface Explanation {
  title: string;
  meaning: string;
  fix: string;
}

// What each failure means for somebody standing at the gateway. The codes
// come from lib/wififail.uc; one it does not know falls back to `unknown`.
const EXPLAIN: Record<string, (ssid: string, detail?: string | null) => Explanation> = {
  password_expired: () => ({
    title: 'Password expired',
    meaning: 'The network knows the account, and its password has expired.',
    fix: "Change it where the account's owner changes passwords, then join again with the new one.",
  }),
  bad_credentials: () => ({
    title: 'Username or password rejected',
    meaning: "The network's server did not accept this username and password.",
    fix: 'Check both, including the @domain on the username.',
  }),
  account_disabled: () => ({
    title: 'Account disabled',
    meaning: 'The network knows the account and has disabled it.',
    fix: "The account's owner has to get it re-enabled, or use another account.",
  }),
  restricted_hours: () => ({
    title: 'Not allowed at this hour',
    meaning: 'The account may only sign in at certain times.',
    fix: "Use an account without time limits. The gateway needs to be online all day.",
  }),
  no_permission: (ssid) => ({
    title: `Account not allowed on ${ssid}`,
    meaning: 'The account exists and is not permitted to use this network.',
    fix: "Ask the network's IT for access, or use another account.",
  }),
  mschap_failed: () => ({
    title: 'Sign-in refused',
    meaning: "The network's server refused the sign-in.",
    fix: 'Check the username and password. What the server said is below.',
  }),
  cert_mismatch: () => ({
    title: 'Server certificate changed',
    meaning:
      "The network's server presented a different certificate from the one this gateway trusted. The password was not sent.",
    fix: "If the network's IT renewed it, check the certificate again and trust the new one. If not, this may not be the real network.",
  }),
  method_mismatch: (_, detail) => ({
    title: 'Wrong sign-in method',
    meaning: `The network's server wants ${detail ?? 'a different method'}.`,
    fix: `Set Method to ${detail ?? 'the one the network uses'} and join again.`,
  }),
  wrong_passphrase: () => ({
    title: 'Wrong passphrase',
    meaning: 'The access point rejected the passphrase.',
    fix: 'Check it and join again. Passphrases are case-sensitive.',
  }),
  assoc_rejected: () => ({
    title: 'Access point refused the gateway',
    meaning: 'The access point would not let the gateway connect.',
    fix: "It may be full, or only allowing listed devices. Give the network's IT the gateway's MAC address.",
  }),
  eap_rejected: () => ({
    title: 'Network refused the sign-in',
    meaning: "The network's server ended the sign-in without giving a reason.",
    fix: 'Check the username, the method and the anonymous identity.',
  }),
  auth_timeout: () => ({
    title: "No answer from the network's server",
    meaning: 'The access point never finished signing the gateway in.',
    fix: 'Check the signal. If it is weak, move the gateway or its antenna. Otherwise try again.',
  }),
  not_found: (ssid) => ({
    title: 'Network not found',
    meaning: `Nothing named ${ssid} is on the air where the gateway is.`,
    fix: 'Check the name and that the gateway is in range. Some boards only see 2.4 GHz networks.',
  }),
  unknown: () => ({
    title: 'Could not connect',
    meaning: 'The connection failed for a reason the gateway could not name.',
    fix: 'Check the settings and join again. The full story is under Logs.',
  }),
};

// Codes whose detail is the server's own message rather than something the
// explanation already says.
const SERVER_SAID = new Set(['password_expired', 'bad_credentials', 'mschap_failed', 'account_disabled', 'restricted_hours', 'no_permission']);

const SEEN_KEY = 'pulzr.wifi-failure-seen';

function readSeen() {
  try {
    return sessionStorage.getItem(SEEN_KEY);
  } catch {
    return null;
  }
}

export function explain(failure: WifiFailureInfo, ssid: string) {
  return (EXPLAIN[failure.code] ?? EXPLAIN.unknown)(ssid, failure.detail);
}

/**
 * A new failure opens by itself, once; after that it is a click away. "Once"
 * survives a page reload, because the same failure popping up every time
 * somebody looks at the page is the page shouting.
 */
export function useFailurePopup(failure: WifiFailureInfo | null | undefined) {
  const [seen, setSeen] = useState(readSeen);
  const [reopened, setReopened] = useState(false);
  const open = !!failure && (failure.at !== seen || reopened);

  const close = () => {
    if (failure) {
      setSeen(failure.at);
      try {
        sessionStorage.setItem(SEEN_KEY, failure.at);
      } catch {
        // Private windows: it will be announced again next visit, which is fine.
      }
    }
    setReopened(false);
  };

  return { open, close, show: () => setReopened(true) };
}

export default function WifiFailure({
  failure,
  ssid,
  open,
  onClose,
}: {
  failure: WifiFailureInfo | null | undefined;
  ssid: string;
  open: boolean;
  onClose: () => void;
}) {
  if (!failure) return null;
  const { title, meaning, fix } = explain(failure, ssid);

  return (
    <Dialog
      open={open}
      onClose={onClose}
      size="compact"
      title={title}
      footer={
        <Button variant="primary" onClick={onClose}>
          OK
        </Button>
      }
    >
      <p className={styles.explain}>{meaning}</p>
      <p className={styles.explain}>{fix}</p>
      <FactList>
        <Fact label="Network" value={ssid} />
        {failure.detail &&
          SERVER_SAID.has(failure.code) &&
          failure.detail.toLowerCase() !== title.toLowerCase() && (
          <Fact label="Server said" value={failure.detail} mono />
        )}
        <Fact label="When" value={failure.at} />
      </FactList>
    </Dialog>
  );
}
