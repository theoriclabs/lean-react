import test from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { createGateway } from '../../engine/gateway/index.mjs';
import { isLoopback } from '../../engine/gateway/metrics.mjs';
import { startStub, freePort, operation } from './stub.mjs';

const json = { 'x-leanapp-request': '1', 'content-type': 'application/json' };
const requestFields = ['v', 'ts', 'requestId', 'method', 'path', 'status', 'upstreamStatus', 'durations', 'bytes', 'streamEventsPublished'];
async function gateway(stub, config = {}) {
  const port = await freePort(), origin = `http://127.0.0.1:${port}`;
  const lines = [];
  const handle = await createGateway({ port, origin, development: true, log: line => lines.push(line), signals: false, exit: false,
    backend: { attach: { url: stub.url }, readyAttempts: 20 }, routes: { extra: ['/api/echo'] }, ...config });
  const call = (path, init = {}) => fetch(origin + path, init);
  const post = (path, body = '{}', headers = {}) => call(path, { method: 'POST', headers: { ...json, origin, ...headers }, body });
  const settled = () => new Promise(r => setTimeout(r, 20));
  return { handle, port, origin, lines, call, post, settled };
}

test('isLoopback accepts only loopback peers', () => {
  for (const ok of ['127.0.0.1', '::1', '::ffff:127.0.0.1']) assert.ok(isLoopback(ok));
  for (const bad of ['10.0.0.1', '127.0.0.2', '::2', undefined, '']) assert.ok(!isLoopback(bad));
});

test('one JSON line per request with the versioned field set; request ids are generated, forwarded and returned', async () => {
  const stub = await startStub({ manifest: { operations: [operation('/api/things/save')] } });
  const g = await gateway(stub);
  try {
    const echo = await g.call('/api/echo', { headers: { ...json, cookie: 'leanapp_session=SESSIONVALUE' } });
    const id = echo.headers.get('x-request-id');
    assert.match(id, /^[A-Za-z0-9_-]{1,64}$/);
    assert.equal((await echo.json()).headers['x-request-id'], id, 'forwarded upstream');
    assert.equal((await g.post('/api/things/save', '{"body":"PRIVATEBODY"}', { cookie: 'leanapp_session=SESSIONVALUE' })).status, 200);
    assert.equal((await g.post('/api/things/save', '{}', { origin: 'https://evil.example' })).status, 403);
    assert.equal((await g.call('/nope?tail=secret')).status, 404);
    const spoofed = await g.call('/api/echo', { headers: { ...json, 'x-request-id': 'client-chosen' } });
    assert.notEqual(spoofed.headers.get('x-request-id'), 'client-chosen', 'client ids are never trusted');
    assert.equal((await spoofed.json()).headers['x-request-id'], spoofed.headers.get('x-request-id'));
    await g.settled();
    const requests = g.lines.filter(l => l.requestId);
    assert.equal(requests.length, 5);
    for (const line of requests) {
      assert.deepEqual(Object.keys(line).sort(), [...requestFields].sort());
      assert.equal(line.v, 1); assert.ok(!Number.isNaN(Date.parse(line.ts)));
      assert.deepEqual(Object.keys(line.durations), ['total', 'upstream']); assert.deepEqual(Object.keys(line.bytes), ['in', 'out']);
      assert.ok(line.durations.total >= 0); assert.ok(line.bytes.out > 0);
    }
    const first = requests.find(l => l.requestId === id);
    assert.equal(first.path, '/api/echo'); assert.equal(first.status, 200); assert.equal(first.upstreamStatus, 200);
    assert.ok(first.durations.upstream >= 0 && first.durations.upstream <= first.durations.total);
    const saved = requests[1];
    assert.equal(saved.bytes.in, 22); assert.equal(saved.method, 'POST');
    const forbidden = requests[2]; assert.equal(forbidden.status, 403); assert.equal(forbidden.upstreamStatus, null); assert.equal(forbidden.durations.upstream, null);
    assert.equal(requests[3].status, 404); assert.equal(requests[3].path, '/nope', 'query strings are not logged');
    const text = JSON.stringify(g.lines);
    for (const secret of ['SESSIONVALUE', 'PRIVATEBODY', 'cookie', 'secret', 'client-chosen']) assert.ok(!text.includes(secret), `${secret} leaked into logs`);
  } finally { await g.handle.stop(); await stub.close(); }
});

test('stdout carries the same lines as JSON, one per request, without cookie values', { timeout: 20000 }, async () => {
  const port = await freePort(), backend = await freePort(), origin = `http://127.0.0.1:${port}`;
  const child = spawn(process.execPath, ['tests/gateway/run.mjs'], { stdio: ['ignore', 'pipe', 'pipe'], env: { ...process.env,
    GATEWAY_CONFIG: JSON.stringify({ port, origin, development: true, log: 'json', routes: { extra: ['/api/echo'] },
      backend: { binary: 'tests/gateway/stub.mjs', port: backend } }) } });
  let out = '', err = ''; child.stdout.on('data', b => out += b); child.stderr.on('data', b => err += b);
  try {
    for (let n = 0; n < 100; n++) {
      if (child.exitCode !== null) throw new Error(out + err);
      try { if ((await fetch(origin + '/health/ready')).ok) break; } catch {}
      await new Promise(r => setTimeout(r, 50));
    }
    await (await fetch(origin + '/api/echo', { headers: { ...json, cookie: 'leanapp_session=STDOUTSECRET' } })).text();
    await (await fetch(origin + '/api/echo')).text();
    const exited = once(child, 'exit'); child.kill('SIGTERM'); await exited;
    const lines = out.trim().split('\n').map(line => JSON.parse(line));
    assert.ok(lines.every(l => l.v === 1 && typeof l.ts === 'string'));
    const requests = lines.filter(l => l.requestId);
    assert.deepEqual(requests.map(l => [l.path, l.status]), [['/health/ready', 200], ['/api/echo', 200], ['/api/echo', 403]]);
    for (const line of requests) assert.deepEqual(Object.keys(line).sort(), [...requestFields].sort());
    assert.ok(!out.includes('STDOUTSECRET')); assert.ok(!out.toLowerCase().includes('cookie'));
    assert.ok(lines.some(l => l.event === 'listening'));
  } finally { if (child.exitCode === null) child.kill('SIGKILL'); }
});

test('/internal/metrics serves the gateway counters to loopback in Prometheus text format; /internal/* is never proxied', async () => {
  const stub = await startStub({ manifest: { operations: [operation('/api/hang'), operation('/internal/leaked')] } });
  const g = await gateway(stub, { limits: { inFlight: 1 }, routes: { extra: ['/api/echo', '/internal/*'] } });
  try {
    assert.equal((await g.call('/api/echo', { headers: json })).status, 200);
    assert.equal((await g.call('/api/echo')).status, 403);
    assert.equal((await g.call('/missing')).status, 404);
    const hung = g.post('/api/hang');
    while (!stub.hits.some(h => h.url === '/api/hang')) await new Promise(r => setTimeout(r, 10));
    assert.equal((await g.post('/api/hang')).status, 429);
    const scrape = await g.call('/internal/metrics');
    assert.equal(scrape.status, 200); assert.match(scrape.headers.get('content-type'), /^text\/plain; version=0\.0\.4/);
    const text = await scrape.text();
    assert.match(text, /^# TYPE leanapp_gateway_in_flight gauge\nleanapp_gateway_in_flight 1$/m);
    assert.match(text, /^leanapp_gateway_requests_total\{status="200"\} 1$/m);
    assert.match(text, /^leanapp_gateway_requests_total\{status="403"\} 1$/m);
    assert.match(text, /^leanapp_gateway_rejected_total\{reason="forbidden"\} 1$/m);
    assert.match(text, /^leanapp_gateway_rejected_total\{reason="throttled"\} 1$/m);
    assert.match(text, /^leanapp_gateway_rejected_total\{reason="not_allowed"\} 1$/m);
    assert.match(text, /^leanapp_gateway_upstream_total\{status="200"\} 1$/m);
    assert.match(text, /^leanapp_gateway_event_loop_lag_ms\{quantile="0.99"\} \d+\.\d+$/m);
    stub.release(); assert.equal((await hung).status, 200);
    const before = stub.hits.length;
    assert.equal((await g.call('/internal/leaked', { headers: json })).status, 404);
    assert.equal((await g.post('/internal/leaked')).status, 404);
    assert.equal((await g.call('/internal/metrics', { method: 'POST', headers: json })).status, 404);
    assert.equal((await g.call('/internal/')).status, 404);
    assert.equal(stub.hits.length, before, '/internal/* never reaches the backend');
    assert.match(await (await g.call('/internal/metrics')).text(), /^leanapp_gateway_in_flight 0$/m);
    assert.match(await (await g.call('/internal/metrics')).text(), /^leanapp_gateway_rejected_total\{reason="internal"\} 4$/m);
  } finally { stub.release(); await g.handle.stop(); await stub.close(); }
});
