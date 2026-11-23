import { StrictMode } from 'react';
import { createRoot } from 'react-dom/client';
import { BrowserRouter } from 'react-router-dom';
import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { SessionProvider } from '@/contexts/SessionContext';
import App from './App';
import './index.css';

/**
 * A page left open across a firmware upgrade, or an index.html a browser kept,
 * asks for chunks the new image no longer has: every asset name is a hash of
 * its content. uhttpd can put no Cache-Control on index.html (the cloud
 * marks it no-cache on the Pulzr Cloud path, but a laptop on a LAN port talks to
 * uhttpd directly), so the page reloads itself once, which fetches the
 * current index.html, rather than showing a page of errors. Once a minute at
 * most, so a chunk that is really missing does not loop.
 */
window.addEventListener('vite:preloadError', (event) => {
  const key = 'pulzr-reloaded-for-assets';
  try {
    const last = Number(sessionStorage.getItem(key) ?? 0);
    if (Date.now() - last < 60_000) return;
    sessionStorage.setItem(key, String(Date.now()));
  } catch {
    return;
  }
  event.preventDefault();
  window.location.reload();
});

/**
 * Query defaults, tuned for a device rather than a web app.
 *
 * The gateway is on the other side of a LAN cable or a proxied tunnel, and it
 * is a small computer with a packet forwarder to run. So: no refetch storms on
 * window focus, one retry rather than three (a gateway that refused once is
 * usually rebooting, and hammering it does not help), and pages opt into
 * polling individually where live data actually matters.
 */
const queryClient = new QueryClient({
  defaultOptions: {
    queries: {
      refetchOnWindowFocus: false,
      retry: 1,
      staleTime: 5_000,
    },
  },
});

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <QueryClientProvider client={queryClient}>
      <SessionProvider>
        {/* BrowserRouter, not HashRouter: uhttpd is configured with
            error_page=/index.html so a deep link survives a reload, and clean
            URLs are what somebody pastes into a ticket. */}
        <BrowserRouter>
          <App />
        </BrowserRouter>
      </SessionProvider>
    </QueryClientProvider>
  </StrictMode>,
);
