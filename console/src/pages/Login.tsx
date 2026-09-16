import { useState } from 'react';
import { useMutation, useQuery } from '@tanstack/react-query';
import { ShieldCheck } from 'lucide-react';
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
export default function Login() {
  const [mode, setMode] = useState<'password' | 'recovery' | null>(null);

  const methods = useQuery({
    queryKey: ['auth-methods'],
    queryFn: () => api.get<LoginMethods>('/auth/methods'),
    retry: false,
  });

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
  const effective = mode ?? (available.local ? 'password' : 'recovery');

  return (
    <div className={styles.wrap}>
      <div className={`${styles.card} fade-in`}>
        <div className={styles.brand}>
          <Brand size="md" sub="Gateway console" />
        </div>

        {effective === 'recovery' ? (
          <Recovery
            canGoBack={available.local}
            onBack={() => setMode('password')}
          />
        ) : (
          <PasswordForm methods={available} onRecovery={() => setMode('recovery')} />
        )}
      </div>
    </div>
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
