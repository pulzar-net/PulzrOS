import {
  Cpu,
  KeyRound,
  Gauge,
  Lightbulb,
  Network,
  Radio,
  ScrollText,
  Settings2,
} from 'lucide-react';
import type { LucideIcon } from 'lucide-react';

/**
 * The console's pages, in sidebar order.
 *
 * One list rather than routes in one file and nav items in another: they got
 * out of step twice while this was being built, producing a nav entry that
 * routed to nothing. The router and the sidebar both read this.
 */
export interface NavEntry {
  path: string;
  label: string;
  icon: LucideIcon;
  /** Shown in the top bar. */
  title: string;
}

export const NAV: NavEntry[] = [
  { path: '/',          label: 'Overview',  icon: Gauge,      title: 'Overview' },
  { path: '/backhaul',  label: 'Backhaul',  icon: Network,    title: 'Backhaul' },
  { path: '/lorawan',   label: 'LoRaWAN',   icon: Radio,      title: 'LoRaWAN' },
  { path: '/hardware',  label: 'Hardware',  icon: Cpu,        title: 'Concentrator hardware' },
  { path: '/access',    label: 'Access',    icon: KeyRound,   title: 'Access' },
  { path: '/io',        label: 'Panel',     icon: Lightbulb,  title: 'LEDs and buttons' },
  { path: '/logs',      label: 'Logs',      icon: ScrollText, title: 'System log' },
  { path: '/system',    label: 'System',    icon: Settings2,  title: 'System' },
];
