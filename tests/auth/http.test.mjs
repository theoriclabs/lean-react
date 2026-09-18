import test from 'node:test';
import assert from 'node:assert/strict';
import { spawn, spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { once } from 'node:events';
import { createServer } from 'node:net';
import { mkdtemp } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { resolve } from 'node:path';

/** One `leanapp_auth_demo` process on a free loopback port with its own database. */
async function fixture(env = {}) {
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
    process = spawn(binary, [String(port), database, origin], { stdio: ['ignore', 'pipe', 'pipe'], env: { ...globalThis.process.env, ...env } });
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
  return { origin, directory, database, start, stop, request, logs: () => logs };
}

const wire = { operation: { namespace: 'auth-demo', name: 'whoami', version: '1' }, kind: 'query', input: null };

test('real Lean HTTP signup, session isolation, restart and logout', { timeout: 60000 }, async () => {
  const { directory, database, start, stop, request, logs } = await fixture();
  const credentials = { username: 'alice_http', password: 'correct horse battery staple 🔐' };
  try {
    await start();
    assert.equal((await request('/auth/signup', { body: credentials, headers: { origin: 'https://evil.test' } })).status, 403);
    assert.equal((await request('/auth/signup', { body: { ...credentials, actor: 'admin' } })).status, 401);
    assert.equal((await request('/auth/signup', { body: { ...credentials, invite: 'a'.repeat(64) } })).status, 401);
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
    assert(!logs().includes(credentials.password)); assert(!logs().includes(token)); assert(!logs().includes(alice.body.csrf));
    console.log(`Auth HTTP fixture retained: ${directory}`);
  } finally { await stop(); }
});

test('concurrent sessions: eviction, listing, targeted revoke, password change and logout everywhere', { timeout: 90000 }, async () => {
  const { start, stop, request, logs } = await fixture({ LEANAPP_MAX_SESSIONS: '3' });
  const password = 'a multi device passphrase 🔐', renewed = 'a renewed multi device passphrase';
  const cookieOf = reply => reply.setCookie.split(';')[0];
  const device = (reply, label) => ({ cookie: cookieOf(reply), csrf: reply.body.csrf, token: cookieOf(reply).split('=')[1], label });
  const session = d => request('/auth/session', { method: 'GET', cookie: d.cookie });
  try {
    await start();
    const one = device(await request('/auth/signup', { body: { username: 'multi_http', password, label: 'Laptop' } }), 'Laptop');
    const two = device(await request('/auth/login', { body: { username: 'multi_http', password, label: 'Phone' } }), 'Phone');
    const three = device(await request('/auth/login', { body: { username: 'multi_http', password } }));
    assert.equal((await session(one)).status, 200); assert.equal((await session(two)).status, 200);
    assert.equal((await request('/auth/login', { body: { username: 'multi_http', password, label: 1 } })).status, 401);
    const four = device(await request('/auth/login', { body: { username: 'multi_http', password, label: 'Desk' } }), 'Desk');
    assert.equal((await session(one)).status, 401);
    for (const d of [two, three, four]) assert.equal((await session(d)).status, 200);
    assert.equal((await request('/auth/sessions', { cookie: four.cookie })).status, 403);
    const listed = await request('/auth/sessions', { cookie: four.cookie, csrf: four.csrf });
    assert.equal(listed.status, 200); assert.equal(listed.body.sessions.length, 3);
    assert.deepEqual(listed.body.sessions.map(s => s.current), [true, false, false]);
    assert.deepEqual(listed.body.sessions.map(s => s.label).sort(), ['Desk', 'Phone', null].sort());
    const digests = [two, three, four].map(d => createHash('sha256').update(d.token).digest('hex'));
    for (const s of listed.body.sessions) {
      assert.match(s.id, /^[0-9a-f]{64}$/); assert.match(s.createdAt, /^[0-9]+$/); assert.match(s.lastSeenAt, /^[0-9]+$/);
      assert(!digests.includes(s.id)); assert(![two, three, four].some(d => d.token === s.id));
    }
    const phone = listed.body.sessions.find(s => s.label === 'Phone');
    assert.equal((await request('/auth/sessions/revoke', { cookie: two.cookie, csrf: two.csrf, body: { id: 'x'.repeat(64) } })).status, 404);
    assert.equal((await request('/auth/sessions/revoke', { cookie: two.cookie, csrf: two.csrf, body: { id: phone.id, extra: 1 } })).status, 404);
    const revoked = await request('/auth/sessions/revoke', { cookie: four.cookie, csrf: four.csrf, body: { id: phone.id } });
    assert.equal(revoked.status, 200); assert.deepEqual(revoked.body, { ok: true, current: false }); assert.equal(revoked.setCookie, null);
    assert.equal((await session(two)).status, 401); assert.equal((await session(four)).status, 200);
    const stranger = device(await request('/auth/signup', { body: { username: 'stranger_http', password } }));
    const mine = listed.body.sessions.find(s => s.current);
    assert.equal((await request('/auth/sessions/revoke', { cookie: stranger.cookie, csrf: stranger.csrf, body: { id: mine.id } })).status, 404);
    assert.equal((await session(four)).status, 200);
    const self = await request('/auth/sessions/revoke', { cookie: three.cookie, csrf: three.csrf, body: { id:
      (await request('/auth/sessions', { cookie: three.cookie, csrf: three.csrf })).body.sessions.find(s => s.current).id } });
    assert.deepEqual(self.body, { ok: true, current: true }); assert.match(self.setCookie, /Max-Age=0/);
    assert.equal((await session(three)).status, 401);
    const wrong = await request('/auth/password', { cookie: four.cookie, csrf: four.csrf, body: { currentPassword: 'not the password at all', newPassword: renewed } });
    assert.equal(wrong.status, 401); assert.equal(wrong.body.error, 'auth.invalid_credentials');
    assert.equal((await request('/auth/password', { cookie: four.cookie, csrf: four.csrf, body: { currentPassword: password, newPassword: 'short' } })).status, 400);
    assert.equal((await request('/auth/password', { cookie: four.cookie, body: { currentPassword: password, newPassword: renewed } })).status, 403);
    const five = device(await request('/auth/login', { body: { username: 'multi_http', password } }));
    const changed = await request('/auth/password', { cookie: four.cookie, csrf: four.csrf, body: { currentPassword: password, newPassword: renewed } });
    assert.equal(changed.status, 200); assert.equal(changed.body.user.username, 'multi_http');
    const reissued = device(changed);
    assert.notEqual(reissued.cookie, four.cookie); assert.notEqual(reissued.csrf, four.csrf);
    assert.equal((await session(four)).status, 401); assert.equal((await session(five)).status, 401);
    assert.equal((await session(reissued)).status, 200);
    assert.equal((await request('/api/whoami', { body: wire, cookie: reissued.cookie, csrf: reissued.csrf })).body.value, 'multi_http');
    assert.deepEqual((await request('/auth/sessions', { cookie: reissued.cookie, csrf: reissued.csrf })).body.sessions.map(s => s.label), ['Desk']);
    assert.equal((await request('/auth/login', { body: { username: 'multi_http', password } })).status, 401);
    const six = device(await request('/auth/login', { body: { username: 'multi_http', password: renewed } }));
    assert.equal(six.cookie.length > 0, true);
    const everywhere = await request('/auth/logout-all', { cookie: reissued.cookie, csrf: reissued.csrf });
    assert.equal(everywhere.status, 200); assert.match(everywhere.setCookie, /Max-Age=0/);
    assert.equal((await session(reissued)).status, 401); assert.equal((await session(six)).status, 401);
    for (const d of [one, two, three, four, five, six, reissued]) assert(!logs().includes(d.token));
    assert(!logs().includes(password) && !logs().includes(renewed));
  } finally { await stop(); }
});

test('fixed tenant policy shares one workspace; invite policy requires a token', { timeout: 60000 }, async () => {
  const shared = await fixture({ LEANAPP_TENANT_POLICY: 'fixed:workspace' });
  const password = 'a tenant policy passphrase 🔐';
  try {
    await shared.start();
    const a = await shared.request('/auth/signup', { body: { username: 'fixed_a', password } });
    const b = await shared.request('/auth/signup', { body: { username: 'fixed_b', password } });
    assert.equal(a.status, 200); assert.equal(b.status, 200);
    assert.equal(a.body.user.tenant, 'workspace'); assert.equal(b.body.user.tenant, 'workspace');
    assert.notEqual(a.body.user.actor, b.body.user.actor);
    assert.equal((await shared.request('/auth/signup', { body: { username: 'fixed_c', password, invite: 'a'.repeat(64) } })).status, 401);
  } finally { await shared.stop(); }
  const invited = await fixture({ LEANAPP_TENANT_POLICY: 'invite' });
  try {
    await invited.start();
    const denied = await invited.request('/auth/signup', { body: { username: 'invite_a', password } });
    assert.equal(denied.status, 403); assert.equal(denied.body.error, 'auth.invite_required');
    // Invites are issued by trusted native code only; a forged token is refused with the same code.
    const forged = await invited.request('/auth/signup', { body: { username: 'invite_a', password, invite: '0'.repeat(64) } });
    assert.equal(forged.status, 403); assert.equal(forged.body.error, 'auth.invite_required');
    assert.equal((await invited.request('/auth/login', { body: { username: 'invite_a', password } })).status, 401);
  } finally { await invited.stop(); }
});
