import test from 'node:test';
import assert from 'node:assert/strict';
import { spawn, spawnSync } from 'node:child_process';
import { once } from 'node:events';
import { createServer } from 'node:net';
import { mkdtemp } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { resolve } from 'node:path';

test('real Lean HTTP signup, session isolation, restart and logout', { timeout: 60000 }, async () => {
  const probe = createServer();
  probe.listen(0, '127.0.0.1'); await once(probe, 'listening');
  const port = probe.address().port;
  await new Promise(resolve => probe.close(resolve));
  const origin = `http://127.0.0.1:${port}`;
  const directory = await mkdtemp(resolve(tmpdir(), 'leanapp-auth-http-'));
  const database = resolve(directory, 'auth.sqlite');
  const binary = resolve('adapters/native/.lake/build/bin/leanapp_auth_demo');
  let process, logs = '';
  const start = async () => {
    process = spawn(binary, [String(port), database, origin], { stdio: ['ignore', 'pipe', 'pipe'] });
    process.stdout.on('data', chunk => { logs += chunk; });
    process.stderr.on('data', chunk => { logs += chunk; });
    for (let n = 0; n < 200; n++) {
      if (process.exitCode !== null) throw new Error(`auth server exited: ${logs}`);
      try { if ((await fetch(`${origin}/health/ready`)).status === 200) return; } catch {}
      await new Promise(resolve => setTimeout(resolve, 50));
    }
    throw new Error('auth server readiness timed out');
  };
  const stop = async () => {
    if (process && process.exitCode === null && process.signalCode === null) {
      const exit = once(process, 'exit'); process.kill('SIGTERM'); await exit;
    }
  };
  const request = async (path, { method = 'POST', body = {}, cookie, csrf, headers = {} } = {}) => {
    const response = await fetch(origin + path, {
      method, redirect: 'error',
      headers: { 'x-leanapp-request': '1', 'content-type': 'application/json', origin,
        ...(cookie ? { cookie } : {}), ...(csrf ? { 'x-csrf-token': csrf } : {}), ...headers },
      ...(!['GET', 'HEAD'].includes(method) ? { body: JSON.stringify(body) } : {}),
    });
    assert.equal(response.headers.get('cache-control'), 'no-store');
    return { status: response.status, body: await response.json(), setCookie: response.headers.get('set-cookie') };
  };
  const credentials = { username: 'alice_http', password: 'correct horse battery staple 🔐' };
  const wire = { operation: { namespace: 'auth-demo', name: 'whoami', version: '1' }, kind: 'query', input: null };
  try {
    await start();
    assert.equal((await request('/auth/signup', { body: credentials, headers: { origin: 'https://evil.test' } })).status, 403);
    assert.equal((await request('/auth/signup', { body: { ...credentials, actor: 'admin' } })).status, 401);
    const alice = await request('/auth/signup', { body: credentials });
    assert.equal(alice.status, 200);
    assert.equal(alice.body.user.username, 'alice_http');
    assert.equal(alice.body.user.tenant, alice.body.user.actor);
    assert.match(alice.setCookie, /HttpOnly; SameSite=Strict/);
    assert(!alice.setCookie.includes('Secure')); // Explicit loopback development profile only.
    const cookie = alice.setCookie.split(';')[0], token = cookie.split('=')[1];
    assert(!JSON.stringify(alice.body).includes(token));
    assert.equal((await request('/auth/signup', { body: credentials })).status, 409);
    const wrong = await request('/auth/login', { body: { ...credentials, password: 'definitely a wrong password' } });
    const unknown = await request('/auth/login', { body: { ...credentials, username: 'missing_http' } });
    assert.deepEqual(wrong.body, unknown.body); assert.equal(wrong.status, 401);
    assert.equal((await request('/api/whoami', { body: wire, cookie })).status, 403);
    assert.equal((await request('/api/whoami', { body: wire, csrf: alice.body.csrf })).status, 401);
    assert.equal((await request('/api/whoami', { body: wire, cookie, csrf: alice.body.csrf })).body.value, 'alice_http');
    const bob = await request('/auth/signup', { body: { ...credentials, username: 'bob_http' } });
    assert.equal(bob.status, 200);
    assert.notEqual(bob.body.user.tenant, alice.body.user.tenant);
    const bobCookie = bob.setCookie.split(';')[0];
    assert.equal((await request('/api/whoami', { body: wire, cookie: bobCookie, csrf: alice.body.csrf })).status, 403);
    assert.equal((await request('/api/whoami', { body: wire, cookie: bobCookie, csrf: bob.body.csrf,
      headers: { 'x-user-id': alice.body.user.actor, 'x-tenant-id': alice.body.user.tenant } })).body.value, 'bob_http');
    await stop(); await start();
    assert.equal((await request('/auth/session', { method: 'GET', cookie })).body.user.username, 'alice_http');
    assert.equal((await request('/api/whoami', { body: wire, cookie, csrf: alice.body.csrf })).status, 200);
    const login = await request('/auth/login', { body: credentials, cookie });
    assert.equal(login.status, 200); assert.notEqual(login.setCookie.split(';')[0], cookie);
    assert.equal((await request('/auth/session', { method: 'GET', cookie })).status, 401);
    const fresh = login.setCookie.split(';')[0];
    const logout = await request('/auth/logout', { cookie: fresh, csrf: login.body.csrf });
    assert.equal(logout.status, 200); assert.match(logout.setCookie, /Max-Age=0/);
    assert.equal((await request('/auth/session', { method: 'GET', cookie: fresh })).status, 401);
    const race = await Promise.all([1, 2].map(() => request('/auth/signup', { body: { ...credentials, username: 'race_http' } })));
    assert.equal(race.filter(reply => reply.status === 200).length, 1);
    assert(race.some(reply => [409, 429].includes(reply.status)));
    const stored = spawnSync('sqlite3', [database,
      "SELECT count(*) FROM account WHERE passwordHash LIKE '$leanapp$scrypt$v1$N=131072$r=8$p=1$%';"], { encoding: 'utf8' });
    assert.equal(stored.status, 0); assert.equal(stored.stdout.trim(), '3');
    assert(!logs.includes(credentials.password)); assert(!logs.includes(token)); assert(!logs.includes(alice.body.csrf));
    console.log(`Auth HTTP fixture retained: ${directory}`);
  } finally { await stop(); }
});
