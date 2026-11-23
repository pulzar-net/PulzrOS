import { useState } from 'react';
import { Link } from 'react-router-dom';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import {
  ArrowUpFromLine, ChevronDown, Pencil, Plus, RadioTower, SlidersHorizontal, Trash2, Waypoints, Wifi,
} from 'lucide-react';
import { api } from '@/services/api';
import type { AccessStatus, UplinksStatus } from '@/types';
import Section from '@/components/ui/Section';
import Badge from '@/components/ui/Badge';
import Button from '@/components/ui/Button';
import Notice from '@/components/ui/Notice';
import Spinner from '@/components/ui/Spinner';
import ErrorState from '@/components/ErrorState';
import ApplyChangeNotice from '@/components/ApplyChangeNotice';
import { useApplyChange, type Pending } from '@/hooks/useApplyChange';
import { useVendor } from '@/lib/oui';
import JoinWizard from '@/pages/backhaul/JoinWizard';
import { useWifiSignIn } from '@/pages/backhaul/signin';
import { signalBars } from '@/pages/backhaul/wifiFormat';
import { explain, type WifiFailureInfo } from '@/pages/backhaul/WifiFailure';
import SignalPath from './SignalPath';
import {
  ApDialog, RadioDialog, RemoveApDialog, RemoveUplinkDialog, UplinkDialog,
} from './dialogs';
import {
  BAND_NAMES, ROLE_NAMES, channelText, joiningIface, radioName, securityLabel,
  type Radio, type RadioClient, type RadioInterface, type RadiosStatus,
} from './model';
import styles from './Radios.module.css';

/**
 * The WiFi radios: what each one is, what runs on it, and the path from the
 * internet through them to the networks this gateway serves.
 *
 * The uplink's own page (Backhaul, WiFi) stays where the network it joins is
 * looked after: saved networks, 802.1X, roaming. This one decides which radio
 * it is on, and what the others do beside it. A second radio joins as a
 * second uplink, onto the same network or another, and takes the traffic
 * only once it is online (the handover in lib/radios.uc).
 */
export default function Radios() {
  const queryClient = useQueryClient();
  const change = useApplyChange();
  const [watchUntil, setWatchUntil] = useState(0);
  // Quick while a change settles, and while a handover runs: it can take two
  // minutes, longer than the change's own watch.
  const interval = () => (Date.now() < watchUntil
    || queryClient.getQueryData<RadiosStatus>(['radios'])?.handover?.state === 'joining' ? 3000 : 15_000);

  const radios = useQuery({
    queryKey: ['radios'],
    queryFn: () => api.get<RadiosStatus>('/radios'),
    refetchInterval: interval,
  });
  const access = useQuery({
    queryKey: ['access'],
    queryFn: () => api.get<AccessStatus>('/access/status'),
    refetchInterval: interval,
  });
  const detail = useQuery({
    queryKey: ['wifi-detail'],
    queryFn: () => api.get<{ failure?: WifiFailureInfo | null }>('/access/wifi'),
    refetchInterval: interval,
  });
  const signIn = useWifiSignIn();

  const [editRadio, setEditRadio] = useState<Radio | null>(null);
  const [apTarget, setApTarget] = useState<{ iface?: RadioInterface; radio?: Radio } | null>(null);
  const [removing, setRemoving] = useState<RadioInterface | null>(null);
  const [removingUplink, setRemovingUplink] = useState<RadioInterface | null>(null);
  const [moving, setMoving] = useState<Radio | null>(null);
  // `handover`: another radio's uplink carries the traffic while this join
  // runs, and the page's own notice follows it, not the wizard's outcome
  // step (which watches the WiFi page's station).
  const [wizard, setWizard] = useState<{ extra: Record<string, unknown>; handover?: boolean } | null>(null);

  const applied = (pending?: Pending | null) => {
    change.watch(pending);
    setWatchUntil(Date.now() + 60_000);
    window.setTimeout(() => {
      for (const key of ['radios', 'access', 'wifi-detail']) queryClient.invalidateQueries({ queryKey: [key] });
    }, 3000);
  };

  if (radios.isLoading) return <Spinner label="Reading the radios" />;
  if (radios.isError) return <ErrorState error={radios.error} onRetry={radios.refetch} />;

  const status = radios.data!;
  const wifi = access.data?.wifi;
  const current = wifi?.configured ? wifi.ssid : null;

  if (!status.radios.length) {
    return (
      <div className="fade-in">
        <Section wide>
          <div className={styles.empty}>No WiFi radio on this gateway.</div>
        </Section>
      </div>
    );
  }

  // Another radio's uplink keeps carrying while this one joins, so there is
  // a choice of network; with none, it is a plain join.
  const otherUplink = (radio: Radio | null) => status.uplinks.find((u) => u.radio !== radio?.id) ?? null;
  const useForUplink = (radio: Radio) => {
    if (otherUplink(radio)) setMoving(radio);
    else setWizard({ extra: { radio: radio.id } });
  };

  return (
    <div className="fade-in">
      <ApplyChangeNotice change={change} />
      <HandoverNotice status={status} />
      <Section
        title="Topology"
        icon={Wifi}
        wide
        note={status.country ? `Country ${status.country}` : undefined}
      >
        <SignalPath
          status={status}
          wifi={wifi}
          onSignIn={signIn.start}
          signingIn={signIn.isPending}
        />
        {signIn.isError && <Notice tone="error">{(signIn.error as Error).message}</Notice>}
      </Section>

      {status.radios.map((radio) => (
        <RadioCard
          key={radio.id}
          status={status}
          radio={radio}
          onSettings={() => setEditRadio(radio)}
          onAddAp={() => setApTarget({ radio })}
          onEditAp={(iface) => setApTarget({ iface, radio })}
          onRemoveAp={setRemoving}
          onRemoveUplink={setRemovingUplink}
          onUseForUplink={() => useForUplink(radio)}
        />
      ))}

      <RadioDialog status={status} radio={editRadio} onClose={() => setEditRadio(null)} onApplied={applied} />
      <ApDialog status={status} target={apTarget} onClose={() => setApTarget(null)} onApplied={applied} />
      <RemoveApDialog status={status} iface={removing} onClose={() => setRemoving(null)} onApplied={applied} />
      <UplinkDialog
        status={status}
        radio={moving}
        ssid={otherUplink(moving)?.ssid ?? current}
        onClose={() => setMoving(null)}
        onApplied={applied}
        onChooseNetwork={(radio) => {
          setMoving(null);
          setWizard({ extra: { radio: radio.id }, handover: true });
        }}
      />
      <RemoveUplinkDialog status={status} iface={removingUplink} onClose={() => setRemovingUplink(null)} onApplied={applied} />
      {wifi && (
        <JoinWizard
          open={!!wizard}
          wifi={wifi}
          failure={detail.data?.failure}
          endpoint="/radios/uplink"
          extra={wizard?.extra}
          onClose={() => setWizard(null)}
          onJoined={(pending) => {
            applied(pending);
            if (wizard?.handover) setWizard(null);
          }}
          onFailureShown={() => undefined}
        />
      )}
    </div>
  );
}

function RadioCard({
  status,
  radio,
  onSettings,
  onAddAp,
  onEditAp,
  onRemoveAp,
  onRemoveUplink,
  onUseForUplink,
}: {
  status: RadiosStatus;
  radio: Radio;
  onSettings: () => void;
  onAddAp: () => void;
  onEditAp: (iface: RadioInterface) => void;
  onRemoveAp: (iface: RadioInterface) => void;
  onRemoveUplink: (iface: RadioInterface) => void;
  onUseForUplink: () => void;
}) {
  const name = radioName(status.radios, radio.id);
  const band = { '--band': `var(--band-${radio.band})` } as React.CSSProperties;
  const carriesUplink = radio.interfaces.some((i) => i.role === 'uplink');
  const canUplink = radio.present && !carriesUplink && radio.capabilities.modes.includes('managed')
    && radio.capabilities.room.uplink;
  // A repeater is a network joined on one radio and another broadcast on a
  // radio that is not joined to anything; a radio carrying the uplink takes
  // no access point until it is disconnected.
  const canAp = radio.present && !carriesUplink && status.networks.length > 0 && radio.capabilities.room.ap;
  const state = !radio.present ? { label: 'Not detected', tone: 'error' as const }
    : !radio.enabled ? { label: 'Off', tone: 'neutral' as const }
    : radio.up ? { label: 'Up', tone: 'success' as const }
    : radio.interfaces.some((i) => i.enabled) ? { label: 'Down', tone: 'error' as const }
    : { label: 'Idle', tone: 'neutral' as const };
  const power = radio.txpower.current ?? radio.txpower.configured;

  return (
    <Section
      title={name}
      icon={RadioTower}
      note={radio.hardware ?? undefined}
      actions={
        <>
          <Badge tone={state.tone}>{state.label}</Badge>
          {radio.present && (
            <Button variant="quiet" onClick={onSettings} aria-label={`${name} settings`}>
              <SlidersHorizontal size={14} strokeWidth={2} /> Settings
            </Button>
          )}
        </>
      }
    >
      <div className={styles.specs} style={band}>
        <div className={styles.spec}>
          <span className={styles.specLabel}>Band</span>
          <span className={styles.bandPill}>{BAND_NAMES[radio.band]}</span>
        </div>
        <div className={styles.spec}>
          <span className={styles.specLabel}>Channel</span>
          <span className={`${styles.specValue} num`}>
            {channelText(radio)}
            {radio.sharedChannel ? <span className={styles.specNote}>follows uplink</span>
              : radio.channel.configured === 'auto' && radio.channel.current != null
                ? <span className={styles.specNote}>auto</span> : null}
          </span>
        </div>
        <div className={styles.spec}>
          <span className={styles.specLabel}>Width</span>
          <span className={`${styles.specValue} num`}>{radio.width.configured} MHz</span>
        </div>
        <div className={styles.spec}>
          <span className={styles.specLabel}>Power</span>
          <span className={`${styles.specValue} num`}>
            {power != null ? `${power} dBm` : 'Max'}
          </span>
        </div>
      </div>

      {radio.interfaces.length > 0 ? (
        <ul className={styles.ifaces}>
          {radio.interfaces.map((iface) => (
            <InterfaceRow key={iface.id} iface={iface} radio={radio} joining={joiningIface(status, iface)} onEdit={onEditAp}
              onRemove={iface.owner === 'radios' ? onRemoveUplink : onRemoveAp} />
          ))}
        </ul>
      ) : (
        <div className={styles.unused}>Unused</div>
      )}

      {(canAp || canUplink) && (
        <div className={styles.cardActions}>
          {canAp && (
            <Button onClick={onAddAp}>
              <Plus size={14} strokeWidth={2} /> Add Access Point
            </Button>
          )}
          {canUplink && (
            <Button variant="quiet" onClick={onUseForUplink}>
              <ArrowUpFromLine size={14} strokeWidth={2} /> Use for Uplink
            </Button>
          )}
        </div>
      )}
    </Section>
  );
}

function InterfaceRow({
  iface,
  radio,
  joining,
  onEdit,
  onRemove,
}: {
  iface: RadioInterface;
  radio: Radio;
  joining: boolean;
  onEdit: (iface: RadioInterface) => void;
  onRemove: (iface: RadioInterface) => void;
}) {
  const [open, setOpen] = useState(false);
  const station = iface.role === 'uplink' || iface.role === 'client';
  const Icon = station ? ArrowUpFromLine : iface.role === 'mesh' ? Waypoints : RadioTower;
  const clients = iface.clients ?? [];
  const bars = signalBars(iface.up ? iface.signal : null);
  const role = iface.owner === 'setup' ? 'Setup network' : ROLE_NAMES[iface.role];
  const live = radio.enabled && iface.enabled && iface.up;
  const sub = [
    role,
    station ? null : iface.networks.map((n) => n.label).join(', '),
    iface.role === 'ap' ? securityLabel(iface.security) : null,
    iface.hidden ? 'Hidden' : null,
  ].filter(Boolean);

  return (
    <li className={styles.iface}>
      <div className={styles.ifaceRow}>
        <span className={`${styles.ifaceGlyph} ${live ? styles.ifaceLive : ''}`}>
          <Icon size={15} strokeWidth={2} />
        </span>
        <div className={styles.ifaceText}>
          <span className={styles.ifaceName}>{(iface.role === 'mesh' ? iface.meshId : iface.ssid) ?? 'Unnamed'}</span>
          <span className={styles.ifaceSub}>
            {sub.map((part, i) => <span key={i}>{part}</span>)}
          </span>
        </div>
        <div className={styles.ifaceState}>
          {!iface.enabled ? <Badge tone="neutral">Off</Badge>
            : joining ? <Badge tone="neutral">Joining</Badge>
            : !iface.up ? <Badge tone={radio.enabled ? 'error' : 'neutral'}>Down</Badge>
            : station ? (
              <span className={`${styles.reading} ${styles[bars.tone]} num`}>
                <bars.icon size={15} strokeWidth={2} /> {iface.signal != null ? `${iface.signal} dBm` : bars.word}
              </span>
            ) : (
              <button
                className={styles.clientCount}
                onClick={() => setOpen(!open)}
                aria-expanded={open}
                disabled={!clients.length}
              >
                {clients.length} {clients.length === 1 ? 'client' : 'clients'}
                {clients.length > 0 && <ChevronDown size={14} strokeWidth={2} className={open ? styles.flipped : undefined} />}
              </button>
            )}
        </div>
        <div className={styles.ifaceActions}>
          {iface.owner === 'console' && (
            <>
              <button className={styles.iconButton} onClick={() => onEdit(iface)} aria-label={`Edit ${iface.ssid}`}>
                <Pencil size={14} strokeWidth={2} />
              </button>
              <button className={styles.iconButton} onClick={() => onRemove(iface)} aria-label={`Remove ${iface.ssid}`}>
                <Trash2 size={14} strokeWidth={2} />
              </button>
            </>
          )}
          {iface.owner === 'radios' && (
            <button className={styles.iconButton} onClick={() => onRemove(iface)} aria-label={`Remove ${iface.ssid}`}>
              <Trash2 size={14} strokeWidth={2} />
            </button>
          )}
          {iface.owner === 'uplink' && <Link className={styles.rowLink} to="/backhaul/wifi">Network</Link>}
          {iface.owner === 'setup' && <Link className={styles.rowLink} to="/access">Access</Link>}
        </div>
      </div>
      {open && clients.length > 0 && (
        <ul className={styles.clients}>
          {clients.map((c) => <ClientRow key={c.mac} client={c} />)}
        </ul>
      )}
    </li>
  );
}

/** The handover's state while it runs, and for a while after it failed. A
    failure is over once nobody is waiting on it: fifteen minutes. */
function HandoverNotice({ status }: { status: RadiosStatus }) {
  const h = status.handover;
  if (!h) return null;
  const to = radioName(status.radios, h.radio);
  const from = radioName(status.radios, h.fromRadio);
  if (h.state === 'joining') {
    return <Notice tone="info">{`${to} joining ${h.ssid}; ${from} carries traffic until then.`}</Notice>;
  }
  if (h.state === 'failed' && h.endedAt && Date.now() / 1000 - h.endedAt < 900) {
    const why = h.failure ? `${explain(h.failure, h.ssid).title}.` : (h.reason ?? 'No internet.');
    return <Notice tone="warning">{`${to} did not take over from ${from}: ${why}`}</Notice>;
  }
  return null;
}

/** One station on an AP, with its maker when the uplink in use is not
    metered (lib/oui.ts). */
function ClientRow({ client }: { client: RadioClient }) {
  const uplinks = useQuery({
    queryKey: ['uplinks'],
    queryFn: () => api.get<UplinksStatus>('/uplinks/status'),
    staleTime: 30_000,
    retry: false,
  });
  const active = uplinks.data?.uplinks.find((u) => u.iface === uplinks.data?.active);
  const vendor = useVendor(client.mac, active !== undefined && !active.metered);
  const bars = signalBars(client.signal);
  return (
    <li className={styles.client}>
      <span className="mono">{client.mac}</span>
      <span className={styles.vendor}>
        {vendor && 'name' in vendor ? vendor.name : vendor && 'private' in vendor ? 'Private address' : ''}
      </span>
      <span className={`${styles.reading} ${styles[bars.tone]} num`}>
        <bars.icon size={14} strokeWidth={2} /> {client.signal != null ? `${client.signal} dBm` : ''}
      </span>
      <span className={`${styles.rate} num`}>{client.rx != null ? `${Math.round(client.rx / 1000)} Mb/s` : ''}</span>
    </li>
  );
}
