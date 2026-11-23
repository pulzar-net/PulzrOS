import { useEffect, useMemo, useState, type ReactNode } from 'react';
import { useMutation } from '@tanstack/react-query';
import { ArrowRight } from 'lucide-react';
import { api } from '@/services/api';
import Dialog from '@/components/ui/Dialog';
import Button from '@/components/ui/Button';
import Notice from '@/components/ui/Notice';
import Segmented from '@/components/ui/Segmented';
import Fact, { FactList } from '@/components/Fact';
import { CheckboxField, SelectField, TextField } from '@/components/ui/Field';
import fieldStyles from '@/components/ui/Field.module.css';
import type { Pending } from '@/hooks/useApplyChange';
import {
  BAND_NAMES, SECURITY_LABELS, channelFits, channelText, radioName,
  type ApSecurity, type Radio, type RadioInterface, type RadiosStatus,
} from './model';
import styles from './Radios.module.css';

/**
 * The radios page's dialogs: a radio's settings, an access point, the
 * one-step repeater and an uplink on another radio. Each posts its change and hands
 * the answer's rollback window to the page (onApplied), which confirms it once
 * the browser reaches the gateway again; see useApplyChange.
 */

type Applied = { pending?: Pending | null };

function usePost(onApplied: (pending?: Pending | null) => void, onDone: () => void) {
  return useMutation({
    mutationFn: ({ path, body }: { path: string; body: unknown }) => api.post<Applied>(path, body),
    onSuccess: (answer) => {
      onApplied(answer.pending);
      onDone();
    },
  });
}

function Labelled({ label, children }: { label: string; children: ReactNode }) {
  return (
    <div className={fieldStyles.field}>
      <span className={fieldStyles.label}>{label}</span>
      {children}
    </div>
  );
}

// ── a radio ─────────────────────────────────────────────────────────────────

/** Every region Intl has a name for, by its ISO code, and the world domain. */
function countries(): { value: string; label: string }[] {
  const names = new Intl.DisplayNames(['en'], { type: 'region' });
  const out: { value: string; label: string }[] = [];
  const A = 'A'.charCodeAt(0);
  for (let i = 0; i < 26; i++) {
    for (let j = 0; j < 26; j++) {
      const code = String.fromCharCode(A + i, A + j);
      let name: string | undefined;
      try { name = names.of(code); } catch { name = undefined; }
      if (name && name !== code) out.push({ value: code, label: `${name} (${code})` });
    }
  }
  out.sort((a, b) => a.label.localeCompare(b.label));
  return [{ value: '00', label: 'World (00)' }, ...out];
}

export function RadioDialog({
  status,
  radio,
  onClose,
  onApplied,
}: {
  status: RadiosStatus;
  radio: Radio | null;
  onClose: () => void;
  onApplied: (pending?: Pending | null) => void;
}) {
  const [enabled, setEnabled] = useState(true);
  const [channel, setChannel] = useState<string>('auto');
  const [width, setWidth] = useState(20);
  const [power, setPower] = useState<string>('max');
  const [country, setCountry] = useState('00');
  const post = usePost(onApplied, onClose);
  const countryList = useMemo(countries, []);

  useEffect(() => {
    if (!radio) return;
    setEnabled(radio.enabled);
    setChannel(radio.channel.configured === 'auto' ? 'auto' : String(radio.channel.configured));
    setWidth(radio.width.configured);
    setPower(radio.txpower.configured == null ? 'max' : String(radio.txpower.configured));
    setCountry(radio.country ?? status.country ?? '00');
    post.reset();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [radio?.id]);

  if (!radio) return <Dialog open={false} onClose={onClose} title=""><span /></Dialog>;

  const widths = radio.capabilities.widths.length ? radio.capabilities.widths : [20];
  const chooseWidth = (w: number) => {
    setWidth(w);
    // A channel that cannot carry the new width goes back to automatic rather
    // than leaving a choice the gateway will refuse.
    if (channel !== 'auto' && !channelFits(radio, Number(channel), w)) setChannel('auto');
  };
  const max = radio.txpower.max ?? 20;
  const powers = [{ value: 'max', label: `Maximum (${max} dBm)` }];
  for (let p = max - 1; p >= 1; p--) powers.push({ value: String(p), label: `${p} dBm` });

  const channels = [
    { value: 'auto', label: 'Automatic' },
    ...radio.capabilities.channels.map((c) => ({
      value: String(c.channel),
      label: `${c.channel} (${c.mhz} MHz${c.dfs ? ', DFS' : ''})`,
      disabled: !channelFits(radio, c.channel, width),
    })),
  ];

  const body = {
    radio: radio.id,
    enabled,
    width,
    txpower: power === 'max' ? 'max' : Number(power),
    ...(radio.sharedChannel ? {} : { channel: channel === 'auto' ? 'auto' : Number(channel) }),
    ...(country !== (radio.country ?? status.country ?? '00') ? { country } : {}),
  };

  return (
    <Dialog
      open
      size="compact"
      onClose={onClose}
      title={`${radioName(status.radios, radio.id)}, ${BAND_NAMES[radio.band]}`}
      footer={
        <>
          <Button variant="quiet" onClick={onClose}>Cancel</Button>
          <Button variant="primary" loading={post.isPending} onClick={() => post.mutate({ path: '/radios/radio', body })}>
            Apply
          </Button>
        </>
      }
    >
      <div className={styles.form}>
        <CheckboxField label="Radio on" checked={enabled} onChange={(e) => setEnabled(e.target.checked)} />
        {radio.sharedChannel ? (
          <SelectField
            label="Channel"
            value="shared"
            onChange={() => undefined}
            disabled
            options={[{ value: 'shared', label: `Follows the uplink, now ${channelText(radio)}` }]}
          />
        ) : (
          <SelectField label="Channel" value={channel} onChange={setChannel} options={channels} />
        )}
        {widths.length > 1 && (
          <Labelled label="Width">
            <Segmented
              aria-label="Channel width"
              value={width}
              onChange={chooseWidth}
              options={widths.map((w) => ({ value: w, label: `${w} MHz` }))}
            />
          </Labelled>
        )}
        <SelectField label="Transmit power" value={power} onChange={setPower} options={powers} />
        <SelectField label="Country, every radio" value={country} onChange={setCountry} options={countryList} />
        {post.isError && <Notice tone="error">{(post.error as Error).message}</Notice>}
      </div>
    </Dialog>
  );
}

// ── an access point ─────────────────────────────────────────────────────────

export interface ApDraft {
  ssid: string;
  security: ApSecurity;
  key: string;
  network: string;
  hidden: boolean;
  isolate: boolean;
  enabled: boolean;
  allowOpen: boolean;
}

export function draftFor(status: RadiosStatus, iface?: RadioInterface | null): ApDraft {
  return {
    ssid: iface?.ssid ?? '',
    security: (iface && iface.security in SECURITY_LABELS ? iface.security : status.sae ? 'sae-mixed' : 'psk2') as ApSecurity,
    key: '',
    network: iface?.networks[0]?.id ?? status.networks[0]?.id ?? '',
    hidden: iface?.hidden ?? false,
    isolate: iface?.isolate ?? false,
    enabled: iface?.enabled ?? true,
    allowOpen: iface?.security === 'none',
  };
}

/** What is wrong with a draft before it is sent, or null. */
export function draftProblem(draft: ApDraft, editing: boolean): string | null {
  if (!draft.ssid.trim()) return 'Name the network.';
  if (new TextEncoder().encode(draft.ssid).length > 32) return 'A network name is at most 32 bytes.';
  if (draft.security === 'none') return draft.allowOpen ? null : 'Confirm the network is open to anybody.';
  if (!draft.key && editing) return null;
  if (draft.key.length < 8 || draft.key.length > 63) return 'A passphrase is 8 to 63 characters.';
  return null;
}

export function bodyOf(draft: ApDraft) {
  return {
    ssid: draft.ssid,
    security: draft.security,
    key: draft.security === 'none' ? undefined : draft.key || undefined,
    network: draft.network,
    hidden: draft.hidden,
    isolate: draft.isolate,
    enabled: draft.enabled,
    allowOpen: draft.security === 'none' ? draft.allowOpen : undefined,
  };
}

function ApFields({
  status,
  draft,
  set,
  editing,
}: {
  status: RadiosStatus;
  draft: ApDraft;
  set: (next: Partial<ApDraft>) => void;
  editing: boolean;
}) {
  const securities = (Object.keys(SECURITY_LABELS) as ApSecurity[])
    .filter((s) => status.sae || (s !== 'sae' && s !== 'sae-mixed'))
    .map((s) => ({ value: s, label: SECURITY_LABELS[s] }));
  return (
    <>
      <TextField label="Network name" value={draft.ssid} maxLength={32} autoComplete="off"
        onChange={(e) => set({ ssid: e.target.value })} />
      <Labelled label="Security">
        <Segmented aria-label="Security" value={draft.security} options={securities}
          onChange={(security) => set({ security })} />
      </Labelled>
      {draft.security === 'none' ? (
        <CheckboxField label="Anybody nearby can join it and reach the LAN" checked={draft.allowOpen}
          onChange={(e) => set({ allowOpen: e.target.checked })} />
      ) : (
        <TextField label="Passphrase" type="password" autoComplete="new-password" value={draft.key}
          placeholder={editing ? 'Unchanged' : ''} maxLength={63}
          onChange={(e) => set({ key: e.target.value })} />
      )}
      {status.networks.length > 1 && (
        <SelectField label="Network" value={draft.network} onChange={(network) => set({ network })}
          options={status.networks.map((n) => ({ value: n.id, label: n.label }))} />
      )}
      <div className={styles.checks}>
        <CheckboxField label="Hidden" checked={draft.hidden} onChange={(e) => set({ hidden: e.target.checked })} />
        <CheckboxField label="Keep clients apart" checked={draft.isolate}
          onChange={(e) => set({ isolate: e.target.checked })} />
        {editing && (
          <CheckboxField label="On" checked={draft.enabled} onChange={(e) => set({ enabled: e.target.checked })} />
        )}
      </div>
    </>
  );
}

export function ApDialog({
  status,
  target,
  onClose,
  onApplied,
}: {
  status: RadiosStatus;
  /** The AP being edited, or the radio a new one goes on (null: choose). */
  target: { iface?: RadioInterface; radio?: Radio } | null;
  onClose: () => void;
  onApplied: (pending?: Pending | null) => void;
}) {
  const editing = target?.iface ?? null;
  const [draft, setDraft] = useState<ApDraft>(() => draftFor(status));
  const choices = status.radios.filter((r) => r.capabilities.room.ap && r.present);
  const [radio, setRadio] = useState('');
  const post = usePost(onApplied, onClose);

  useEffect(() => {
    if (!target) return;
    setDraft(draftFor(status, target.iface));
    setRadio(target.radio?.id ?? choices[0]?.id ?? '');
    post.reset();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [target]);

  const problem = draftProblem(draft, !!editing);
  const title = editing ? `Edit ${editing.ssid ?? 'Access Point'}` : 'Add Access Point';

  return (
    <Dialog
      open={!!target}
      size="compact"
      onClose={onClose}
      title={title}
      footer={
        <>
          <Button variant="quiet" onClick={onClose}>Cancel</Button>
          <Button
            variant="primary"
            disabled={!!problem || (!editing && !radio)}
            loading={post.isPending}
            onClick={() => post.mutate({
              path: '/radios/ap',
              body: { ...bodyOf(draft), ...(editing ? { id: editing.id } : { radio }) },
            })}
          >
            {editing ? 'Save' : 'Add'}
          </Button>
        </>
      }
    >
      {target && (
        <div className={styles.form}>
          {!editing && !target.radio && (
            <SelectField label="Radio" value={radio} onChange={setRadio}
              options={choices.map((r) => ({ value: r.id, label: `${radioName(status.radios, r.id)}, ${BAND_NAMES[r.band]}` }))} />
          )}
          <ApFields status={status} draft={draft} set={(next) => setDraft({ ...draft, ...next })} editing={!!editing} />
          {post.isError && <Notice tone="error">{(post.error as Error).message}</Notice>}
        </div>
      )}
    </Dialog>
  );
}

export function RemoveApDialog({
  status,
  iface,
  onClose,
  onApplied,
}: {
  status: RadiosStatus;
  iface: RadioInterface | null;
  onClose: () => void;
  onApplied: (pending?: Pending | null) => void;
}) {
  const post = usePost(onApplied, onClose);
  useEffect(() => { post.reset(); /* eslint-disable-next-line react-hooks/exhaustive-deps */ }, [iface?.id]);
  const clients = iface?.clients?.length ?? 0;
  return (
    <Dialog
      open={!!iface}
      size="compact"
      onClose={onClose}
      title={`Remove ${iface?.ssid ?? 'Access Point'}`}
      footer={
        <>
          <Button variant="quiet" onClick={onClose}>Cancel</Button>
          <Button variant="danger" loading={post.isPending}
            onClick={() => post.mutate({ path: '/radios/ap/remove', body: { id: iface!.id } })}>
            Remove
          </Button>
        </>
      }
    >
      {iface && (
        <FactList>
          <Fact label="Network" value={iface.networks.map((n) => n.label).join(', ')} />
          <Fact label="Connected now" value={`${clients}`} />
          {status.radios.length > 1 && (
            <Fact label="Radio" value={radioName(status.radios,
              status.radios.find((r) => r.interfaces.some((i) => i.id === iface.id))?.id ?? '')} />
          )}
        </FactList>
      )}
      {post.isError && <Notice tone="error">{(post.error as Error).message}</Notice>}
    </Dialog>
  );
}

// ── the uplink's radio ──────────────────────────────────────────────────────

/**
 * The uplink onto a radio that has none, while another radio's carries it:
 * the network the uplink is on now, rejoined here, or another one through the
 * join wizard (onChooseNetwork). The radio carrying it now keeps carrying it
 * until this one is online, then stays as the fallback (lib/radios.uc).
 */
export function UplinkDialog({
  status,
  radio,
  ssid,
  onClose,
  onApplied,
  onChooseNetwork,
}: {
  status: RadiosStatus;
  radio: Radio | null;
  ssid: string | null;
  onClose: () => void;
  onApplied: (pending?: Pending | null) => void;
  onChooseNetwork: (radio: Radio) => void;
}) {
  const post = usePost(onApplied, onClose);
  const [network, setNetwork] = useState<'keep' | 'new'>('keep');
  useEffect(() => {
    post.reset();
    setNetwork(ssid ? 'keep' : 'new');
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [radio?.id]);
  const carrying = status.uplinks.find((u) => u.radio !== radio?.id);
  const from = status.radios.find((r) => r.id === carrying?.radio);
  const name = (r?: Radio) => (r ? `${radioName(status.radios, r.id)}, ${BAND_NAMES[r.band]}` : '');
  const keep = network === 'keep' && !!ssid;
  return (
    <Dialog
      open={!!radio}
      size="compact"
      onClose={onClose}
      title={`Uplink on ${radio ? radioName(status.radios, radio.id) : ''}`}
      footer={
        <>
          <Button variant="quiet" onClick={onClose}>Cancel</Button>
          <Button variant="primary" loading={post.isPending}
            onClick={() => (keep
              ? post.mutate({ path: '/radios/uplink', body: { radio: radio!.id, ssid, saved: true } })
              : onChooseNetwork(radio!))}>
            {keep ? 'Join' : 'Choose Network'}
          </Button>
        </>
      }
    >
      {radio && (
        <div className={styles.form}>
          {ssid && (
            <Labelled label="Network">
              <Segmented
                aria-label="Network"
                value={network}
                onChange={setNetwork}
                options={[{ value: 'keep', label: ssid }, { value: 'new', label: 'Another network' }]}
              />
            </Labelled>
          )}
          <FactList>
            <Fact label="Radio" value={name(radio)} />
            {from && <Fact label="Fallback" value={name(from)} />}
          </FactList>
        </div>
      )}
      {post.isError && <Notice tone="error">{(post.error as Error).message}</Notice>}
    </Dialog>
  );
}

/** The second WiFi uplink off its radio. The WiFi page's own is forgotten
    there. */
export function RemoveUplinkDialog({
  status,
  iface,
  onClose,
  onApplied,
}: {
  status: RadiosStatus;
  iface: RadioInterface | null;
  onClose: () => void;
  onApplied: (pending?: Pending | null) => void;
}) {
  const post = usePost(onApplied, onClose);
  useEffect(() => { post.reset(); /* eslint-disable-next-line react-hooks/exhaustive-deps */ }, [iface?.id]);
  const radio = status.radios.find((r) => r.interfaces.some((i) => i.id === iface?.id));
  return (
    <Dialog
      open={!!iface}
      size="compact"
      onClose={onClose}
      title={`Remove ${iface?.ssid ?? 'Uplink'}`}
      footer={
        <>
          <Button variant="quiet" onClick={onClose}>Cancel</Button>
          <Button variant="danger" loading={post.isPending}
            onClick={() => post.mutate({ path: '/radios/uplink/remove', body: { radio: radio!.id } })}>
            Remove
          </Button>
        </>
      }
    >
      {radio && (
        <FactList>
          <Fact label="Radio" value={`${radioName(status.radios, radio.id)}, ${BAND_NAMES[radio.band]}`} />
        </FactList>
      )}
      {post.isError && <Notice tone="error">{(post.error as Error).message}</Notice>}
    </Dialog>
  );
}

// ── the repeater ────────────────────────────────────────────────────────────

export interface RepeaterPlan {
  uplinkRadio: string;
  ap: Record<string, unknown>;
}

/**
 * One radio joins the site's network, another (or the same one, where the
 * hardware takes both) serves the gateway's own, as one change. The upstream
 * network is the current uplink's, rejoined there, or a new one through the
 * join wizard (onChooseNetwork), which sends the access point with the join.
 */
export function RepeaterDialog({
  status,
  open,
  current,
  onClose,
  onApplied,
  onChooseNetwork,
  onRejoined,
}: {
  status: RadiosStatus;
  open: boolean;
  /** The network the uplink is on now, if it is on one. */
  current: string | null;
  onClose: () => void;
  onApplied: (pending?: Pending | null) => void;
  onChooseNetwork: (plan: RepeaterPlan) => void;
  onRejoined: (ssid: string) => void;
}) {
  const usable = status.radios.filter((r) => r.present);
  const pick = () => {
    const up = usable.find((r) => r.id === status.uplink) ?? usable[0];
    const ap = usable.find((r) => r.id !== up?.id) ?? up;
    return { up: up?.id ?? '', ap: ap?.id ?? '' };
  };
  const [uplinkRadio, setUplinkRadio] = useState('');
  const [apRadio, setApRadio] = useState('');
  const [draft, setDraft] = useState<ApDraft>(() => draftFor(status));
  const [upstream, setUpstream] = useState<'keep' | 'new'>('keep');
  const post = usePost(onApplied, () => undefined);

  useEffect(() => {
    if (!open) return;
    const p = pick();
    setUplinkRadio(p.up);
    setApRadio(p.ap);
    setDraft({ ...draftFor(status), ssid: current ? `${current} Extended`.slice(0, 32) : '' });
    setUpstream(current ? 'keep' : 'new');
    post.reset();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [open]);

  const options = usable.map((r) => ({ value: r.id, label: `${radioName(status.radios, r.id)}, ${BAND_NAMES[r.band]}` }));
  const up = status.radios.find((r) => r.id === uplinkRadio);
  const ap = status.radios.find((r) => r.id === apRadio);
  const problem = draftProblem(draft, false);
  const plan: RepeaterPlan = { uplinkRadio, ap: { ...bodyOf(draft), radio: apRadio } };

  const go = () => {
    if (upstream === 'new' || !current) {
      onChooseNetwork(plan);
      return;
    }
    post.mutate(
      { path: '/radios/uplink', body: { radio: uplinkRadio, ssid: current, saved: true, ap: plan.ap } },
      { onSuccess: () => onRejoined(current) },
    );
  };

  return (
    <Dialog
      open={open}
      size="compact"
      onClose={onClose}
      title="Set Up Repeater"
      footer={
        <>
          <Button variant="quiet" onClick={onClose}>Cancel</Button>
          <Button variant="primary" disabled={!!problem || !uplinkRadio || !apRadio} loading={post.isPending} onClick={go}>
            {upstream === 'new' || !current ? 'Choose Network' : 'Apply'}
          </Button>
        </>
      }
    >
      <div className={styles.form}>
        <div className={styles.preview} aria-hidden>
          <span className={styles.previewNode}>{upstream === 'keep' && current ? current : 'Site WiFi'}</span>
          <PreviewHop radio={up} radios={status.radios} />
          <span className={`${styles.previewNode} ${styles.previewGateway}`}>{status.hostname ?? 'Gateway'}</span>
          <PreviewHop radio={ap} radios={status.radios} />
          <span className={styles.previewNode}>{draft.ssid.trim() || 'New network'}</span>
        </div>
        <div className={styles.pair}>
          <SelectField label="Uplink radio" value={uplinkRadio} onChange={setUplinkRadio} options={options} />
          <SelectField label="Access point radio" value={apRadio} onChange={setApRadio} options={options} />
        </div>
        {current && (
          <Labelled label="Upstream network">
            <Segmented
              aria-label="Upstream network"
              value={upstream}
              onChange={setUpstream}
              options={[{ value: 'keep', label: current }, { value: 'new', label: 'Another network' }]}
            />
          </Labelled>
        )}
        <ApFields status={status} draft={draft} set={(next) => setDraft({ ...draft, ...next })} editing={false} />
        {post.isError && <Notice tone="error">{(post.error as Error).message}</Notice>}
      </div>
    </Dialog>
  );
}

function PreviewHop({ radio, radios }: { radio?: Radio; radios: Radio[] }) {
  return (
    <span className={styles.previewHop} style={radio ? ({ '--band': `var(--band-${radio.band})` } as React.CSSProperties) : undefined}>
      <span className={styles.previewBand}>{radio ? BAND_NAMES[radio.band] : ''}</span>
      <ArrowRight size={14} strokeWidth={2} />
      <span className={styles.previewRadio}>{radio ? radioName(radios, radio.id) : ''}</span>
    </span>
  );
}
