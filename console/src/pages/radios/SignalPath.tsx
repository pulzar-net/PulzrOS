import type { ReactNode } from 'react';
import { Link as RouterLink } from 'react-router-dom';
import { Cable, Globe, RadioTower, Router, Signal, Users, Waypoints, Wifi } from 'lucide-react';
import type { AccessStatus } from '@/types';
import Badge, { type Tone } from '@/components/ui/Badge';
import Button from '@/components/ui/Button';
import { signalBars } from '@/pages/backhaul/wifiFormat';
import {
  BAND_NAMES, ROLE_NAMES, channelText, gatewayMode, joiningIface, radioName, securityLabel,
  type Radio, type RadioInterface, type RadiosStatus,
} from './model';
import styles from './SignalPath.module.css';

/**
 * The gateway's WiFi as a path, left to right: the internet, what the gateway
 * reaches it through, the gateway with its radios, and the networks it serves
 * and who is on them. Each hop that is a radio is labelled with it, so a
 * two-radio repeater reads at a glance: the site's network on one radio, the
 * gateway's own on the other.
 *
 * Plain markup, not a canvas: the hops are cards with words in them, which
 * have to wrap, stay selectable and work on a phone, where the path turns to
 * run down the screen.
 */

type LinkState = 'live' | 'down' | 'idle' | 'held';

interface Upstream {
  key: string;
  kind: 'wifi' | 'ethernet' | 'cellular' | 'other' | 'none';
  carrying: boolean;
  /** A second radio's station the handover is still proving. */
  joining?: boolean;
  radio?: Radio;
  iface?: RadioInterface;
}

export default function SignalPath({
  status,
  wifi,
  onSignIn,
  signingIn,
}: {
  status: RadiosStatus;
  wifi: AccessStatus['wifi'] | undefined;
  onSignIn: () => void;
  signingIn: boolean;
}) {
  const { radios, route } = status;
  const mode = gatewayMode(status);

  // Left of the gateway: the WiFi uplink when there is one, and whatever
  // carries the traffic when that is something else.
  const upstreams: Upstream[] = [];
  for (const radio of radios) {
    for (const iface of radio.interfaces) {
      if (iface.role !== 'uplink' && iface.role !== 'client') continue;
      // With two WiFi uplinks, the one whose interface has the default route.
      const carrying = route.via === 'wifi' && iface.role === 'uplink' && iface.networks.some((n) => n.id === route.iface);
      upstreams.push({ key: iface.id, kind: 'wifi', carrying, joining: joiningIface(status, iface), radio, iface });
    }
  }
  if (route.via && route.via !== 'wifi') {
    const kind = route.via === 'ethernet' ? 'ethernet' : route.via === 'other' ? 'other' : 'cellular';
    upstreams.push({ key: 'route', kind, carrying: true });
  }
  if (!upstreams.length) upstreams.push({ key: 'none', kind: 'none', carrying: false });

  // Right of it: every access point and mesh, on the radio it runs on.
  const served: { radio: Radio; iface: RadioInterface }[] = [];
  for (const radio of radios) {
    for (const iface of radio.interfaces) {
      if (iface.role === 'ap' || iface.role === 'mesh') served.push({ radio, iface });
    }
  }

  // The internet is reached when what carries the traffic gets through: a
  // WiFi uplink held at a sign-in page carries nothing past it.
  const reaches = (u: Upstream) => u.carrying && !upstreamState(u, wifi).portal;
  const internetLive = upstreams.some(reaches);

  return (
    <div className={styles.path}>
      <div className={styles.hop}>
        <Node icon={Globe} tone={internetLive ? 'live' : upstreams.some((u) => u.carrying) ? 'held' : 'down'} title="Internet" kind="internet" />
      </div>

      <Fan side="both">
        {upstreams.map((u) => {
          const state = upstreamState(u, wifi);
          return (
            <div key={u.key} className={styles.row}>
              <Line state={reaches(u) ? 'live' : u.carrying && state.portal ? 'held' : state.link === 'live' ? 'idle' : state.link} />
              <UpstreamNode upstream={u} state={state} onSignIn={onSignIn} signingIn={signingIn} />
              <Line
                state={state.link}
                band={u.radio?.band}
                label={u.radio ? <RadioTag radios={radios} radio={u.radio} /> : null}
              />
            </div>
          );
        })}
      </Fan>

      <div className={styles.hop}>
        <div className={`${styles.node} ${styles.gateway}`}>
          <div className={styles.nodeHead}>
            <span className={`${styles.glyph} ${styles.glyphGateway}`}><Router size={18} strokeWidth={1.9} /></span>
            <div className={styles.nodeTitle}>
              <span className={styles.name}>{status.hostname ?? 'This gateway'}</span>
              <Badge tone={mode.repeater ? 'success' : 'neutral'}>{mode.label}</Badge>
            </div>
          </div>
          <ul className={styles.antennas} aria-label="Radios">
            {radios.map((radio) => {
              const busy = radio.enabled && radio.interfaces.some((i) => i.enabled);
              return (
                <li key={radio.id} className={busy ? undefined : styles.idleRadio} style={bandStyle(radio.band)}>
                  <span className={styles.dot} />
                  <span>{radioName(radios, radio.id)}</span>
                  <span className={styles.dim}>{BAND_NAMES[radio.band]}</span>
                  {!radio.enabled && <span className={styles.dim}>Off</span>}
                </li>
              );
            })}
          </ul>
        </div>
      </div>

      <Fan side="left">
        {served.length ? served.map(({ radio, iface }) => (
          <div key={iface.id} className={styles.row}>
            <Line
              state={radio.enabled && iface.enabled ? (iface.up ? 'live' : 'down') : 'idle'}
              band={radio.band}
              label={<RadioTag radios={radios} radio={radio} />}
            />
            <ServedNode iface={iface} />
          </div>
        )) : (
          <div className={styles.row}>
            <Line state="idle" />
            <div className={`${styles.node} ${styles.ghost}`}>
              <span className={styles.ghostTitle}>No access point</span>
            </div>
          </div>
        )}
      </Fan>
    </div>
  );
}

function bandStyle(band?: string) {
  return band ? ({ '--band': `var(--band-${band})` } as React.CSSProperties) : undefined;
}

/** A column of hops joined by a bar on one side or both, so several meet
    the one hop beside them. */
function Fan({ side, children }: { side: 'left' | 'both'; children: ReactNode }) {
  return <div className={`${styles.fan} ${side === 'both' ? styles.both : ''}`}>{children}</div>;
}

function Line({ state, band, label }: { state: LinkState; band?: string; label?: ReactNode }) {
  return (
    <div className={`${styles.line} ${styles[state]} ${label ? styles.labelled : ''}`} style={bandStyle(band)}>
      <span className={styles.wire} aria-hidden />
      {label}
    </div>
  );
}

/** A radio hop's label: its band over the wire, which radio and channel
    under it. */
function RadioTag({ radios, radio }: { radios: Radio[]; radio: Radio }) {
  return (
    <>
      <span className={styles.over}><span className={styles.band}>{BAND_NAMES[radio.band]}</span></span>
      <span className={`${styles.under} num`}>{radioName(radios, radio.id)}, ch {channelText(radio)}</span>
    </>
  );
}

function Node({
  icon: Icon,
  tone,
  title,
  kind,
  children,
}: {
  icon: typeof Globe;
  tone: LinkState;
  title: ReactNode;
  kind?: string;
  children?: ReactNode;
}) {
  return (
    <div className={`${styles.node} ${kind ? styles[kind] : ''}`}>
      <div className={styles.nodeHead}>
        <span className={`${styles.glyph} ${styles[`glyph_${tone}`]}`}><Icon size={17} strokeWidth={1.9} /></span>
        <div className={styles.nodeTitle}>{title}</div>
      </div>
      {children}
    </div>
  );
}

interface UpState {
  link: LinkState;
  badge: { label: string; tone: Tone } | null;
  portal: boolean;
}

function upstreamState(u: Upstream, wifi: AccessStatus['wifi'] | undefined): UpState {
  if (u.kind === 'none') return { link: 'down', badge: { label: 'No uplink', tone: 'error' }, portal: false };
  if (u.kind !== 'wifi') return { link: 'live', badge: null, portal: false };
  const iface = u.iface!;
  if (!u.radio!.enabled || !iface.enabled) return { link: 'idle', badge: { label: 'Off', tone: 'neutral' }, portal: false };
  if (u.joining) return { link: 'idle', badge: { label: 'Joining', tone: 'neutral' }, portal: false };
  if (!iface.up) return { link: 'down', badge: { label: 'Not connected', tone: 'error' }, portal: false };
  // The WiFi page's answers (address, portal) are about its own station; a
  // second radio's carries traffic only once proven, so up is all it needs.
  if (iface.owner === 'radios') {
    return { link: 'live', badge: u.carrying ? { label: 'Connected', tone: 'success' } : { label: 'Standby', tone: 'neutral' }, portal: false };
  }
  if (iface.role !== 'uplink' || !wifi?.configured) return { link: 'live', badge: null, portal: false };
  if (!wifi.up) return { link: 'down', badge: { label: 'No address', tone: 'warning' }, portal: false };
  if (wifi.uplink === 'portal') return { link: 'live', badge: { label: 'Sign-in needed', tone: 'warning' }, portal: true };
  if (wifi.uplink === 'offline') return { link: 'live', badge: { label: 'No internet', tone: 'warning' }, portal: true };
  if (!u.carrying) return { link: 'live', badge: { label: 'Standby', tone: 'neutral' }, portal: false };
  return { link: 'live', badge: { label: 'Connected', tone: 'success' }, portal: false };
}

function UpstreamNode({
  upstream: u,
  state,
  onSignIn,
  signingIn,
}: {
  upstream: Upstream;
  state: UpState;
  onSignIn: () => void;
  signingIn: boolean;
}) {
  if (u.kind !== 'wifi') {
    const icon = u.kind === 'ethernet' ? Cable : u.kind === 'none' ? Globe : Signal;
    const title = { ethernet: 'Ethernet', cellular: 'Cellular', other: 'Uplink', none: 'No uplink', wifi: '' }[u.kind];
    return (
      <Node icon={icon} tone={state.link} title={<span className={styles.name}>{title}</span>}>
        {state.badge && <div className={styles.meta}><Badge tone={state.badge.tone}>{state.badge.label}</Badge></div>}
      </Node>
    );
  }
  const iface = u.iface!;
  const bars = signalBars(iface.up ? iface.signal : null);
  return (
    <Node
      icon={iface.up ? bars.icon : Wifi}
      tone={state.link}
      title={
        <RouterLink className={`${styles.name} ${styles.nameLink}`} to="/backhaul/wifi">
          {iface.ssid ?? 'Unnamed network'}
        </RouterLink>
      }
    >
      <div className={styles.meta}>
        {state.badge && <Badge tone={state.badge.tone}>{state.badge.label}</Badge>}
        {iface.up && iface.signal != null && <span className={`${styles.dim} num`}>{iface.signal} dBm</span>}
      </div>
      {state.portal && (
        <div className={styles.nodeAction}>
          <Button variant="primary" loading={signingIn} onClick={onSignIn}>Sign In</Button>
        </div>
      )}
    </Node>
  );
}

function ServedNode({ iface }: { iface: RadioInterface }) {
  const clients = iface.clients?.length ?? 0;
  const mesh = iface.role === 'mesh';
  return (
    <Node
      icon={mesh ? Waypoints : RadioTower}
      tone={iface.enabled ? (iface.up ? 'live' : 'down') : 'idle'}
      title={
        <>
          <span className={styles.name}>{(mesh ? iface.meshId : iface.ssid) ?? 'Unnamed'}</span>
          {iface.owner === 'setup' && <Badge tone="info">Setup</Badge>}
          {!iface.enabled && <Badge tone="neutral">Off</Badge>}
        </>
      }
    >
      <div className={styles.meta}>
        <span className={styles.dim}>
          {mesh ? ROLE_NAMES.mesh : iface.networks.map((n) => n.label).join(', ') || 'No network'}
        </span>
        {!mesh && <span className={styles.dim}>{securityLabel(iface.security)}</span>}
        {iface.up && (
          <span className={`${styles.clients} num`} title={`${clients} connected`}>
            <Users size={13} strokeWidth={2} /> {clients}
          </span>
        )}
      </div>
    </Node>
  );
}
