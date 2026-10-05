import { useEffect, useRef, useState } from 'react';
import { useMutation, useQuery } from '@tanstack/react-query';
import { LogIn, ShieldCheck } from 'lucide-react';
import { api } from '@/services/api';
import { useSession } from '@/contexts/SessionContext';
import type { LoginMethods, Session } from '@/types';
import Button from '@/components/ui/Button';
import Notice from '@/components/ui/Notice';
import Spinner from '@/components/ui/Spinner';
import { TextField } from '@/components/ui/Field';
import Recovery from './Recovery';
import Brand from '@/components/Brand';
import styles from './Login.module.css';

/**
 * The way in.
 *
 * What this screen offers depends on the gateway's adoption state, and the
 * gateway decides — not this component. An unadopted gateway offers a local
 * password because that is the only thing that could work; an adopted one
 * offers recovery, because the credential a thief could pull out of its flash
 * must not be a way in. See ParkezeOS docs/auth.md.
 *
 * Note that the *reason* text comes from the API too. It changes with adoption
 * state and there is no version of it that belongs in the frontend.
 */
/**
 * A handoff token in the fragment.
 *
 * parkeze.net returns the browser here with `#sso=<token>`, and
 * `parkeze-local-access open` prints a link ending `#ticket=<hex>`. Either is
 * removed from the URL as soon as it is presented, success or not: a fragment
 * is never sent to a server, but it does stay in history, and the back button
 * on a shared laptop should not be a way back into somebody's session. The
 * gateway also refuses a token the second time, so this is the second of two
 * locks.
 *
 * Reading is kept pure and clearing happens in the effect that presents it.
 * This used to clear the fragment inside the useState initializer, which
 * StrictMode calls twice in development: the first call took the token, the
 * second found nothing, React kept the second, and no link ever signed anybody
 * in from `npm run dev`.
 */
type Handoff = { kind: 'sso' | 'ticket'; token: string };

function readHandoff(): Handoff | null {
  const params = new URLSearchParams(window.location.hash.replace(/^#/, ''));
  const sso = params.get('sso');
  const ticket = params.get('ticket');
  if (sso) return { kind: 'sso', token: sso };
  if (ticket) return { kind: 'ticket', token: ticket };
  return null;
}

export default function Login() {
  const [mode, setMode] = useState<'password' | 'recovery' | 'parkeze' | null>(null);
  const [handoffToken, setHandoffToken] = useState(readHandoff);
  const presented = useRef<string | null>(null);
  const { signIn } = useSession();

  // A link opened in a tab already showing this screen changes only the
  // fragment, which does not reload the page and so is never read above.
  useEffect(() => {
    const onHashChange = () => {
      const next = readHandoff();
      if (next) setHandoffToken(next);
    };
    window.addEventListener('hashchange', onHashChange);
    return () => window.removeEventListener('hashchange', onHashChange);
  }, []);

  const handoff = useMutation({
    mutationFn: (handoff: Handoff) =>
      handoff.kind === 'sso'
        ? api.signIn<Session>('/auth/sso', { token: handoff.token })
        : api.signIn<Session>('/auth/ticket', { ticket: handoff.token }),
    onSuccess: signIn,
  });

  useEffect(() => {
    // Once per token. StrictMode runs this effect twice in development, and a
    // second presentation of a spent token is a refusal the gateway counts
    // toward locking this address out.
    if (!handoffToken || presented.current === handoffToken.token) return;
    presented.current = handoffToken.token;
    window.history.replaceState(null, '', window.location.pathname + window.location.search);
    handoff.mutate(handoffToken);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [handoffToken]);

  const methods = useQuery({
    queryKey: ['auth-methods'],
    queryFn: () => api.get<LoginMethods>('/auth/methods'),
    retry: false,
  });

  if (handoffToken && !handoff.isError) {
    return (
      <div className={styles.wrap}>
        <div className={styles.card}>
          <Spinner label="Signing in" />
        </div>
      </div>
    );
  }

  if (methods.isLoading) {
    return (
      <div className={styles.wrap}>
        <div className={styles.card}>
          <Spinner label="Contacting the gateway" />
        </div>
      </div>
    );
  }

  if (methods.isError) {
    return (
      <div className={styles.wrap}>
        <div className={styles.card}>
          <Notice tone="error">
            Cannot reach the gateway API: {(methods.error as Error).message}
          </Notice>
        </div>
      </div>
    );
  }

  const available = methods.data!;
  // An adopted gateway with local sign-in off has exactly one way in, so land
  // on it rather than making somebody click past a form they cannot use.
  // Adopted: Parkeze sign-in first. Recovery is for when the browser has no
  // internet either, which is the rarer case and one click away.
  const effective =
    mode ?? (available.local ? 'password' : available.sso ? 'parkeze' : 'recovery');

  // A refused LAN link is shown above whichever form follows, since none of
  // them is the way back in: that is a fresh link from the gateway's shell.
  const handoffError = handoff.isError ? (handoff.error as Error).message : null;
  const ssoError = handoffToken?.kind === 'sso' ? handoffError : null;
  const ticketError = handoffToken?.kind === 'ticket' ? handoffError : null;

  return (
    <div className={styles.wrap}>
      <div className={`${styles.card} fade-in`}>
        <div className={styles.brand}>
          <Brand size="md" sub="Gateway console" />
        </div>

        {ticketError && <Notice tone="error">{ticketError}</Notice>}

        {effective === 'recovery' ? (
          <Recovery
            canGoBack={available.local || available.sso}
            onBack={() => setMode(available.local ? 'password' : 'parkeze')}
          />
        ) : effective === 'parkeze' ? (
          <ParkezeSignIn
            methods={available}
            error={ssoError}
            onRecovery={() => setMode('recovery')}
          />
        ) : (
          <PasswordForm methods={available} onRecovery={() => setMode('recovery')} />
        )}
      </div>
    </div>
  );
}

/**
 * Sign in with a Parkeze account.
 *
 * Sends the browser to parkeze.net, which names this gateway, asks the person
 * to confirm, and returns a short-lived token this gateway verifies offline.
 * Only the browser needs internet — the gateway does not talk to Parkeze for
 * any of it — so this works on a site where the gateway's own uplink is down
 * but the technician's laptop is on a phone hotspot.
 */
function ParkezeSignIn({
  methods,
  error,
  onRecovery,
}: {
  methods: LoginMethods;
  error: string | null;
  onRecovery: () => void;
}) {
  const target = methods.platform && methods.deviceId
    ? `${methods.platform.replace(/\/$/, '')}/gateway-access#gw=${methods.deviceId}` +
      `&ret=${encodeURIComponent(window.location.origin)}`
    : null;

  return (
    <>
      <h1 className={styles.title}>Sign in</h1>
      {error && <Notice tone="error">{error}</Notice>}
      <div className={styles.row}>
        <Button
          variant="primary"
          disabled={!target}
          onClick={() => target && window.location.assign(target)}
        >
          <LogIn size={14} strokeWidth={2} />
          Sign in with Parkeze
        </Button>
        <div className={styles.spacer} />
        {methods.recovery && (
          <Button onClick={onRecovery}>
            <ShieldCheck size={14} strokeWidth={2} />
            Recovery access
          </Button>
        )}
      </div>
    </>
  );
}

function PasswordForm({
  methods,
  onRecovery,
}: {
  methods: LoginMethods;
  onRecovery: () => void;
}) {
  const { signIn } = useSession();
  const [username, setUsername] = useState('parkeze');
  const [password, setPassword] = useState('');

  const login = useMutation({
    mutationFn: () => api.post<Session>('/auth/login', { username, password }),
    onSuccess: signIn,
  });

  return (
    <form
      onSubmit={(event) => {
        event.preventDefault();
        login.mutate();
      }}
    >
      <h1 className={styles.title}>Sign in</h1>

      {/* Only when the gateway has something non-obvious to say. An unadopted
          gateway says nothing here: the form is in front of you and the adopt
          route is one click away. */}
      {methods.note && (
        <Notice tone={methods.state === 'adopted' && methods.local ? 'warning' : 'info'}>
          {methods.note}
        </Notice>
      )}

      <TextField
        label="Username"
        autoComplete="username"
        value={username}
        onChange={(event) => setUsername(event.target.value)}
      />
      <TextField
        label="Password"
        type="password"
        autoComplete="current-password"
        autoFocus
        value={password}
        onChange={(event) => setPassword(event.target.value)}
      />

      {login.isError && <Notice tone="error">{(login.error as Error).message}</Notice>}

      <div className={styles.row}>
        <Button variant="primary" type="submit" loading={login.isPending}>
          Sign in
        </Button>
        <div className={styles.spacer} />
        {methods.recovery && (
          <Button onClick={onRecovery}>
            <ShieldCheck size={14} strokeWidth={2} />
            Recovery access
          </Button>
        )}
      </div>
    </form>
  );
}
