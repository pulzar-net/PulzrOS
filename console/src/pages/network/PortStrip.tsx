import { PortsDiagram } from '@pulzr/ui';
import type { Port, PortRole } from '@/types';
import { useHardware } from '@/hooks/useHardware';
import { useFeatures } from '@/hooks/useFeatures';
import { useCellular } from '@/hooks/useCellular';
import styles from './Ports.module.css';

/**
 * The gateway's face, as on the case (@pulzr/ui's PortsDiagram, the same one
 * Pulzr Cloud draws, from the board's hardware.json): its antennas, modem and
 * power, then its jacks, each named, lit by its link and marked with its
 * role. On the Network page above the topology; a jack opens its port.
 */
export default function PortStrip({
  ports, roleOf = (port) => port.role, selected, hovered, onSelect, onHover,
}: {
  ports: Port[];
  /** The role to draw: the page's draft, else what the gateway has. */
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
