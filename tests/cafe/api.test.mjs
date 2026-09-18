import test from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { createServer } from 'node:net';
import { mkdtemp } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { resolve } from 'node:path';

test('native café persistence, authoritative pricing, bounded recipes and account isolation', { timeout: 60000 }, async () => {
  const probe = createServer(); probe.listen(0, '127.0.0.1'); await once(probe, 'listening');
  const port = probe.address().port; await new Promise(r => probe.close(r));
  const origin = `http://127.0.0.1:${port}`;
  const directory = await mkdtemp(resolve(tmpdir(), 'leanapp-cafe-'));
  let child, logs = '';
  const start = async () => {
    child = spawn(resolve('adapters/native/.lake/build/bin/leanapp_cafe'), [], { stdio: ['ignore', 'pipe', 'pipe'], env: {
      ...process.env, LEANAPP_DEVELOPMENT: '1', LEANAPP_ORIGIN: origin, LEANAPP_BACKEND_PORT: String(port),
      LEANAPP_DB_PATH: resolve(directory, 'cafe.sqlite') } });
    child.stdout.on('data', b => logs += b); child.stderr.on('data', b => logs += b);
    for (let n = 0; n < 200; n++) {
      if (child.exitCode !== null) throw new Error(`Backend exited: ${logs}`);
      try { if ((await fetch(origin + '/health/ready')).ok) return; } catch {}
      await new Promise(r => setTimeout(r, 50));
    }
    throw new Error('Backend did not become ready');
  };
  const stop = async () => { if (child?.exitCode === null && child.signalCode === null) {
    const exited = once(child, 'exit'); child.kill('SIGTERM'); await exited;
  } };
  const send = async (path, body, session, headers = {}) => {
    const r = await fetch(origin + path, { method: 'POST', headers: { origin, 'content-type': 'application/json',
      'x-leanapp-request': '1', ...(session ? { cookie: session.cookie, 'x-csrf-token': session.csrf } : {}), ...headers }, body: JSON.stringify(body) });
    return { status: r.status, cookie: r.headers.get('set-cookie')?.split(';')[0], body: await r.json() };
  };
  const call = (name, input, session, headers) => send(`/api/recipes/${name}`, {
    operation: { namespace: 'cafe', name, version: '1' }, kind: name === 'list' ? 'query' : 'command', input,
  }, session, headers);
  const draft = { temperature: 'hot', size: 'large', milk: 'oat', shots: 'double', decaf: false };
  try {
    await start(); assert.equal((await call('list', null)).status, 401);
    const manifest = await (await fetch(origin + '/api/manifest')).json();
    assert.deepEqual(manifest.operations.map(op => [op.name, op.metadata.describePolicy, op.http.path]),
      [['list', 'authenticated', '/api/recipes/list'], ['save', 'authenticated', '/api/recipes/save'],
        ['delete', 'authenticated', '/api/recipes/delete']]);
    const a = await send('/auth/signup', { username: 'cafe_alice', password: 'cafe-alice-safe-passphrase' });
    const b = await send('/auth/signup', { username: 'cafe_bob', password: 'cafe-bob-safe-passphrase' });
    assert.equal(a.status, 200); assert.equal(b.status, 200);
    const alice = { cookie: a.cookie, csrf: a.body.csrf }, bob = { cookie: b.cookie, csrf: b.body.csrf };
    assert.equal((await call('save', { name: 'Morning oat', configuration: draft }, alice, { origin: 'https://evil.example' })).status, 403);
    assert.equal((await call('save', { name: 'Morning oat', configuration: draft, priceMinor: '1' }, alice)).status, 400);
    assert.equal((await call('save', { name: 'Morning oat', configuration: { ...draft, temperature: 'iced', size: 'small' } }, alice)).status, 422);
    assert.equal((await call('save', { name: ' ', configuration: draft }, alice)).status, 400);
    const saved = await call('save', { name: 'Morning oat ☕', configuration: draft }, alice);
    assert.equal(saved.status, 200); assert.equal(saved.body.tag, 'success');
    assert.equal(saved.body.value.priceMinor, '625'); assert.match(saved.body.value.id, /^[0-9a-f]{64}$/);
    assert.deepEqual((await call('list', null, bob)).body.value, []);
    await call('delete', saved.body.value.id, bob);
    assert.equal((await call('list', null, alice)).body.value.length, 1);
    await stop(); await start();
    assert.deepEqual((await call('list', null, alice)).body.value, [saved.body.value]);
    for (let n = 1; n < 40; n++) assert.equal((await call('save', { name: `Recipe ${n}`, configuration: draft }, alice)).status, 200);
    assert.equal((await call('save', { name: 'Over limit', configuration: draft }, alice)).status, 422);
    assert.equal((await call('list', null, alice)).body.value.length, 40);
    await call('delete', saved.body.value.id, alice);
    assert.equal((await call('list', null, alice)).body.value.length, 39);
    assert.deepEqual((await call('list', null, bob)).body.value, []);
    assert.ok(!logs.includes('safe-passphrase')); assert.ok(!logs.includes(alice.cookie));
  } finally { await stop(); console.log(`Café fixture retained: ${directory}`); }
});
