import { EthernetPort } from 'lucide-react';
import type { Port, PortRole } from '@/types';
import styles from './Ports.module.css';

/**
 * The gateway's jacks in a row, the way a switch's own page draws them: each
 * one's role, name and speed, its socket coloured by link. Network > Ports
 * edits from it; the Network page shows it and opens the port there.
 */

export const ROLE_NAMES: Record<PortRole, string> = { uplink: 'Uplink', devices: 'LAN', none: 'Unused' };

/** Gigabit and up, fast Ethernet, or nothing: the colour of a jack. */
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
  return (
    <div className={styles.strip} role="list">
      {ports.map((port) => {
        const role = roleOf(port);
        return (
          <button
            key={port.name}
            type="button"
            role="listitem"
            className={`${styles.jack} ${tier(port)} ${selected === port.name ? styles.selected : ''} ${hovered === port.name ? styles.lit : ''}`}
            onClick={() => onSelect(port.name)}
            onMouseEnter={() => onHover?.(port.name)}
            onMouseLeave={() => onHover?.(null)}
            aria-label={`${port.label}, ${ROLE_NAMES[role]}`}
          >
            <span className={styles.jackRole}>{ROLE_NAMES[role]}</span>
            <span className={styles.socket}><EthernetPort size={20} strokeWidth={1.8} /></span>
            <span className={styles.jackName}>{port.label}</span>
            <span className={styles.jackSpeed}>{port.link.up ? speed(port.link.speed) ?? 'Up' : '—'}</span>
          </button>
        );
      })}
    </div>
  );
}
