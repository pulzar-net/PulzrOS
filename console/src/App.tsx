import { lazy } from 'react';
import { Navigate, Route, Routes } from 'react-router-dom';
import { useQuery } from '@tanstack/react-query';
import { useSession } from '@/contexts/SessionContext';
import { api } from '@/services/api';
import type { ClaimStatus } from '@/types';
import Layout from '@/components/Layout';
import Login from '@/pages/Login';
import Spinner from '@/components/ui/Spinner';
import PasswordPrompt from '@/components/PasswordPrompt';

/**
 * Routing.
 *
 * Only Overview is in the initial bundle. The rest are lazy: a gateway console
 * is usually opened to answer one question, and on a Pi 3 over a slow link the
 * difference between parsing one page and parsing seven is visible.
 */
const Backhaul = lazy(() => import('@/pages/Backhaul'));
const Lorawan = lazy(() => import('@/pages/Lorawan'));
const Hardware = lazy(() => import('@/pages/Hardware'));
const Panel = lazy(() => import('@/pages/Panel'));
const Access = lazy(() => import('@/pages/Access'));
const Logs = lazy(() => import('@/pages/Logs'));
const System = lazy(() => import('@/pages/System'));
const Overview = lazy(() => import('@/pages/Overview'));
// Not lazy: on an unadopted gateway this is the *only* thing anyone sees, and
// a spinner before the first screen of a brand-new device reads as a fault.
import Onboarding from '@/pages/Onboarding';

export default function App() {
  const { session, loading } = useSession();

  // Adoption state decides the whole shape of the app, so it is asked for
  // before anything else. Unauthenticated on purpose: a gateway out of the box
  // has a password nobody has read off the serial console yet, and requiring a
  // login before it can be claimed would defeat one-touch provisioning
  // entirely. The endpoint stops answering the moment the gateway is adopted.
  const claim = useQuery({
    queryKey: ['claim-status'],
    queryFn: () => api.get<ClaimStatus>('/claim/status'),
    retry: false,
    staleTime: 10_000,
  });

  // Wait for both probes before deciding. Rendering one screen and replacing
  // it a moment later makes every refresh look like a fault.
  if (loading || claim.isLoading) {
    return <Spinner label="Connecting to the gateway" />;
  }

  // A gateway nobody owns has exactly one thing to offer: being claimed.
  // Everything else — the login form included — is noise until then.
  if (claim.data && claim.data.adoption !== 'adopted') return <Onboarding />;

  if (!session) return <Login />;

  // A gateway still on the password it generated at first boot is a gateway
  // anybody holding the label can open. Nothing else is reachable until it is
  // dealt with — a dismissible banner is a banner that gets dismissed.
  if (session.mustChangePassword) return <PasswordPrompt />;

  return (
    <Routes>
      <Route element={<Layout />}>
        <Route index element={<Overview />} />
        <Route path="backhaul" element={<Backhaul />} />
        <Route path="lorawan" element={<Lorawan />} />
        <Route path="hardware" element={<Hardware />} />
        <Route path="access" element={<Access />} />
        <Route path="io" element={<Panel />} />
        <Route path="logs" element={<Logs />} />
        <Route path="system" element={<System />} />
        {/* A deep link to a page this build does not have goes home rather
            than rendering nothing. */}
        <Route path="*" element={<Navigate to="/" replace />} />
      </Route>
    </Routes>
  );
}
