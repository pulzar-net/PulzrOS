import { useEffect, useState } from 'react';
import { useSearchParams } from 'react-router-dom';
import { useQuery } from '@tanstack/react-query';
import { Network as NetworkIcon } from 'lucide-react';
import { api } from '@/services/api';
import type { PortsStatus, UplinksStatus } from '@/types';
import type { RadiosStatus } from '@/pages/radios/model';
import WifiSettings from '@/pages/radios/Radios';
import Section from '@/components/ui/Section';
import Button from '@/components/ui/Button';
import Notice from '@/components/ui/Notice';
import Spinner from '@/components/ui/Spinner';
import ErrorState from '@/components/ErrorState';
import ApplyChangeNotice from '@/components/ApplyChangeNotice';
import { useApplyChange } from '@/hooks/useApplyChange';
import { useFeatures } from '@/hooks/useFeatures';
import { countdown } from '@/lib/format';
import Clients, { useLanStatus } from './Lan';
import { PortEditor, same, toDraft, type Draft } from './Ports';
import SetupAccessPoint from './SetupAccessPoint';
import Topology from './Topology';
import styles from './Ports.module.css';

/**
 * The gateway's network on one page (Ports, LAN and WiFi were three until
 * 27 Nov 2026): the diagram of its ports and radios, every client and where
 * it is connected, and the WiFi uplink and radios. A port or a radio in the
 * diagram opens its settings.
 *
 * One apply-with-undo for the page (useApplyChange): the gateway holds one
 * pending change at a time, so one banner says where it stands whichever
 * card made it. The port layout is a draft until Apply, and applied whole.
 */
export default function Network() {
  const features = useFeatures();
  const change = useApplyChange();
  const ports = useQuery({
    queryKey: ['ports'],
    queryFn: () => api.get<PortsStatus>('/ports/status'),
    refetchInterval: 10_000,
  });
  const lan = useLanStatus(features.has('lan'));
  const radios = useQuery({
    queryKey: ['radios'],
    queryFn: () => api.get<RadiosStatus>('/radios'),
    refetchInterval: 15_000,
    enabled: features.has('wifi'),
  });
  const uplinks = useQuery({
    queryKey: ['uplinks'],
    queryFn: () => api.get<UplinksStatus>('/uplinks/status'),
    refetchInterval: 15_000,
  });

  const [draft, setDraft] = useState<Draft | null>(null);
  const [dirty, setDirty] = useState(false);
  // ?port= and ?radio= open that one: old links to Ports and WiFi land here.
  const [params] = useSearchParams();
  const [editing, setEditing] = useState<string | null>(params.get('port'));
  const [radio, setRadio] = useState<string | null>(params.get('radio'));

  // The page's copy follows the gateway until somebody edits it.
  useEffect(() => {
    if (ports.data && !dirty) setDraft(toDraft(ports.data));
  }, [ports.data, dirty]);

  if (ports.isLoading || !draft) return <Spinner label="Reading the ports" />;
  if (ports.isError) return <ErrorState error={ports.error} onRetry={ports.refetch} />;

  const state = ports.data!;
  const before = toDraft(state);
  const edited = draft.filter((d) => !same(d, before.find((b) => b.name === d.name)!)).length;
  const busy = change.applying || change.phase === 'confirming';
  const foreign = state.pending && change.phase !== 'confirming' ? state.pending : null;
  const editPort = editing ? state.ports.find((p) => p.name === editing) : null;
  const clients = lan.data?.clients ?? [];

  return (
    <div className="fade-in">
      <ApplyChangeNotice change={change} />
      {foreign && (
        <Notice tone="warning">
          {foreign.what ?? 'A change'}{foreign.by ? ` (by ${foreign.by})` : ''} is undone in {countdown(foreign.in)} unless it is kept.{' '}
          <Button onClick={() => api.post('/ports/confirm').then(() => ports.refetch())}>Keep</Button>{' '}
          <Button onClick={change.undo}>Undo</Button>
        </Notice>
      )}

      <Section title="Ports and Radios" icon={NetworkIcon} wide>
        <Topology
          ports={state.ports}
          roleOf={(port) => draft.find((p) => p.name === port.name)!.role}
          radios={radios.data}
          uplinks={uplinks.data}
          clients={clients}
          hostname={radios.data?.hostname ?? null}
          lanAddress={lan.data?.address ? [lan.data.address, ...(lan.data.addresses ?? [])].join(', ')
            : state.consoleAddress}
          onPort={setEditing}
          onRadio={setRadio}
        />
        {edited > 0 && (
          <div className={styles.bar}>
            <span className={styles.summary}>{edited === 1 ? '1 port changed' : `${edited} ports changed`}</span>
            <Button disabled={busy} onClick={() => { setDirty(false); setDraft(before); }}>Discard</Button>
            <Button
              variant="primary"
              disabled={busy}
              loading={change.applying}
              onClick={async () => {
                await change.apply('/ports', { ports: draft });
                setDirty(false);
              }}
            >
              Apply
            </Button>
          </div>
        )}
      </Section>

      {(features.has('lan') || features.has('wifi')) && <Clients lan={features.has('lan')} radios={radios.data} />}

      {features.has('wifi') && <WifiSettings change={change} radio={radio} onRadio={setRadio} />}
      {features.has('wifi') && <SetupAccessPoint />}

      {editPort && (
        <PortEditor
          port={editPort}
          clients={clients.filter((c) => c.online && (c.port === editPort.name || c.port?.startsWith(`${editPort.name}.`)))}
          consoleAddress={state.console === editPort.name ? state.consoleAddress : null}
          draft={draft.find((p) => p.name === editPort.name)!}
          devices={state.devices}
          disabled={busy}
          onClose={() => setEditing(null)}
          onChange={(next) => {
            setDraft(draft.map((p) => (p.name === editPort.name ? next(p) : p)));
            setDirty(true);
            if (change.phase !== 'confirming') change.reset();
          }}
        />
      )}
    </div>
  );
}
