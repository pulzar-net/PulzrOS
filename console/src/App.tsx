import { lazy, useState, type ReactNode } from 'react';
import { Navigate, Route, Routes } from 'react-router-dom';
import { useQuery } from '@tanstack/react-query';
import { useSession } from '@/contexts/SessionContext';
import { api } from '@/services/api';
import type { ClaimStatus, Feature } from '@/types';
import { useFeatures } from '@/hooks/useFeatures';
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
const Backhaul = lazy(() => import('@/pages/backhaul/Backhaul'));
const Ethernet = lazy(() => import('@/pages/backhaul/Ethernet'));
const Cellular = lazy(() => import('@/pages/backhaul/Cellular'));
const Wifi = lazy(() => import('@/pages/backhaul/Wifi'));
const Forwarders = lazy(() => import('@/pages/lorawan/Forwarders'));
const LorawanSettings = lazy(() => import('@/pages/lorawan/Settings'));
const Ports = lazy(() => import('@/pages/network/Ports'));
const Lan = lazy(() => import('@/pages/network/Lan'));
const Dns = lazy(() => import('@/pages/network/Dns'));
const SpeedTest = lazy(() => import('@/pages/network/SpeedTest'));
const Gnss = lazy(() => import('@/pages/Gnss'));
const Bluetooth = lazy(() => import('@/pages/Bluetooth'));
const Radios = lazy(() => import('@/pages/radios/Radios'));
const Panel = lazy(() => import('@/pages/Panel'));
const Access = lazy(() => import('@/pages/Access'));
const Logs = lazy(() => import('@/pages/Logs'));
const Resources = lazy(() => import('@/pages/system/Resources'));
const Maintenance = lazy(() => import('@/pages/system/Maintenance'));
const Overview = lazy(() => import('@/pages/Overview'));
// Not lazy: on an unadopted gateway this is the *only* thing anyone sees, and
// a spinner before the first screen of a brand-new device reads as a fault.
import Onboarding from '@/pages/Onboarding';

export default function App() {
  const { session, loading } = useSession();

  // Set when somebody chooses to look around before claiming. Deliberately
  // not persisted: it is a decision about this visit, and a gateway that
  // quietly stops offering to be adopted because of a click last week is
  // worse than one that asks again.
  const [browsing, setBrowsing] = useState(false);

  // Adoption state, signed in only. The claim code is a key to the gateway:
  // whoever holds it can adopt it into any organization they run, so the API
  // shows it to a session and nobody else. On an unadopted gateway the label's
  // password is that session. The endpoint stops answering once adopted.
  const claim = useQuery({
    queryKey: ['claim-status'],
    queryFn: () => api.get<ClaimStatus>('/claim/status'),
    enabled: !!session,
    retry: false,
    staleTime: 10_000,
  });

  // Wait for both probes before deciding. Rendering one screen and replacing
  // it a moment later makes every refresh look like a fault.
  if (loading || (!!session && claim.isLoading)) {
    return <Spinner label="Connecting to the gateway" />;
  }

  // Reclaiming is adopted with a revoked claim: the claim screen opens as it
  // does on an unadopted gateway, but nothing about the gateway is local-only.
  const claimable = !!claim.data && claim.data.adoption !== 'adopted';
  const reclaiming = claim.data?.adoption === 'reclaiming';
  const unadopted = claimable && !reclaiming;

  if (!session) return <Login />;

  // A gateway still on the password it generated at first boot is a gateway
  // anybody holding the label can open. Nothing else is reachable until it is
  // dealt with — a dismissible banner is a banner that gets dismissed.
  if (session.mustChangePassword) return <PasswordPrompt />;

  // Claiming is what an unadopted gateway is usually here to do, so it is what
  // opens after sign-in — but not a wall: the console is reachable before
  // adoption, because looking at a gateway before committing it to an
  // organization is a reasonable thing to want.
  if (claimable && !browsing) {
    return <Onboarding onBrowse={() => setBrowsing(true)} />;
  }

  return (
    <Routes>
      <Route element={<Layout unadopted={unadopted} reclaiming={reclaiming} />}>
        <Route path="adopt" element={<Onboarding />} />
        <Route index element={<Overview />} />
        <Route path="backhaul" element={<Backhaul />} />
        <Route path="backhaul/ethernet" element={<Ethernet />} />
        <Route path="backhaul/cellular" element={<Gated feature="cellular"><Cellular /></Gated>} />
        <Route path="backhaul/wifi" element={<Gated feature="wifi"><Wifi /></Gated>} />
        <Route path="lorawan" element={<Navigate to="/lorawan/forwarders/1/status" replace />} />
        <Route path="lorawan/forwarders" element={<Navigate to="/lorawan/forwarders/1/status" replace />} />
        <Route path="lorawan/forwarders/:forwarder/:tab" element={<Gated feature="lorawan"><Forwarders /></Gated>} />
        <Route path="lorawan/settings" element={<Gated feature="lorawan"><LorawanSettings /></Gated>} />
        <Route path="network" element={<Navigate to="/network/ports" replace />} />
        <Route path="network/ports" element={<Ports />} />
        <Route path="network/lan" element={<Gated feature="lan"><Lan /></Gated>} />
        <Route path="network/dns" element={<Gated feature="dns"><Dns /></Gated>} />
        <Route path="network/speed" element={<Gated feature="speedtest"><SpeedTest /></Gated>} />
        <Route path="gnss" element={<Gated feature="gnss"><Gnss /></Gated>} />
        <Route path="wifi" element={<Gated feature="wifi"><Radios /></Gated>} />
        <Route path="bluetooth" element={<Gated feature="bluetooth"><Bluetooth /></Gated>} />
        {/* Where concentrator hardware used to be; it is a forwarder's tab now. */}
        <Route path="hardware" element={<Navigate to="/lorawan/forwarders/1/concentrator" replace />} />
        <Route path="access" element={<Access />} />
        <Route path="io" element={<Panel />} />
        <Route path="logs" element={<Logs />} />
        <Route path="system" element={<Navigate to="/system/resources" replace />} />
        <Route path="system/resources" element={<Resources />} />
        <Route path="system/maintenance" element={<Maintenance />} />
        {/* A deep link to a page this build does not have goes home rather
            than rendering nothing. */}
        <Route path="*" element={<Navigate to="/" replace />} />
      </Route>
    </Routes>
  );
}

/** A page for a feature this board was not built with goes home, as an
    unknown path does; the API would only answer it with 404s. */
function Gated({ feature, children }: { feature: Feature; children: ReactNode }) {
  const features = useFeatures();
  if (features.loading) return <Spinner label="Loading" />;
  return features.has(feature) ? children : <Navigate to="/" replace />;
}
