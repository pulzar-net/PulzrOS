import { useQuery } from '@tanstack/react-query';
import { ShieldCheck } from 'lucide-react';
import { api } from '@/services/api';
import type { BackhaulStatus } from '@/types';
import Section from '@/components/ui/Section';
import Badge, { StatusBadge } from '@/components/ui/Badge';
import Fact, { FactList } from '@/components/Fact';

/**
 * On Backhaul since the Access page went (owner, 23 Nov 2026).
 *
 * How Pulzr Cloud reaches this gateway: a WireGuard tunnel the gateway opens
 * outwards, so nothing at the site has to accept an inbound connection.
 */
export default function ManagementTunnel() {
  const paths = useQuery({
    queryKey: ['backhaul'],
    queryFn: () => api.get<BackhaulStatus>('/network/backhaul'),
    refetchInterval: 15_000,
  });
  const tunnel = paths.data?.tunnel;

  return (
    <Section title="Management Tunnel" icon={ShieldCheck}>
      <FactList>
        <Fact
          label="State"
          value={
            tunnel ? (
              <StatusBadge
                ok={tunnel.state === 'up'}
                okLabel="Connected"
                badLabel={
                  tunnel.state === 'none'
                    ? 'Not enrolled'
                    : tunnel.state === 'waiting'
                      ? 'No recent handshake'
                      : 'Unknown'
                }
              />
            ) : null
          }
        />
        <Fact label="Address" value={tunnel?.address} mono />
        <Fact label="Hub" value={tunnel?.endpoint} mono />
        <Fact
          label="Last handshake"
          value={tunnel?.lastHandshake != null ? `${tunnel.lastHandshake}s ago` : null}
        />
        <Fact
          label="Egress"
          value={
            paths.data?.wired.device ? (
              <span className="mono">
                {paths.data.wired.device} → {paths.data.wired.gateway}
              </span>
            ) : paths.data?.tunnel.via === 'wifi' ? (
              'WiFi'
            ) : paths.data ? (
              <Badge tone="warning">No ethernet or WiFi route</Badge>
            ) : null
          }
        />
      </FactList>
    </Section>
  );
}
