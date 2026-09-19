import test from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { createServer } from 'node:net';
import { mkdtemp } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { resolve } from 'node:path';

test('{{name}}: authentication, the shared title rule, persistence and account isolation', { timeout: 60000 }, async () => {
  const probe = createServer(); probe.listen(0, '127.0.0.1'); await once(probe, 'listening');
  const port = probe.address().port; await new Promise(r => probe.close(r));
  const origin = `http://127.0.0.1:${port}`;
  const directory = await mkdtemp(resolve(tmpdir(), '{{name}}-'));
  const binary = process.env.LEANAPP_BINARY ?? resolve('native/.lake/build/bin/{{name}}_server');
  let child, logs = '';
  const start = async () => {
    child = spawn(binary, [], { stdio: ['ignore', 'pipe', 'pipe'], env: { ...process.env,
      LEANAPP_DEVELOPMENT: '1', LEANAPP_ORIGIN: origin, LEANAPP_BACKEND_PORT: String(port),
      LEANAPP_DB_PATH: resolve(directory, '{{name}}.sqlite'), LEANAPP_DB_READERS: '2' } });
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
  const call = (name, input, session, headers) => send(`/api/notes/${name}`, {
    operation: { namespace: '{{namespace}}', name, version: '1' }, kind: name === 'list' ? 'query' : 'command', input,
  }, session, headers);
  try {
    await start();
    assert.equal((await call('list', null)).status, 401);
    const manifest = await (await fetch(origin + '/api/manifest')).json();
    assert.deepEqual(manifest.operations.map(op => [op.name, op.metadata.describePolicy, op.http.path]),
      [['list', 'authenticated', '/api/notes/list'], ['add', 'authenticated', '/api/notes/add']]);
    const a = await send('/auth/signup', { username: 'note_alice', password: 'alice-safe-passphrase-1' });
    const b = await send('/auth/signup', { username: 'note_bob', password: 'bob-safe-passphrase-123' });
    assert.equal(a.status, 200); assert.equal(b.status, 200);
    const alice = { cookie: a.cookie, csrf: a.body.csrf }, bob = { cookie: b.cookie, csrf: b.body.csrf };
    assert.equal((await call('add', 'Water the plants', alice, { origin: 'https://evil.example' })).status, 403);
    assert.equal((await call('add', '', alice)).status, 400);
    assert.equal((await call('add', 'x'.repeat(121), alice)).status, 400);
    const added = await call('add', 'Water the plants', alice);
    assert.equal(added.status, 200); assert.equal(added.body.tag, 'success');
    assert.equal(added.body.value.title, 'Water the plants'); assert.match(added.body.value.id, /^[0-9a-f]{64}$/);
    assert.deepEqual((await call('list', null, bob)).body.value, []);
    await stop(); await start();
    assert.deepEqual((await call('list', null, alice)).body.value, [added.body.value]);
    assert.ok(!logs.includes('safe-passphrase')); assert.ok(!logs.includes(alice.cookie));
  } finally { await stop(); console.log(`Fixture retained: ${directory}`); }
});
