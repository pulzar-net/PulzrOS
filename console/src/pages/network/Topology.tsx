import { useEffect, useRef, type CSSProperties } from 'react';
import {
  Background,
  Handle,
  Position,
  ReactFlow,
  ReactFlowProvider,
  useReactFlow,
  type Edge,
  type Node,
  type NodeProps,
} from '@xyflow/react';
import '@xyflow/react/dist/style.css';
import { Cable, Globe, RadioTower, Router, Signal, Wifi, type LucideIcon } from 'lucide-react';
import type { LanClient, Port, PortRole, UplinksStatus } from '@/types';
import { uplinkName } from '@/lib/format';
import {
  BAND_NAMES, ROLE_NAMES, channelText, joiningIface, type RadiosStatus,
} from '@/pages/radios/model';
import { speed } from './Ports';
import styles from './Topology.module.css';

/**
 * The gateway as Pulzr Cloud's Topology draws one (parkeze.net MeshView, the
 * same React Flow and the same cards), left to right: the internet, every
 * uplink that could reach it (a WAN port, a WiFi station, the modem), the
 * gateway, and what it serves (LAN ports, access points, the radios doing
 * nothing). The uplink carrying the traffic is the heavy line.
 *
 * A fixed four-column layout rather than Cloud's ELK: a gateway has a dozen
 * cards at most and always the same shape, and a layout engine is a quarter
 * of a megabyte to put them in the same place every time.
 */

type Health = 'up' | 'down' | 'off';

interface Card {
  [key: string]: unknown;
  kind: 'internet' | 'gateway' | 'side';
  title: string;
  sub: string | null;
  icon: LucideIcon;
  /** A radio's band, down the card's edge. */
  stripe?: string;
  health: Health | null;
  /** Uplink, or In Use for the one carrying traffic. */
  tag?: string;
  active?: boolean;
  /** What a click opens: a port's editor, a radio's settings. */
  open?: () => void;
}

interface Item {
  id: string;
  card: Card;
  /** The line's color, as a CSS variable. */
  color: string;
  up: boolean;
}

function CardNode({ data }: NodeProps<Node<Card>>) {
  const Icon = data.icon;
  return (
    <div
      className={[styles.node, styles[data.kind], data.open ? styles.clickable : '', data.health === 'off' ? styles.idle : ''].join(' ')}
      style={data.stripe ? { '--stripe': `var(${data.stripe})` } as CSSProperties : undefined}
      title={[data.title, data.sub].filter(Boolean).join('\n')}
    >
      <Handle type="target" position={Position.Left} className={styles.handle} />
      {data.health && <span className={`${styles.health} ${styles[data.health]}`} />}
      <span className={styles.icon}><Icon size={14} strokeWidth={2} /></span>
      <span className={styles.text}>
        <span className={styles.title}>{data.title}</span>
        {data.sub && <span className={styles.sub}>{data.sub}</span>}
      </span>
      {data.tag && <span className={`${styles.tag} ${data.active ? styles.inUse : ''}`}>{data.tag}</span>}
      <Handle type="source" position={Position.Right} className={styles.handle} />
    </div>
  );
}

const NODE_TYPES = { card: CardNode };
const HEIGHT = 46;
const ROW = HEIGHT + 12;
const GAP = 64;
const WIDTH = { internet: 120, side: 236, gateway: 172 };
const X = {
  internet: 0,
  left: WIDTH.internet + GAP,
  gateway: WIDTH.internet + GAP + WIDTH.side + GAP,
  right: WIDTH.internet + GAP + WIDTH.side + GAP + WIDTH.gateway + GAP,
};

const join = (...parts: (string | null | undefined | false)[]) => parts.filter(Boolean).join(' · ') || null;
const plural = (n: number, one: string) => `${n} ${one}${n === 1 ? '' : 's'}`;

export interface TopologyProps {
  ports: Port[];
  /** The role to draw: the page's draft, so an edit shows before Apply. */
  roleOf: (port: Port) => PortRole;
  radios: RadiosStatus | undefined;
  uplinks: UplinksStatus | undefined;
  clients: LanClient[];
  /** The gateway's own name and its LAN address. */
  hostname: string | null;
  lanAddress: string | null;
  onPort: (name: string) => void;
  onRadio: (radio: string) => void;
}

function build(p: TopologyProps) {
  const active = p.uplinks?.active ?? null;
  const left: Item[] = [];
  const right: Item[] = [];
  const behind = (device: string) => p.clients.filter((c) => c.online && (c.port === device || c.port?.startsWith(`${device}.`))).length;

  for (const port of p.ports) {
    const up = !!port.link.up;
    const role = p.roleOf(port);
    const link = up ? speed(port.link.speed) ?? 'Up' : 'No cable';
    const vlans = port.vlans.length ? `VLAN ${port.vlans.map((v) => v.vid).join(', ')}` : null;
    const open = () => p.onPort(port.name);
    if (role === 'uplink' || port.vlans.some((v) => v.role === 'uplink')) {
      const inUse = !!active && (port.uplink?.iface === active || port.vlans.some((v) => v.uplink?.iface === active));
      left.push({
        id: `port:${port.name}`, color: '--proto-wire', up,
        card: { kind: 'side', icon: Cable, title: port.label, health: up ? 'up' : 'down', open,
                sub: join(link, up && port.uplink?.state.address, vlans),
                tag: inUse ? 'In Use' : 'Uplink', active: inUse },
      });
    } else {
      right.push({
        id: `port:${port.name}`, color: '--proto-lan', up: up && role === 'devices',
        card: { kind: 'side', icon: Cable, title: port.label, health: role === 'none' ? 'off' : up ? 'up' : 'down', open,
                sub: join(link, role === 'none' ? 'Unused' : up && plural(behind(port.name), 'client'), vlans) },
      });
    }
  }

  for (const radio of p.radios?.radios ?? []) {
    const band = BAND_NAMES[radio.band] ?? radio.band;
    const stripe = `--band-${radio.band}`;
    const open = radio.present ? () => p.onRadio(radio.id) : undefined;
    const live = radio.enabled ? radio.interfaces.filter((i) => i.enabled) : [];
    if (!radio.present || !live.length) {
      right.push({
        id: `radio:${radio.id}`, color: stripe, up: false,
        card: { kind: 'side', icon: RadioTower, title: `${band} Radio`, stripe, health: 'off', open,
                sub: !radio.present ? 'Not detected' : !radio.enabled ? 'Off' : 'Idle' },
      });
      continue;
    }
    for (const iface of live) {
      const channel = `ch ${channelText(radio)}`;
      if (iface.role === 'uplink' || iface.role === 'client') {
        const inUse = !!active && iface.networks.some((n) => n.id === active);
        left.push({
          id: `wifi:${radio.id}:${iface.id}`, color: stripe, up: iface.up,
          card: { kind: 'side', icon: Wifi, title: iface.ssid ?? 'WiFi', stripe, health: iface.up ? 'up' : 'down', open,
                  sub: join(band, channel, joiningIface(p.radios!, iface) ? 'Joining'
                    : iface.up ? (iface.signal != null ? `${iface.signal} dBm` : 'Connected') : 'Not connected'),
                  tag: inUse ? 'In Use' : 'Uplink', active: inUse },
        });
      } else {
        right.push({
          id: `wifi:${radio.id}:${iface.id}`, color: stripe, up: iface.up,
          card: { kind: 'side', icon: RadioTower, stripe, health: iface.up ? 'up' : 'down', open,
                  title: (iface.role === 'mesh' ? iface.meshId : iface.ssid) ?? ROLE_NAMES[iface.role],
                  sub: join(band, channel, iface.owner === 'setup' ? 'Setup network'
                    : iface.role === 'ap' ? plural(iface.clients?.length ?? 0, 'client') : ROLE_NAMES[iface.role]) },
        });
      }
    }
  }

  // The modem: an uplink with no port or radio of its own on this page.
  for (const u of p.uplinks?.uplinks ?? []) {
    if (u.kind !== 'cellular' && u.kind !== 'usb-cellular') continue;
    const inUse = u.iface === active;
    left.push({
      id: `uplink:${u.iface}`, color: '--proto-cellular', up: u.up,
      card: { kind: 'side', icon: Signal, title: uplinkName(u.iface), health: u.up ? 'up' : 'down',
              sub: u.up ? (u.state === 'online' ? 'Online' : u.state === 'offline' ? 'No internet' : 'Up') : 'Down',
              tag: inUse ? 'In Use' : 'Uplink', active: inUse },
    });
  }

  const height = Math.max(left.length, right.length, 1) * ROW - (ROW - HEIGHT);
  const column = (items: Item[], x: number, width: number) => items.map((item, i): Node<Card> => ({
    id: item.id, type: 'card', data: item.card, width, height: HEIGHT,
    position: { x, y: (height - (items.length * ROW - (ROW - HEIGHT))) / 2 + i * ROW },
  }));
  const middle = (height - HEIGHT) / 2;
  const nodes: Node<Card>[] = [
    { id: 'internet', type: 'card', width: WIDTH.internet, height: HEIGHT, position: { x: X.internet, y: middle },
      data: { kind: 'internet', icon: Globe, title: 'Internet', sub: null, health: null } },
    { id: 'gateway', type: 'card', width: WIDTH.gateway, height: HEIGHT, position: { x: X.gateway, y: middle },
      data: { kind: 'gateway', icon: Router, title: p.hostname ?? 'Gateway', sub: p.lanAddress, health: null } },
    ...column(left, X.left, WIDTH.side),
    ...column(right, X.right, WIDTH.side),
  ];

  // Color is the medium; the uplink in use is the heavy line, a standby one
  // dashed, and nothing on the other end dotted.
  const line = (item: Item, heavy: boolean): CSSProperties => ({
    stroke: `var(${item.up ? item.color : '--text-tertiary'})`,
    strokeWidth: heavy ? 3.6 : 2,
    strokeDasharray: !item.up ? '1 5' : item.card.tag && !heavy ? '7 5' : undefined,
    strokeLinecap: 'round',
  });
  const edges: Edge[] = [
    ...left.flatMap((item) => [
      { id: `internet-${item.id}`, source: 'internet', target: item.id, type: 'smoothstep', style: line(item, !!item.card.active) },
      { id: `${item.id}-gateway`, source: item.id, target: 'gateway', type: 'smoothstep', style: line(item, !!item.card.active) },
    ]),
    ...right.map((item) => ({ id: `gateway-${item.id}`, source: 'gateway', target: item.id, type: 'smoothstep',
                              style: line(item, false) })),
  ];
  return { nodes, edges, height };
}

const FIT = { padding: 0.04, maxZoom: 1 };

function Flow(props: TopologyProps) {
  const { nodes, edges, height } = build(props);
  const box = useRef<HTMLDivElement>(null);
  const flow = useReactFlow();
  // Refit when the card's width changes (the sidebar, a phone turned), not
  // only at mount; and when the diagram gains or loses a row.
  useEffect(() => {
    const el = box.current;
    if (!el) return;
    const fit = () => flow.fitView(FIT);
    const observer = new ResizeObserver(fit);
    observer.observe(el);
    fit();
    return () => observer.disconnect();
  }, [flow, nodes.length]);

  return (
    // Below the inner box's minimum width the box scrolls sideways rather
    // than the cards shrinking past reading on a phone.
    <div className={styles.canvas}>
      <div ref={box} className={styles.flow} style={{ height: height + 48 }}>
        <ReactFlow
          nodes={nodes}
          edges={edges}
          nodeTypes={NODE_TYPES}
          colorMode="system"
          fitView
          fitViewOptions={FIT}
          // A picture in a page, not a canvas to explore: the wheel scrolls the
          // page, and nothing moves under a click.
          nodesDraggable={false}
          nodesConnectable={false}
          elementsSelectable={false}
          panOnDrag={false}
          zoomOnScroll={false}
          zoomOnPinch={false}
          zoomOnDoubleClick={false}
          preventScrolling={false}
          proOptions={{ hideAttribution: true }}
          onNodeClick={(_, node) => (node.data as Card).open?.()}
        >
          <Background gap={18} size={1.2} />
        </ReactFlow>
      </div>
    </div>
  );
}

export default function Topology(props: TopologyProps) {
  return (
    <ReactFlowProvider>
      <Flow {...props} />
    </ReactFlowProvider>
  );
}
