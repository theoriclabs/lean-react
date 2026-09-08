import test from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { createServer } from 'node:net';
import { mkdtemp } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { resolve } from 'node:path';

test('private notes: real HTTP scope, fixture ownership, query parity, restart and session revocation', { timeout: 90000 }, async () => {
  const probe = createServer(); probe.listen(0, '127.0.0.1'); await once(probe, 'listening');
  const port = probe.address().port; await new Promise(r => probe.close(r));
  const origin = `http://127.0.0.1:${port}`, directory = await mkdtemp(resolve(tmpdir(), 'leanapp-notes-http-'));
  let child, logs = '';
  const start = async () => {
    child = spawn(resolve('adapters/native/.lake/build/bin/leanapp_notes'), [], { stdio: ['ignore', 'pipe', 'pipe'], env: {
      ...process.env, LEANAPP_DEVELOPMENT: '1', LEANAPP_ORIGIN: origin, LEANAPP_BACKEND_PORT: String(port),
      LEANAPP_DB_PATH: resolve(directory, 'notes.sqlite') } });
    child.stdout.on('data', b => logs += b); child.stderr.on('data', b => logs += b);
    for (let n = 0; n < 250; n++) {
      if (child.exitCode !== null) throw new Error(`Backend exited: ${logs}`);
      try { if ((await fetch(origin + '/health/ready')).ok) return; } catch {}
      await new Promise(r => setTimeout(r, 50));
    }
    throw new Error('Backend did not become ready');
  };
  const stop = async () => { if (child?.exitCode === null && child.signalCode === null) {
    const ended = once(child, 'exit'); child.kill('SIGTERM'); await ended;
  } };
  const send = async (path, body, session, extra = {}) => {
    const response = await fetch(origin + path, { method: 'POST', headers: { origin,
      'content-type': 'application/json', 'x-leanapp-request': '1',
      ...(session ? { cookie: session.cookie, 'x-csrf-token': session.csrf } : {}), ...extra }, body: JSON.stringify(body) });
    return { status: response.status, body: await response.json(), cookie: response.headers.get('set-cookie')?.split(';')[0] };
  };
  const criteria = { search: '', id: null, offset: '0', limit: '50' };
  const call = (name, session, input = criteria, extra) => send(`/api/notes/${name}`, {
    operation: { namespace: 'notes', name, version: '1' }, kind: name === 'lab' ? 'command' : 'query',
    input: name === 'lab' ? null : input,
  }, session, extra);
  try {
    await start(); assert.equal((await call('list')).status, 401);
    const a = await send('/auth/signup', { username: 'notes_alice', password: 'notes-alice-safe-passphrase' });
    const b = await send('/auth/signup', { username: 'notes_bob', password: 'notes-bob-safe-passphrase' });
    assert.equal(a.status, 200); assert.equal(b.status, 200);
    const alice = { cookie: a.cookie, csrf: a.body.csrf }, bob = { cookie: b.cookie, csrf: b.body.csrf };
    assert.equal((await call('list', alice, criteria, { origin: 'https://foreign.example' })).status, 403);
    assert.equal((await call('list', alice, criteria, { 'x-csrf-token': '' })).status, 401);
    assert.equal((await call('list', alice, { ...criteria, owner: b.body.user.actor })).status, 400);
    const lab = await call('lab', alice); assert.equal(lab.status, 200);
    assert.deepEqual((await call('lab', alice)).body, lab.body);
    await call('lab', bob);
    const own = await call('list', alice); assert.equal(own.status, 200);
    assert.equal(own.body.value.count, '2'); assert.equal(own.body.value.notes.length, 2);
    assert.deepEqual(own.body.value.notes.map(n => n.title), ['Launch budget', 'Garden notes']);
    const other = await call('list', bob); assert.equal(other.body.value.notes.length, 2);
    const missing = await call('lookup', alice, { ...criteria, id: '9223372036854775807' });
    assert.equal(missing.status, 404);
    for (const id of [lab.body.value.foreignId, lab.body.value.archiveId, other.body.value.notes[0].id]) {
      const denied = await call('lookup', alice, { ...criteria, id });
      assert.equal(denied.status, 404); assert.deepEqual(denied.body, missing.body);
    }
    assert.equal((await call('lookup', alice, { ...criteria, id: own.body.value.notes[0].id })).status, 200);
    assert.equal((await call('search', alice, { ...criteria, search: 'budget' })).body.value.count, '1');
    assert.equal((await call('count', alice, { ...criteria, search: 'budget' })).body.value.count, '1');
    for (const search of ["' OR 1=1 --", '%', '_', '\"', '🌱'])
      assert.equal((await call('search', alice, { ...criteria, search })).body.value.count, '0');
    const page = await call('list', alice, { ...criteria, offset: '1', limit: '1' });
    assert.equal(page.body.value.notes[0].title, 'Garden notes'); assert.equal(page.body.value.count, '2');
    assert.deepEqual((await call('export', alice)).body.value, own.body.value);
    assert.ok(!JSON.stringify(own.body).includes('CANARY'));
    await stop(); await start();
    assert.deepEqual((await call('list', alice)).body, own.body);
    assert.deepEqual((await call('lab', alice)).body, lab.body);
    const login = await send('/auth/login', { username: 'notes_alice', password: 'notes-alice-safe-passphrase' });
    assert.equal(login.status, 200); assert.equal((await call('list', alice)).status, 401);
    const next = { cookie: login.cookie, csrf: login.body.csrf };
    assert.deepEqual((await call('list', next)).body, own.body);
    assert.equal((await send('/auth/logout', {}, next)).status, 200);
    assert.equal((await call('export', next)).status, 401);
    assert.ok(!logs.includes('safe-passphrase')); assert.ok(!logs.includes(alice.cookie));
  } finally { await stop(); console.log(`Notes fixture retained: ${directory}`); }
});
