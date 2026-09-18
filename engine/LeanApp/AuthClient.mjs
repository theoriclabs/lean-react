/** Same-origin cookie authentication. No bearer or password is stored in snapshots/storage.
 * Auth transitions are serialized, including response parsing; every invocation immediately
 * invalidates prior ownership. Queued credentials exist only until their request is sent.
 * subscribe/getSnapshot support React.useSyncExternalStore. request returns parsed JSON,
 * never an unchecked Response that could be consumed after ownership changes.
 */
const codes = new Set(['auth.invalid_credentials', 'auth.username_unavailable', 'auth.invalid_username',
  'auth.invalid_password', 'auth.required', 'auth.forbidden', 'auth.throttled', 'auth.unavailable', 'auth.failed',
  'auth.invite_required', 'auth.session_not_found']);
export class AuthError extends Error {
  constructor(code, status = 0) { super(code); this.name = 'AuthError'; this.code = code; this.status = status; }
}
const fail = code => { throw new AuthError(code); };
const object = x => x !== null && typeof x === 'object' && !Array.isArray(x);
const hex64 = /^[0-9a-f]{64}$/;
const stamp = /^(0|[1-9][0-9]{0,18})$/;
function session(value) {
  const u = value?.user;
  if (!object(value) || !object(u) || !/^[A-Za-z0-9_-]{3,32}$/.test(u.username ?? '') ||
      typeof u.username !== 'string' || typeof u.actor !== 'string' || !u.actor || u.actor.length > 1024 ||
      typeof u.tenant !== 'string' || !u.tenant || u.tenant.length > 1024 ||
      typeof u.generation !== 'string' || !/^(0|[1-9][0-9]{0,127})$/.test(u.generation) ||
      typeof value.csrf !== 'string' || !hex64.test(value.csrf)) fail('auth.protocol');
  return { user: Object.freeze({ username: u.username, actor: u.actor, tenant: u.tenant, generation: u.generation }), csrf: value.csrf };
}
function sessionList(value) {
  const list = value?.sessions;
  if (!object(value) || !Array.isArray(list) || list.length > 1000) fail('auth.protocol');
  return Object.freeze(list.map(s => {
    if (!object(s) || typeof s.id !== 'string' || !hex64.test(s.id) || typeof s.current !== 'boolean' ||
        (s.label !== null && (typeof s.label !== 'string' || s.label.length > 64)) ||
        [s.createdAt, s.lastSeenAt].some(t => t !== null && (typeof t !== 'string' || !stamp.test(t)))) fail('auth.protocol');
    return Object.freeze({ id: s.id, label: s.label, createdAt: s.createdAt, lastSeenAt: s.lastSeenAt, current: s.current });
  }));
}
/** Coarse platform/browser string for the session list; never a full user agent. */
export function deviceLabel(userAgent = globalThis.navigator?.userAgent ?? '') {
  if (typeof userAgent !== 'string' || !userAgent) return undefined;
  const platform = /Android/.test(userAgent) ? 'Android' : /iPhone|iPad|iPod/.test(userAgent) ? 'iOS' :
    /Mac OS X|Macintosh/.test(userAgent) ? 'macOS' : /Windows/.test(userAgent) ? 'Windows' :
    /CrOS/.test(userAgent) ? 'ChromeOS' : /Linux/.test(userAgent) ? 'Linux' : /Node\.js/.test(userAgent) ? 'Node.js' : 'Unknown';
  const browser = /Edg\//.test(userAgent) ? 'Edge' : /OPR\/|Opera/.test(userAgent) ? 'Opera' :
    /Firefox\//.test(userAgent) ? 'Firefox' : /Chrome\/|Chromium\/|CriOS\//.test(userAgent) ? 'Chrome' :
    /Safari\//.test(userAgent) ? 'Safari' : undefined;
  return browser ? `${browser} on ${platform}` : platform;
}

export function createAuthClient({ fetch: fetchImpl = globalThis.fetch, label = deviceLabel() } = {}) {
  let epoch = 0, current = null, queue = Promise.resolve();
  let state = Object.freeze({ user: null, transitioning: false, epoch, error: null });
  const listeners = new Set();
  const publish = next => { state = Object.freeze(next); for (const fn of listeners) fn(); };
  const labelled = (payload, override) => {
    const value = override === undefined ? label : override;
    return typeof value === 'string' && value.trim() ? { ...payload, label: value.slice(0, 64) } : payload;
  };
  async function send(path, method, body, csrf) {
    const headers = { 'X-LeanApp-Request': '1' };
    if (body !== undefined) headers['Content-Type'] = 'application/json';
    if (csrf) headers['X-CSRF-Token'] = csrf;
    let response;
    try {
      const pending = fetchImpl(path, { method, headers, credentials: 'same-origin', redirect: 'error',
        cache: 'no-store', ...(body === undefined ? {} : { body: JSON.stringify(body) }) });
      body = undefined;
      response = await pending;
    } catch { fail('auth.unavailable'); }
    let value;
    try { value = await response.json(); } catch { fail('auth.protocol'); }
    if (!response.ok) throw new AuthError(codes.has(value?.error) ? value.error : 'auth.failed', response.status);
    return value;
  }
  // Every cookie-changing exchange: signup, login, restore, logout, logout-all and password change.
  function transition(kind, payload) {
    const owner = ++epoch;
    // Keep private CSRF until the queued request executes, but drop visible ownership now.
    publish({ user: null, transitioning: true, epoch, error: null });
    const operation = queue.then(async () => {
      try {
        if (kind === 'logout' || kind === 'logout-all') {
          const csrf = current?.csrf;
          current = null;
          if (!csrf) fail('auth.required');
          const result = await send(`/auth/${kind}`, 'POST', {}, csrf);
          if (!object(result) || result.ok !== true) fail('auth.protocol');
        } else if (kind === 'password') {
          const csrf = current?.csrf;
          current = null;
          if (!csrf) { payload = undefined; fail('auth.required'); }
          const pending = send('/auth/password', 'POST', payload, csrf);
          payload = undefined;
          current = session(await pending);
        } else {
          current = null;
          const pending = send(kind === 'restore' ? '/auth/session' : `/auth/${kind}`,
            kind === 'restore' ? 'GET' : 'POST', payload);
          payload = undefined;
          current = session(await pending);
        }
        if (owner !== epoch) fail('auth.stale');
        publish({ user: current?.user ?? null, transitioning: false, epoch, error: null });
        return state.user;
      } catch (error) {
        payload = undefined;
        if (owner !== epoch) throw new AuthError('auth.stale');
        current = null;
        const safe = error instanceof AuthError ? error : new AuthError('auth.failed');
        publish({ user: null, transitioning: false, epoch, error: safe.code });
        throw safe;
      }
    });
    queue = operation.catch(() => {});
    return operation;
  }
  // A CSRF-protected exchange that keeps the current session unless the server says it is gone.
  async function protectedSend(path, method, body) {
    if (state.transitioning || !state.user || !current) fail('auth.required');
    const owner = epoch;
    try {
      const result = await send(path, method, method === 'GET' ? undefined : body, current.csrf);
      if (owner !== epoch) fail('auth.stale');
      return result;
    } catch (error) {
      if (owner !== epoch) throw new AuthError('auth.stale');
      if (error instanceof AuthError && error.code === 'auth.required') {
        current = null; ++epoch;
        publish({ user: null, transitioning: false, epoch, error: error.code });
      }
      throw error;
    }
  }
  async function request(path, { method = 'POST', body = {} } = {}) {
    if (typeof path !== 'string' || !/^\/api\/[A-Za-z0-9_/-]+$/.test(path) || path.includes('//')) fail('auth.invalid_request');
    if (!['GET', 'POST', 'PUT', 'PATCH', 'DELETE'].includes(method)) fail('auth.invalid_request');
    return protectedSend(path, method, body);
  }
  async function call(path, envelope) {
    const owner = epoch;
    if (!object(envelope?.operation) || !['namespace', 'name', 'version'].every(k =>
      typeof envelope.operation[k] === 'string' && envelope.operation[k].length > 0)) fail('auth.invalid_request');
    const result = await request(path, { body: envelope });
    if (owner !== epoch) fail('auth.stale');
    const op = result?.operation;
    if (!object(result) || result.tag !== 'success' || !object(op) ||
        !['namespace', 'name', 'version'].every(k => op[k] === envelope?.operation?.[k]) ||
        !Object.hasOwn(result, 'value')) fail('auth.protocol');
    return result.value;
  }
  async function revokeSession(id) {
    if (typeof id !== 'string' || !hex64.test(id)) fail('auth.invalid_request');
    const owner = epoch;
    const result = await protectedSend('/auth/sessions/revoke', 'POST', { id });
    if (!object(result) || result.ok !== true || typeof result.current !== 'boolean') fail('auth.protocol');
    // Revoking the current session cleared the cookie: behave like a logout locally.
    if (result.current && owner === epoch) {
      current = null; ++epoch;
      publish({ user: null, transitioning: false, epoch, error: null });
    }
    return result.current;
  }
  return Object.freeze({
    // `invite` is only accepted by servers configured with the invite tenant policy; `label`
    // names this device in the session list (defaults to a coarse platform/browser string).
    signup: (username, password, { invite, label: override } = {}) => transition('signup',
      labelled({ username, password, ...(typeof invite === 'string' && invite ? { invite } : {}) }, override)),
    login: (username, password, { label: override } = {}) => transition('login', labelled({ username, password }, override)),
    logout: () => transition('logout'), restore: () => transition('restore'), request, call,
    logoutAll: () => transition('logout-all'),
    changePassword: (currentPassword, newPassword) => transition('password', { currentPassword, newPassword }),
    sessions: async () => sessionList(await protectedSend('/auth/sessions', 'POST', {})),
    revokeSession,
    getSnapshot: () => state,
    subscribe(fn) { listeners.add(fn); return () => listeners.delete(fn); },
  });
}
