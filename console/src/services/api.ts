/**
 * The one place that talks to the gateway.
 *
 * Deliberately thin. The API is a dozen endpoints on the same origin behind a
 * session cookie, so this is a fetch wrapper with three responsibilities and
 * no more: attach the CSRF token, turn a non-2xx into a thrown `ApiError`, and
 * notice when the session has died.
 */

import type { Session } from '@/types';

export class ApiError extends Error {
  constructor(
    message: string,
    readonly status: number,
  ) {
    super(message);
    this.name = 'ApiError';
  }
}

/**
 * The current session's CSRF token.
 *
 * Module-level rather than in React state because `api()` is called from query
 * functions that have no access to context, and threading it through every
 * call site would put a token argument on functions that are otherwise about
 * gateways and LEDs. SessionProvider owns writing it.
 */
let csrfToken: string | null = null;

export function setCsrfToken(token: string | null) {
  csrfToken = token;
}

/**
 * Called when the gateway answers 401 on a request we thought was
 * authenticated — the session expired, or the device rebooted and dropped
 * every session with it (they live in /var/run on purpose). SessionProvider
 * registers a handler so the app drops to the login screen rather than leaving
 * a page of stale values on screen.
 */
let onUnauthenticated: (() => void) | null = null;

export function setUnauthenticatedHandler(handler: (() => void) | null) {
  onUnauthenticated = handler;
}

interface RequestOptions {
  method?: 'GET' | 'POST' | 'PUT' | 'DELETE';
  body?: unknown;
  /** Suppresses the drop-to-login on 401. Used by the session probe at boot,
      where a 401 is the expected answer and not a failure. */
  anonymous?: boolean;
}

async function request<T>(path: string, options: RequestOptions = {}): Promise<T> {
  const method = options.method ?? 'GET';
  const headers: Record<string, string> = { 'Content-Type': 'application/json' };

  // Every state-changing request echoes the session's CSRF token. The cookie
  // is SameSite=Strict, but the console is also reachable through the
  // parkeze.net proxy under a different origin, where that reasoning gets
  // subtle enough that the header check earns its keep.
  if (method !== 'GET' && csrfToken) headers['X-Parkeze-CSRF'] = csrfToken;

  const response = await fetch(`/api${path}`, {
    method,
    headers,
    // The session cookie is HttpOnly; this is what sends it.
    credentials: 'same-origin',
    body: options.body === undefined ? undefined : JSON.stringify(options.body),
  });

  let payload: { error?: string } & Record<string, unknown> = {};
  try {
    payload = await response.json();
  } catch {
    // An empty body on a 200 is normal for some endpoints.
  }

  if (response.status === 401 && !options.anonymous) {
    onUnauthenticated?.();
    throw new ApiError('Your session has ended. Sign in again.', 401);
  }

  if (!response.ok) {
    throw new ApiError(
      payload.error ?? `Request failed (${response.status})`,
      response.status,
    );
  }

  return payload as T;
}

/**
 * Upload a file as the raw request body, reporting progress.
 *
 * XHR rather than fetch because fetch cannot report upload progress, and a
 * 30MB firmware image over a slow link with no indication of movement looks
 * exactly like a hang. Same CSRF and 401 handling as `request`.
 */
export function upload<T>(
  path: string,
  file: Blob,
  onProgress: (fraction: number) => void,
  // Extra headers. The firmware upload sends its signature this way: the body
  // is the raw image, so there is nowhere else in the request to put a few
  // hundred bytes of manifest.
  headers?: Record<string, string>,
): Promise<T> {
  return new Promise((resolve, reject) => {
    const xhr = new XMLHttpRequest();
    xhr.open('POST', `/api${path}`);
    xhr.withCredentials = true;
    xhr.setRequestHeader('Content-Type', 'application/octet-stream');
    if (csrfToken) xhr.setRequestHeader('X-Parkeze-CSRF', csrfToken);
    for (const [name, value] of Object.entries(headers ?? {})) {
      xhr.setRequestHeader(name, value);
    }

    xhr.upload.onprogress = (event) => {
      if (event.lengthComputable) onProgress(event.loaded / event.total);
    };
    xhr.onerror = () => reject(new ApiError('The upload was interrupted.', 0));
    xhr.onload = () => {
      let payload: { error?: string } & Record<string, unknown> = {};
      try {
        payload = JSON.parse(xhr.responseText);
      } catch {
        // Non-JSON answer; the status says enough.
      }
      if (xhr.status === 401) {
        onUnauthenticated?.();
        reject(new ApiError('Your session has ended. Sign in again.', 401));
      } else if (xhr.status < 200 || xhr.status >= 300) {
        reject(new ApiError(payload.error ?? `Upload failed (${xhr.status})`, xhr.status));
      } else {
        resolve(payload as T);
      }
    };
    xhr.send(file);
  });
}

export const api = {
  get: <T>(path: string) => request<T>(path),
  post: <T>(path: string, body?: unknown) => request<T>(path, { method: 'POST', body }),

  /** Presenting a credential. A 401 here is the gateway refusing it, with a
      reason worth showing — not a session that ended, which nobody had. */
  signIn: <T>(path: string, body: unknown) =>
    request<T>(path, { method: 'POST', body, anonymous: true }),

  /** The session probe at boot. A 401 here means "not signed in", not "error". */
  session: () => request<Session>('/auth/session', { anonymous: true }),
};
