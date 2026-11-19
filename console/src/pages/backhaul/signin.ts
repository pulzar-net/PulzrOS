import { useMutation } from '@tanstack/react-query';
import { api } from '@/services/api';

/**
 * Signing the WiFi uplink in to its network's portal, through the gateway's
 * sign-in proxy (lib/signin.uc). Shared by the WiFi page and the radios page,
 * which both offer it while the uplink is held at a sign-in page.
 *
 * The window is opened by the click itself and pointed at the proxy once the
 * ticket arrives: one opened after an await is a popup, and browsers block
 * those. Its opener is cut first, because what loads in it is the portal's.
 * Where popups are blocked outright, this tab goes instead.
 */
export function useWifiSignIn() {
  const mutation = useMutation({
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
  return { ...mutation, start: () => mutation.mutate(window.open('about:blank', '_blank')) };
}

interface SigninTicket {
  port: number;
  path: string;
  /** How this page reached the gateway, which decides how to reach the proxy. */
  via: 'local' | 'Pulzar Cloud';
}

// The sign-in proxy is another origin on purpose (lib/signin.uc on the
// gateway). Here that is this address on its own port; through Pulzar Cloud it
// is another device host, which Pulzar Cloud mints when asked at /__signin.
function signinUrl(ticket: SigninTicket) {
  if (ticket.via === 'Pulzar Cloud') return `/__signin?next=${encodeURIComponent(ticket.path)}`;
  return `https://${window.location.hostname}:${ticket.port}${ticket.path}`;
}
