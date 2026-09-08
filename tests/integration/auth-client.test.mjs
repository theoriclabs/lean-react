import test from 'node:test';
import assert from 'node:assert/strict';
import { createAuthClient } from '../../engine/LeanApp/AuthClient.mjs';

const csrf = 'a'.repeat(64);
const user = (name = 'alice') => ({ username: name, actor: `actor:${name}`, tenant: 'demo', generation: '9007199254740993' });
const session = (name = 'alice') => ({ user: user(name), csrf });
const response = (value, status = 200) => ({ ok: status >= 200 && status < 300, status, json: async () => value });
const deferred = () => { let resolve; const promise = new Promise(r => { resolve = r; }); return { promise, resolve }; };
const tick = () => new Promise(resolve => setImmediate(resolve));
const code = expected => error => error.code === expected && error.message === expected;
const envelope = { operation: { namespace: 'auth-demo', name: 'whoami', version: '1' }, kind: 'query', input: null };

test('signup/login/restore/logout use cookie credentials and exact headers/bodies', async () => {
  const calls = [];
  const c = createAuthClient({ fetch: async (path, init) => {
    calls.push({ path, ...init }); return response(path === '/auth/logout' ? { ok: true } : session());
  } });
  let notifications = 0;
  const unsubscribe = c.subscribe(() => ++notifications);
  const password = '  long password 😀\0  ';
  assert.deepEqual(await c.signup('Alice', password), user());
  await c.login('Alice', password); await c.restore(); await c.logout();
  assert.deepEqual(calls.map(c => c.path), ['/auth/signup', '/auth/login', '/auth/session', '/auth/logout']);
  for (const call of calls) {
    assert.equal(call.credentials, 'same-origin'); assert.equal(call.redirect, 'error');
    assert.equal(call.headers['X-LeanApp-Request'], '1'); assert.equal(call.cache, 'no-store');
    assert.equal(call.headers.Authorization, undefined); assert.equal(call.headers.Origin, undefined);
  }
  assert.deepEqual(JSON.parse(calls[0].body), { username: 'Alice', password });
  assert.deepEqual(JSON.parse(calls[1].body), { username: 'Alice', password });
  assert.equal(calls[2].method, 'GET'); assert.equal(calls[2].body, undefined);
  assert.equal(calls[3].headers['X-CSRF-Token'], csrf); assert.equal(calls[3].body, '{}');
  assert.equal(calls[0].headers['Content-Type'], 'application/json');
  assert.equal(c.getSnapshot().user, null); assert.equal(c.getSnapshot().transitioning, false);
  assert.equal(notifications, 8); unsubscribe();
  assert.equal(JSON.stringify(c.getSnapshot()).includes(password), false);
  assert.equal(JSON.stringify(c.getSnapshot()).includes(csrf), false);
});

test('protected requests carry CSRF and call validates the Contract envelope', async () => {
  let last;
  const c = createAuthClient({ fetch: async (path, init) => {
    last = { path, ...init };
    return response(path === '/auth/session' ? session() : { tag: 'success', operation: envelope.operation, value: 'alice' });
  } });
  await assert.rejects(c.request('/api/whoami'), code('auth.required'));
  await c.restore();
  assert.equal(await c.call('/api/whoami', envelope), 'alice');
  assert.equal(last.headers['X-CSRF-Token'], csrf);
  assert.deepEqual(JSON.parse(last.body), envelope);
  await c.request('/api/whoami', { method: 'GET' });
  assert.equal(last.body, undefined); assert.equal(last.headers['X-CSRF-Token'], csrf);
  for (const path of ['https://evil.example/api/x', '//evil/api/x', '/auth/logout', '/api/../auth/logout', '/api/x?url=evil'])
    await assert.rejects(c.request(path), code('auth.invalid_request'));
  await assert.rejects(c.call('/api/whoami', {}), code('auth.invalid_request'));
});

test('backend errors are typed, sanitized, and failed login drops old identity', async () => {
  let status = 200;
  const c = createAuthClient({ fetch: async () => response(status === 200 ? session() : { error: 'auth.invalid_credentials', detail: 'secret' }, status) });
  await c.restore(); status = 401;
  const login = c.login('alice', 'bad');
  assert.equal(c.getSnapshot().user, null);
  await assert.rejects(login, code('auth.invalid_credentials'));
  assert.equal(c.getSnapshot().user, null);
  await assert.rejects(c.request('/api/whoami'), code('auth.required'));
  assert.equal(c.getSnapshot().error, 'auth.invalid_credentials');
});

test('all declared error codes survive; unknown/transport errors are sanitized', async () => {
  for (const error of ['invalid_credentials', 'username_unavailable', 'invalid_username', 'invalid_password', 'required', 'forbidden', 'throttled', 'unavailable', 'failed']) {
    const c = createAuthClient({ fetch: async () => response({ error: `auth.${error}` }, 400) });
    await assert.rejects(c.restore(), code(`auth.${error}`));
  }
  const unknown = createAuthClient({ fetch: async () => response({ error: 'secret-value' }, 500) });
  await assert.rejects(unknown.restore(), code('auth.failed'));
  const offline = createAuthClient({ fetch: async () => { throw new Error('secret URL'); } });
  await assert.rejects(offline.restore(), code('auth.unavailable'));
});

test('strict session response validation rejects malformed shapes without disclosure', async () => {
  for (const value of [null, {}, { ...session(), csrf: 'A'.repeat(64) },
    { ...session(), csrf: 'a'.repeat(65) }, { ...session(), user: { ...user(), generation: 1 } },
    { ...session(), user: { ...user(), generation: '01' } }, { ...session(), user: { ...user(), actor: {} } },
    { ...session(), user: { ...user(), tenant: '' } }, { ...session(), user: { ...user(), username: 'x' } }]) {
    const c = createAuthClient({ fetch: async () => response(value) });
    await assert.rejects(c.restore(), code('auth.protocol'));
    assert.equal(c.getSnapshot().user, null);
  }
  const c = createAuthClient({ fetch: async () => ({ ok: true, json: async () => { throw new Error('secret'); } }) });
  await assert.rejects(c.restore(), code('auth.protocol'));
});

test('auth transitions serialize responses and stale login cannot publish its identity', async () => {
  const pending = [], calls = [];
  const c = createAuthClient({ fetch: (path, init) => { const d = deferred(); pending.push(d); calls.push({ path, ...init }); return d.promise; } });
  const first = c.login('alice', 'first password');
  const firstRejected = assert.rejects(first, code('auth.stale'));
  const second = c.login('bobby', 'second password');
  await tick(); assert.equal(calls.length, 1);
  pending[0].resolve(response(session('alice')));
  await firstRejected; await tick();
  assert.equal(calls.length, 2); assert.equal(c.getSnapshot().user, null);
  pending[1].resolve(response(session('bobby')));
  await second; assert.equal(c.getSnapshot().user.username, 'bobby');
});

test('queued logout uses CSRF from preceding login and keeps public identity cleared', async () => {
  const d = deferred(); const calls = [];
  const c = createAuthClient({ fetch: async (path, init) => {
    calls.push({ path, ...init }); return path === '/auth/login' ? d.promise : response({ ok: true });
  } });
  const login = c.login('alice', 'password');
  const stale = assert.rejects(login, code('auth.stale'));
  const logout = c.logout();
  await tick(); assert.equal(calls.length, 1);
  d.resolve(response(session())); await stale; await logout;
  assert.equal(calls[1].path, '/auth/logout'); assert.equal(calls[1].headers['X-CSRF-Token'], csrf);
  assert.equal(c.getSnapshot().user, null);
});

test('late protected success/error cannot cross logout or failed replacement ownership', async () => {
  for (const transition of ['logout', 'login']) for (const late of [response({ value: 'alice' }), response({ error: 'auth.required' }, 401)]) {
    const d = deferred();
    const c = createAuthClient({ fetch: async path => {
      if (path === '/auth/session') return response(session());
      if (path === '/api/whoami') return d.promise;
      return transition === 'logout' ? response({ ok: true }) : response({ error: 'auth.invalid_credentials' }, 401);
    } });
    await c.restore(); const operation = c.request('/api/whoami');
    const stale = assert.rejects(operation, code('auth.stale'));
    const change = transition === 'logout' ? c.logout() : c.login('bobby', 'wrong');
    assert.equal(c.getSnapshot().user, null);
    if (transition === 'login') await assert.rejects(change, code('auth.invalid_credentials')); else await change;
    d.resolve(late); await stale; assert.equal(c.getSnapshot().user, null);
  }
});

test('late old-session unauthorized response cannot clear a newer session', async () => {
  const d = deferred();
  const c = createAuthClient({ fetch: async path => path.startsWith('/api/') ? d.promise : response(session(path === '/auth/login' ? 'bobby' : 'alice')) });
  await c.restore(); const pending = c.request('/api/whoami');
  const stale = assert.rejects(pending, code('auth.stale'));
  await c.login('bobby', 'password');
  d.resolve(response({ error: 'auth.required' }, 401)); await stale;
  assert.equal(c.getSnapshot().user.username, 'bobby');
});

test('active-session unauthorized response invalidates concurrent operations', async () => {
  const pending = [];
  const c = createAuthClient({ fetch: async path => {
    if (path === '/auth/session') return response(session());
    const d = deferred(); pending.push(d); return d.promise;
  } });
  await c.restore(); const first = c.request('/api/whoami'), second = c.request('/api/whoami');
  const failed = assert.rejects(first, code('auth.required'));
  const stale = assert.rejects(second, code('auth.stale'));
  pending[0].resolve(response({ error: 'auth.required' }, 401)); await failed;
  pending[1].resolve(response({ value: 'alice' })); await stale;
  assert.equal(c.getSnapshot().user, null);
});

test('malformed logout and mismatched Contract responses fail closed', async () => {
  const c = createAuthClient({ fetch: async path => response(path === '/auth/session' ? session() : { ok: false }) });
  await c.restore(); await assert.rejects(c.logout(), code('auth.protocol'));
  assert.equal(c.getSnapshot().user, null);
  const other = createAuthClient({ fetch: async path => response(path === '/auth/session' ? session() : {
    tag: 'success', operation: { ...envelope.operation, version: '2' }, value: 'alice',
  }) });
  await other.restore(); await assert.rejects(other.call('/api/whoami', envelope), code('auth.protocol'));
});
