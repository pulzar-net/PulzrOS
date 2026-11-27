import { PortsDiagram } from '@pulzr/ui';
import type { Port, PortRole } from '@/types';
import { useHardware } from '@/hooks/useHardware';
import { useFeatures } from '@/hooks/useFeatures';
import { useCellular } from '@/hooks/useCellular';
import styles from './Ports.module.css';

/**
 * The gateway's face, as on the case (@pulzr/ui's PortsDiagram, the same one
 * Pulzr Cloud draws): its antennas, modem and power, then its jacks, each
 * named, lit by its link and marked with its role. Network > Ports edits from
 * it; the Network page shows it and opens the port there.
 */

export const ROLE_NAMES: Record<PortRole, string> = { uplink: 'Uplink', devices: 'LAN', none: 'Unused' };

/** Gigabit and up, fast Ethernet, or nothing: the colour of a port's dot in a table. */
export function tier(port: Port) {
  if (!port.link.up) return '';
  return (port.link.speed ?? 0) >= 1000 ? styles.gigabit : styles.fast;
}

export function speed(mbps: number | null | undefined) {
  if (!mbps) return null;
  return mbps >= 1000 ? `${mbps / 1000} Gb/s` : `${mbps} Mb/s`;
}

export default function PortStrip({
  ports, roleOf = (port) => port.role, selected, hovered, onSelect, onHover,
}: {
  ports: Port[];
  /** The role to draw: the Ports page's draft, else what the gateway has. */
  roleOf?: (port: Port) => PortRole;
  selected?: string | null;
  hovered?: string | null;
  onSelect: (name: string) => void;
  onHover?: (name: string | null) => void;
}) {
  const hardware = useHardware();
  const features = useFeatures();
  const cellular = useCellular();
  return (
    <div className={styles.face}>
      <PortsDiagram
        hardware={hardware}
        ports={ports.map((p) => ({ name: p.name, label: p.label, up: !!p.link.up, speed: p.link.speed, role: roleOf(p) }))}
        active={{ lora: features.has('lorawan'), lte: cellular.shown, power: true }}
        selected={selected}
        hovered={hovered}
        onSelect={onSelect}
        onHover={onHover}
      />
    </div>
  );
}
