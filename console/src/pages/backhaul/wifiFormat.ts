// Shared by the WiFi page and its join wizard.

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
