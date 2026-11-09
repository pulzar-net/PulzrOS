import { useMemo, useState } from 'react';
import { Globe, RefreshCw, ShieldAlert, Tags } from 'lucide-react';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { createColumnHelper, getCoreRowModel, useReactTable } from '@tanstack/react-table';
import { api } from '@/services/api';
import type { DdnsStatus, DnsStatus } from '@/types';
import Section from '@/components/ui/Section';
import Button from '@/components/ui/Button';
import Dialog from '@/components/ui/Dialog';
import Notice from '@/components/ui/Notice';
import Segmented from '@/components/ui/Segmented';
import { SelectField, TextField } from '@/components/ui/Field';
import Fact, { FactList } from '@/components/Fact';
import DataTable from '@/components/DataTable';
import Spinner from '@/components/ui/Spinner';
import ErrorState from '@/components/ErrorState';
import { duration, uplinkName } from '@/lib/format';
import styles from '../Pages.module.css';

/**
 * The resolver the gateway and its LAN use (parkeze-dns): upstream servers,
 * local names, rebind protection. Each section applies on its own, as
 * GL.iNet's cards do.
 *
 * parkeze-dns refuses a name under a Parkeze domain and a server list that
 * cannot resolve Parkeze; its message is shown as it comes. Everything here is
 * in UCI dhcp, which is what parkeze.net's `dns` op reads.
 *
 * Dynamic DNS is the customer's own name in their own Cloudflare zone, for
 * ports exposed on the LAN page. The token is write-only here: the gateway
 * says whether one is set and never what it is.
 */

type Host = DnsStatus['hosts'][number];

const UPSTREAM = [
  { value: 'auto', label: 'Automatic' },
  { value: 'custom', label: 'Custom' },
] as const;

const SWITCH = [
  { value: 'on', label: 'On' },
  { value: 'off', label: 'Off' },
] as const;

const list = (text: string) => text.split(/[\s,]+/).map((s) => s.trim()).filter(Boolean);

const column = createColumnHelper<Host>();

export default function Dns() {
  const queryClient = useQueryClient();
  const dns = useQuery({
    queryKey: ['dns'],
    queryFn: () => api.get<DnsStatus>('/dns/status'),
  });
  const refresh = () => queryClient.invalidateQueries({ queryKey: ['dns'] });

  if (dns.isLoading) return <Spinner label="Reading DNS" />;
  if (dns.isError) return <ErrorState error={dns.error} onRetry={dns.refetch} />;

  const state = dns.data!;
  return (
    <div className="fade-in">
      <Upstream state={state} onApplied={refresh} />
      <Names hosts={state.hosts} onChanged={refresh} />
      <Rebind state={state} onApplied={refresh} />
      {state.ddns && <Ddns ddns={state.ddns} onApplied={refresh} />}
    </div>
  );
}

function Upstream({ state, onApplied }: { state: DnsStatus; onApplied: () => void }) {
  const [mode, setMode] = useState<'auto' | 'custom'>(state.upstream.mode);
  const [servers, setServers] = useState(
    state.upstream.mode === 'custom' ? state.upstream.servers.join(', ') : '',
  );

  const apply = useMutation({
    mutationFn: () =>
      api.post('/dns/upstream', { servers: mode === 'auto' ? [] : list(servers) }),
    onSuccess: onApplied,
  });

  return (
    <Section title="Upstream" icon={Globe}>
      <Segmented aria-label="Upstream servers" value={mode} options={[...UPSTREAM]} onChange={setMode} />

      {mode === 'auto' ? (
        state.upstream.mode === 'auto' && (
          <FactList>
            <Fact
              label="From the uplinks"
              value={state.upstream.servers.length ? state.upstream.servers.join(', ') : null}
              mono
            />
          </FactList>
        )
      ) : (
        <div className={styles.form}>
          <TextField label="Servers" mono value={servers} placeholder="1.1.1.1, 9.9.9.9"
                     onChange={(event) => setServers(event.target.value)} />
        </div>
      )}

      {apply.isError && <Notice tone="error">{(apply.error as Error).message}</Notice>}
      {apply.isSuccess && <Notice tone="success">Applied.</Notice>}

      <div className={styles.actions}>
        <Button variant="primary" loading={apply.isPending} onClick={() => apply.mutate()}>
          Apply
        </Button>
      </div>
    </Section>
  );
}

function Names({ hosts, onChanged }: { hosts: Host[]; onChanged: () => void }) {
  const [editing, setEditing] = useState<Host | 'new' | null>(null);

  const columns = useMemo(
    () => [
      column.accessor('name', {
        header: 'Name',
        cell: (info) => <span className="mono">{info.getValue()}</span>,
      }),
      column.accessor('ip', {
        header: 'Address',
        size: 140,
        cell: (info) => <span className="mono">{info.getValue()}</span>,
      }),
      column.display({
        id: 'edit',
        header: '',
        size: 72,
        cell: (info) => <Button onClick={() => setEditing(info.row.original)}>Edit</Button>,
      }),
    ],
    [],
  );

  const table = useReactTable({
    data: hosts,
    columns,
    getRowId: (row) => row.name,
    getCoreRowModel: getCoreRowModel(),
  });

  return (
    <Section
      title="Local Names"
      icon={Tags}
      wide
      note={hosts.length ? String(hosts.length) : undefined}
      actions={<Button onClick={() => setEditing('new')}>Add</Button>}
    >
      {hosts.length > 0 ? (
        <DataTable table={table} fill="name" />
      ) : (
        <FactList>
          <Fact label="Names" value="None" />
        </FactList>
      )}
      {editing && (
        <NameDialog
          host={editing === 'new' ? null : editing}
          onClose={() => setEditing(null)}
          onChanged={onChanged}
        />
      )}
    </Section>
  );
}

function NameDialog({
  host,
  onClose,
  onChanged,
}: {
  host: Host | null;
  onClose: () => void;
  onChanged: () => void;
}) {
  const [name, setName] = useState(host?.name ?? '');
  const [ip, setIp] = useState(host?.ip ?? '');

  const save = useMutation({
    mutationFn: async (body: { name: string; ip: string | null }) => {
      // A renamed entry is a new name and the old one removed, in that
      // order, so a refused new name leaves the old one in place.
      await api.post('/dns/host', body);
      if (host && body.ip && body.name !== host.name) {
        await api.post('/dns/host', { name: host.name, ip: null });
      }
    },
    onSuccess: () => {
      onChanged();
      onClose();
    },
  });

  return (
    <Dialog
      open
      size="compact"
      onClose={onClose}
      title={host ? host.name : 'Local name'}
      footer={
        <div className={styles.row}>
          {host && (
            <Button
              variant="danger"
              loading={save.isPending}
              onClick={() => save.mutate({ name: host.name, ip: null })}
            >
              Remove
            </Button>
          )}
          <Button
            variant="primary"
            loading={save.isPending}
            disabled={!name.trim() || !ip.trim()}
            onClick={() => save.mutate({ name: name.trim(), ip: ip.trim() })}
          >
            Save
          </Button>
        </div>
      }
    >
      {save.isError && <Notice tone="error">{(save.error as Error).message}</Notice>}
      <TextField label="Name" mono value={name} placeholder="nas" onChange={(e) => setName(e.target.value)} />
      <TextField label="Address" mono value={ip} placeholder="192.168.70.20" onChange={(e) => setIp(e.target.value)} />
    </Dialog>
  );
}

function Rebind({ state, onApplied }: { state: DnsStatus; onApplied: () => void }) {
  const [on, setOn] = useState<'on' | 'off'>(state.rebind.protection ? 'on' : 'off');
  const [allowed, setAllowed] = useState(state.rebind.allowed.join(', '));

  const apply = useMutation({
    mutationFn: () =>
      api.post('/dns/rebind', { protection: on === 'on', allowed: on === 'on' ? list(allowed) : [] }),
    onSuccess: onApplied,
  });

  return (
    <Section title="Rebind Protection" icon={ShieldAlert}>
      <Segmented aria-label="Rebind protection" value={on} options={[...SWITCH]} onChange={setOn} />

      {on === 'on' && (
        <div className={styles.form}>
          <TextField label="Allowed domains" mono value={allowed} placeholder="corp.local"
                     onChange={(event) => setAllowed(event.target.value)} />
        </div>
      )}

      {apply.isError && <Notice tone="error">{(apply.error as Error).message}</Notice>}
      {apply.isSuccess && <Notice tone="success">Applied.</Notice>}

      <div className={styles.actions}>
        <Button variant="primary" loading={apply.isPending} onClick={() => apply.mutate()}>
          Apply
        </Button>
      </div>
    </Section>
  );
}

function Ddns({ ddns, onApplied }: { ddns: DdnsStatus; onApplied: () => void }) {
  const [on, setOn] = useState<'on' | 'off'>(ddns.enabled ? 'on' : 'off');
  const [name, setName] = useState(ddns.name ?? '');
  const [zone, setZone] = useState(ddns.zone ?? '');
  const [uplink, setUplink] = useState(ddns.uplink ?? ddns.uplinks[0] ?? '');
  const [token, setToken] = useState('');

  const apply = useMutation({
    mutationFn: () =>
      api.post('/dns/ddns', on === 'off'
        ? { enabled: false }
        : { name: name.trim(), zone: zone.trim(), uplink, token: token.trim() || undefined }),
    onSuccess: () => { setToken(''); onApplied(); },
  });

  return (
    <Section title="Dynamic DNS" icon={RefreshCw}>
      {ddns.enabled && ddns.error && <Notice tone="error">{ddns.error}</Notice>}
      {ddns.enabled && (
        <FactList>
          <Fact label="Address" value={ddns.address ?? 'Not registered'} mono />
          <Fact label="Updated"
                value={ddns.updated ? `${duration(Math.floor(Date.now() / 1000) - ddns.updated)} ago` : '—'} />
        </FactList>
      )}

      <div className={styles.options}>
        <Segmented aria-label="Dynamic DNS" value={on} options={[...SWITCH]} onChange={setOn} />
      </div>

      {on === 'on' && (
        <div className={styles.form}>
          <TextField label="Name" mono value={name} placeholder="cameras.example.com"
                     onChange={(event) => setName(event.target.value)} />
          <TextField label="Zone" mono value={zone} placeholder="example.com"
                     onChange={(event) => setZone(event.target.value)} />
          <SelectField label="Uplink" value={uplink} onChange={setUplink}
                       options={ddns.uplinks.map((u) => ({ value: u, label: uplinkName(u) }))} />
          <TextField label="Cloudflare API token" mono type="password" autoComplete="off" value={token}
                     placeholder={ddns.tokenSet ? 'Set' : ''}
                     onChange={(event) => setToken(event.target.value)} />
        </div>
      )}

      {apply.isError && <Notice tone="error">{(apply.error as Error).message}</Notice>}
      {apply.isSuccess && <Notice tone="success">Applied.</Notice>}

      <div className={styles.actions}>
        <Button
          variant="primary"
          loading={apply.isPending}
          disabled={on === 'on' && (!name.trim() || !zone.trim() || !uplink || (!ddns.tokenSet && !token.trim()))}
          onClick={() => apply.mutate()}
        >
          Apply
        </Button>
      </div>
    </Section>
  );
}
