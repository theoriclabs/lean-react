// Session cache load check: 10k authenticated calls against leanapp_auth_demo with the
// in-process session cache off and on. Prints the wall-time reduction; asserts only correctness.
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { createServer } from 'node:net';
import { mkdtemp } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { resolve } from 'node:path';

const calls = Number(process.env.LEANAPP_AUTH_LOAD_CALLS ?? 10000), concurrency = 16;
const wire = { operation: { namespace: 'auth-demo', name: 'whoami', version: '1' }, kind: 'query', input: null };

async function measure(cacheTtlMs) {
  const probe = createServer(); probe.listen(0, '127.0.0.1'); await once(probe, 'listening');
  const port = probe.address().port; await new Promise(r => probe.close(r));
  const origin = `http://127.0.0.1:${port}`;
  const directory = await mkdtemp(resolve(tmpdir(), 'leanapp-auth-load-'));
  const child = spawn(resolve('adapters/native/.lake/build/bin/leanapp_auth_demo'), [String(port), resolve(directory, 'auth.sqlite'), origin],
    { stdio: ['ignore', 'ignore', 'inherit'], env: { ...process.env, LEANAPP_SESSION_CACHE_TTL_MS: String(cacheTtlMs), LEANAPP_LOG: 'off' } });
  try {
    for (let n = 0; n < 200; n++) {
      if (child.exitCode !== null) throw new Error('auth demo exited');
      try { if ((await fetch(`${origin}/health/ready`)).ok) break; } catch {}
      await new Promise(r => setTimeout(r, 50));
    }
    const headers = { 'x-leanapp-request': '1', 'content-type': 'application/json', origin };
    const signup = await fetch(`${origin}/auth/signup`, { method: 'POST', headers, body: JSON.stringify({ username: 'load_user', password: 'a load check passphrase 🔐' }) });
    assert.equal(signup.status, 200);
    const cookie = signup.headers.get('set-cookie').split(';')[0], csrf = (await signup.json()).csrf;
    const request = async () => {
      const response = await fetch(`${origin}/api/whoami`, { method: 'POST', headers: { ...headers, cookie, 'x-csrf-token': csrf }, body: JSON.stringify(wire) });
      assert.equal(response.status, 200); await response.arrayBuffer();
    };
    for (let n = 0; n < 50; n++) await request(); // warm up connections and the cache
    const started = performance.now();
    let issued = 0;
    await Promise.all(Array.from({ length: concurrency }, async () => { while (issued < calls) { issued++; await request(); } }));
    const elapsed = performance.now() - started;
    let metrics = '';
    try { const scrape = await fetch(`${origin}/internal/metrics`); if (scrape.ok) metrics = await scrape.text(); } catch {}
    return { elapsed, metrics };
  } finally {
    if (child.exitCode === null) { const exit = once(child, 'exit'); child.kill('SIGTERM'); await exit; }
  }
}

const gauge = (metrics, name) => { const m = metrics.match(new RegExp(`^${name}(?:\\{[^}]*\\})? ([0-9.]+)$`, 'm')); return m ? Number(m[1]) : undefined; };
const off = await measure(0), on = await measure(30000);
const reduction = Math.round((1 - on.elapsed / off.elapsed) * 100);
console.log(`Session cache load check: ${calls} authenticated calls, ${concurrency} in flight: ` +
  `cache off ${(off.elapsed / 1000).toFixed(2)}s (${Math.round(calls / off.elapsed * 1000)} req/s), ` +
  `cache on ${(on.elapsed / 1000).toFixed(2)}s (${Math.round(calls / on.elapsed * 1000)} req/s), ${reduction}% less wall time`);
const hits = gauge(on.metrics, 'leanapp_auth_session_cache_hits_total');
const queueOff = gauge(off.metrics, 'leanapp_request_queue_wait_ms_sum'), queueOn = gauge(on.metrics, 'leanapp_request_queue_wait_ms_sum');
const dbOff = gauge(off.metrics, 'leanapp_request_db_ms_sum'), dbOn = gauge(on.metrics, 'leanapp_request_db_ms_sum');
if (hits !== undefined) console.log(`Session cache hits: ${hits}`);
if (queueOff !== undefined && queueOn !== undefined && dbOff !== undefined && dbOn !== undefined)
  console.log(`DB-queue time (wait + held): cache off ${Math.round(queueOff + dbOff)}ms, cache on ${Math.round(queueOn + dbOn)}ms`);
