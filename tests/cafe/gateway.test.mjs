import test from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { createServer, createConnection } from 'node:net';
import { mkdtemp } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { resolve } from 'node:path';

async function freePort() {
  const s = createServer(); s.listen(0, '127.0.0.1'); await once(s, 'listening');
  const p = s.address().port; await new Promise(r => s.close(r)); return p;
}
test('rejected anonymous bursts do not burn a global quota; backend crash preserves shutdown deadline', { timeout: 30000 }, async () => {
  const port = await freePort(), backend = await freePort();
  const origin = `http://127.0.0.1:${port}`;
  const fixture = await mkdtemp(resolve(tmpdir(), 'cafe-gateway-'));
  const child = spawn(process.execPath, ['scripts/serve-cafe.mjs'], { stdio: ['ignore', 'pipe', 'pipe'], env: {
    ...process.env, LEANAPP_DEVELOPMENT: '1', PORT: String(port), LEANAPP_BACKEND_PORT: String(backend),
    LEANAPP_ORIGIN: origin, LEANAPP_DB_PATH: resolve(fixture, 'unused.sqlite'),
    LEANAPP_CAFE_BINARY: resolve('tests/cafe/fake-backend.mjs') } });
  let logs = '', slow;
  child.stdout.on('data', b => logs += b); child.stderr.on('data', b => logs += b);
  try {
    let ready = false;
    for (let n = 0; n < 100; n++) {
      if (child.exitCode !== null) throw new Error(logs);
      try { if ((await fetch(origin + '/health/ready')).ok) { ready = true; break; } } catch {}
      await new Promise(r => setTimeout(r, 50));
    }
    assert.ok(ready);
    for (let n = 0; n < 650; n++) {
      const r = await fetch(origin + '/auth/session'); assert.equal(r.status, 403); await r.text();
    }
    const valid = await fetch(origin + '/auth/session', { headers: { 'x-leanapp-request': '1' } });
    assert.equal(valid.status, 200); await valid.text();
    slow = createConnection(port, '127.0.0.1'); slow.on('error', () => {}); slow.on('data', () => {});
    await once(slow, 'connect');
    slow.write(`POST /api/recipes/list HTTP/1.1\r\nHost: 127.0.0.1\r\nOrigin: ${origin}\r\nContent-Type: application/json\r\nX-LeanApp-Request: 1\r\nContent-Length: 8000\r\n\r\n{`);
    const exited = once(child, 'exit');
    const start = Date.now();
    const trigger = await fetch(origin + '/api/recipes/delete', { method: 'POST', headers: {
      origin, 'content-type': 'application/json', 'x-leanapp-request': '1' }, body: '{}' });
    assert.equal(trigger.status, 502); await trigger.text();
    await Promise.race([exited, new Promise((_, reject) => {
      const timer = setTimeout(() => reject(new Error('shutdown exceeded deadline')), 24000); timer.unref();
    })]);
    assert.ok(Date.now() - start < 24000); assert.equal(child.exitCode, 7);
  } finally {
    slow?.destroy();
    if (child.exitCode === null && child.signalCode === null) {
      const exited = once(child, 'exit'); child.kill('SIGTERM');
      const kill = setTimeout(() => child.kill('SIGKILL'), 1000); await exited; clearTimeout(kill);
    }
  }
});
