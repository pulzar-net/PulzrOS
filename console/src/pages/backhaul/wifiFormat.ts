// Shared by the WiFi page and its join wizard.

import { Wifi, WifiHigh, WifiLow, WifiZero, type LucideIcon } from 'lucide-react';

// Neither good nor broken: associated, and not reaching the internet yet.
export const UPLINK_WARNING: Record<string, string | undefined> = {
  portal: 'Sign-in required',
  offline: 'No internet',
  unchecked: 'Checking',
};

export function commonName(subject: string) {
  return subject.match(/CN=([^/,]+)/)?.[1] ?? subject;
}

export function fingerprint(hash: string) {
  return hash.toUpperCase().match(/../g)?.join(':') ?? hash;
}


/** A signal in dBm as bars, the way a phone shows it, and in a word. */
export function signalBars(dbm: number | null | undefined): { icon: LucideIcon; word: string; tone: 'good' | 'fair' | 'weak' } {
  if (dbm == null) return { icon: WifiZero, word: 'No signal', tone: 'weak' };
  if (dbm >= -60) return { icon: Wifi, word: 'Excellent', tone: 'good' };
  if (dbm >= -70) return { icon: WifiHigh, word: 'Good', tone: 'good' };
  if (dbm >= -80) return { icon: WifiLow, word: 'Fair', tone: 'fair' };
  return { icon: WifiZero, word: 'Weak', tone: 'weak' };
}

export const SECURITY_NAMES: Record<'psk' | 'open' | 'eap', string> = {
  psk: 'Password',
  eap: '802.1X',
  open: 'Open',
};
