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
 * The console's pages, in sidebar order, under the sidebar's headings.
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

/** An area's hue (tokens.css --hue-*): its icon, cards and table headers. */
export type Tone = 'green' | 'blue' | 'violet' | 'teal' | 'amber' | 'rose' | 'sky' | 'indigo' | 'slate';

export interface NavEntry {
  path: string;
  label: string;
  icon: LucideIcon;
  tone: Tone;
  feature?: Feature;
  children?: NavChild[];
  /** Uses the whole window rather than the reading column — a table that
      needs every column it can get. */
  wide?: boolean;
}

/** A run of the sidebar under one heading. The first has none: Overview
    stands above the rest. */
export interface NavGroup {
  label?: string;
  entries: NavEntry[];
}

export const NAV_GROUPS: NavGroup[] = [
  {
    entries: [{ path: '/', label: 'Overview', icon: Gauge, tone: 'green' }],
  },
  {
    label: 'Connectivity',
    entries: [
      {
        path: '/backhaul',
        label: 'Backhaul',
        icon: Network, tone: 'blue',
        children: [
          { path: '/backhaul/ethernet', label: 'Ethernet' },
          { path: '/backhaul/cellular', label: 'Cellular', feature: 'cellular' },
          { path: '/backhaul/wifi', label: 'WiFi', feature: 'wifi' },
        ],
      },
      {
        path: '/network',
        label: 'Network',
        icon: Router, tone: 'violet',
        children: [
          { path: '/network/ports', label: 'Ports', wide: true },
          { path: '/network/lan', label: 'LAN', feature: 'lan', wide: true },
          { path: '/network/uplinks', label: 'Uplinks', feature: 'failover' },
          { path: '/network/dns', label: 'DNS', feature: 'dns' },
          { path: '/network/speed', label: 'Speed Test', feature: 'speedtest' },
        ],
      },
      { path: '/access', label: 'Access', icon: KeyRound, tone: 'amber' },
    ],
  },
  {
    label: 'Radios',
    entries: [
      {
        path: '/lorawan',
        label: 'LoRaWAN',
        icon: Radio, tone: 'teal',
        feature: 'lorawan',
        children: [
          { path: '/lorawan/forwarders', label: 'Forwarders' },
          { path: '/lorawan/settings', label: 'Settings' },
        ],
      },
      { path: '/bluetooth', label: 'Bluetooth', icon: Bluetooth, tone: 'indigo', feature: 'bluetooth' },
      { path: '/gnss', label: 'GNSS', icon: Satellite, tone: 'sky', feature: 'gnss' },
    ],
  },
  {
    label: 'Gateway',
    entries: [
      { path: '/io', label: 'Panel', icon: Lightbulb, tone: 'rose' },
      { path: '/logs', label: 'Logs', icon: ScrollText, tone: 'slate', wide: true },
      {
        path: '/system',
        label: 'System',
        icon: Settings2, tone: 'sky',
        children: [
          { path: '/system/resources', label: 'Resources', wide: true },
          { path: '/system/maintenance', label: 'Maintenance' },
        ],
      },
    ],
  },
];

/** Every entry, in sidebar order, for what does not care about the groups. */
export const NAV: NavEntry[] = NAV_GROUPS.flatMap((group) => group.entries);
