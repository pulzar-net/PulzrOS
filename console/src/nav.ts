import {
  Bluetooth,
  Gauge,
  KeyRound,
  Lightbulb,
  Network,
  Radio,
  Router,
  Satellite,
  ScrollText,
  Settings2,
} from 'lucide-react';
import type { LucideIcon } from 'lucide-react';
import type { Feature } from '@/types';

/**
 * The console's pages, in sidebar order.
 *
 * One list rather than routes in one file and nav items in another: they got
 * out of step twice while this was being built, producing a nav entry that
 * routed to nothing. The sidebar reads this; App.tsx routes every path in it.
 *
 * A section with children is a group, not a page: its own path goes to the
 * first child, and the children show in the sidebar while you are inside it.
 *
 * An entry with a feature exists only on a board built with it; the sidebar
 * leaves it out, and a group whose children are all left out, and App.tsx
 * sends its route home.
 */
export interface NavChild {
  path: string;
  label: string;
  wide?: boolean;
  feature?: Feature;
}

export interface NavEntry {
  path: string;
  label: string;
  icon: LucideIcon;
  feature?: Feature;
  children?: NavChild[];
  /** Uses the whole window rather than the reading column — a table that
      needs every column it can get. */
  wide?: boolean;
}

export const NAV: NavEntry[] = [
  { path: '/', label: 'Overview', icon: Gauge },
  {
    path: '/backhaul',
    label: 'Backhaul',
    icon: Network,
    children: [
      { path: '/backhaul/ethernet', label: 'Ethernet' },
      { path: '/backhaul/cellular', label: 'Cellular', feature: 'cellular' },
      { path: '/backhaul/wifi', label: 'WiFi', feature: 'wifi' },
    ],
  },
  {
    path: '/lorawan',
    label: 'LoRaWAN',
    icon: Radio,
    feature: 'lorawan',
    children: [
      { path: '/lorawan/forwarders', label: 'Forwarders' },
      { path: '/lorawan/settings', label: 'Settings' },
    ],
  },
  {
    path: '/network',
    label: 'Network',
    icon: Router,
    children: [
      { path: '/network/lan', label: 'LAN', feature: 'lan', wide: true },
      { path: '/network/uplinks', label: 'Uplinks', feature: 'failover' },
      { path: '/network/dns', label: 'DNS', feature: 'dns' },
    ],
  },
  { path: '/gnss', label: 'GNSS', icon: Satellite, feature: 'gnss' },
  { path: '/bluetooth', label: 'Bluetooth', icon: Bluetooth, feature: 'bluetooth' },
  { path: '/access', label: 'Access', icon: KeyRound },
  { path: '/io', label: 'Panel', icon: Lightbulb },
  { path: '/logs', label: 'Logs', icon: ScrollText, wide: true },
  {
    path: '/system',
    label: 'System',
    icon: Settings2,
    children: [
      { path: '/system/resources', label: 'Resources', wide: true },
      { path: '/system/maintenance', label: 'Maintenance' },
    ],
  },
];
