import test from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { createConnection } from 'node:net';
import { mkdtemp, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { resolve } from 'node:path';
import { createGateway, literalPath } from '../../engine/gateway/index.mjs';
import { startStub, freePort, operation } from './stub.mjs';

const json = { 'x-leanapp-request': '1', 'content-type': 'application/json' };
async function gateway(stub, config = {}) {
  const port = await freePort(), origin = `http://127.0.0.1:${port}`;
  const handle = await createGateway({ port, origin, development: true, log: 'silent', signals: false, exit: false,
    backend: { attach: { url: stub.url }, readyAttempts: 20 }, ...config });
  const call = (path, init = {}) => fetch(origin + path, init);
  const post = (path, body = '{}', headers = {}) => call(path, { method: 'POST', headers: { ...json, origin, ...headers }, body });
  // Raw requests bypass fetch's URL normalisation and header merging; resolves with the status code.
  const raw = request => new Promise((done, fail) => {
    const socket = createConnection(port, '127.0.0.1'); let data = '';
    socket.on('connect', () => socket.write(request)); socket.on('error', fail);
    socket.on('data', b => { data += b; const status = data.match(/^HTTP\/1\.1 (\d{3})/); if (status) { socket.destroy(); done(Number(status[1])); } });
    socket.on('close', () => fail(new Error(`no status line in ${JSON.stringify(data)}`)));
  });
  return { handle, port, origin, call, post, raw };
}
const until = async (predicate, ms = 2000) => { const t = Date.now(); while (!predicate()) { if (Date.now() - t > ms) throw new Error('condition not met'); await new Promise(r => setTimeout(r, 10)); } };

test('literal path rule mirrors HttpBinding.validate', () => {
  for (const ok of ['/', '/api/x', '/api/things-2/save_v1.json']) assert.ok(literalPath(ok), ok);
  for (const bad of ['', 'api/x', '/api/x/', '/api//x', '/api/./x', '/api/../x', '/api/x?y', '/api/ü', '/api/x y', 42, null])
    assert.ok(!literalPath(bad), String(bad));
});

test('allowlist comes from the manifest: listed paths proxy, unlisted paths 404 before the backend, extras add prefixes and literals', async () => {
  const stub = await startStub({ manifest: { operations: [operation('/api/things/save')] } });
  const g = await gateway(stub, { routes: { fromManifest: true, extra: ['/auth/*', '/api/echo'] } });
  try {
    assert.deepEqual([...g.handle.routes.paths].sort(), ['/api/echo', '/api/manifest', '/api/things/save', '/health/ready']);
    assert.deepEqual(g.handle.routes.prefixes, ['/auth/']);
    assert.equal((await g.post('/api/things/save')).status, 200);
    assert.equal((await g.post('/auth/login')).status, 200);
    assert.equal((await g.call('/api/manifest', { headers: json })).status, 200);
    assert.equal((await g.call('/health/ready')).status, 200);
    const before = stub.hits.length;
    for (const path of ['/api/things/delete', '/api/things/save/', '/auth/x?y=1', '/api', '/stub/hits'])
      assert.equal((await g.post(path)).status, 404, path);
    for (const path of ['/auth/../api/things/save', '/auth//x', '/auth/./x', '/auth/%2e%2e/x', '/api/things/save?x=1'])
      assert.equal(await g.raw(`GET ${path} HTTP/1.1\r\nHost: x\r\nX-LeanApp-Request: 1\r\nConnection: close\r\n\r\n`), 404, path);
    assert.equal((await g.call('/api/things/save', { method: 'PUT', headers: json })).status, 404);
    assert.equal((await g.call('/api/things/save', { method: 'DELETE', headers: json })).status, 404);
    assert.equal(stub.hits.length, before, 'unlisted paths never reach the backend');
  } finally { await g.handle.stop(); await stub.close(); }
});

test('a new manifest operation is proxied without a gateway change', async () => {
  const stub = await startStub({ manifest: { operations: [operation('/api/things/save'), operation('/api/things/archive')] } });
  const g = await gateway(stub, { routes: { fromManifest: true, extra: [] } });
  try {
    assert.equal((await g.post('/api/things/archive')).status, 200);
    assert.equal(stub.hits.at(-1).url, '/api/things/archive');
  } finally { await g.handle.stop(); await stub.close(); }
});

test('startup refuses an invalid manifest path, a malformed manifest and an unreachable manifest', async () => {
  for (const [manifest, message] of [[{ operations: [operation('/api/../x')] }, /manifest path rejected/],
    [{ operations: [operation('/api/x', { http: { maxBodyBytes: 0 } })] }, /body cap rejected/],
    [{ nope: true }, /manifest malformed/]]) {
    const stub = await startStub({ manifest });
    try { await assert.rejects(gateway(stub), message); } finally { await stub.close(); }
  }
  const stub = await startStub();
  try { await assert.rejects(gateway(stub, { routes: { fromManifest: true, manifestPath: '/api/reply/404' } }), /manifest unreachable/); }
  finally { await stub.close(); }
  await assert.rejects(gateway({ url: `http://127.0.0.1:${await freePort()}` }), /did not become ready/);
});

test('fromManifest: false keeps only the configured routes', async () => {
  const stub = await startStub({ manifest: { operations: [operation('/api/things/save')] } });
  const g = await gateway(stub, { routes: { fromManifest: false, extra: ['/api/echo'] } });
  try {
    assert.equal(g.handle.manifest, null);
    assert.equal((await g.post('/api/things/save')).status, 404);
    assert.equal((await g.post('/api/echo')).status, 200);
  } finally { await g.handle.stop(); await stub.close(); }
});

test('operations without http.path are tolerated with one warning and routes.extra carries the allowlist', async () => {
  const legacy = { ...operation('/api/legacy/save') }; delete legacy.http;
  const stub = await startStub({ manifest: { operations: [legacy, legacy] } });
  const lines = [];
  const g = await gateway(stub, { log: line => lines.push(line), routes: { fromManifest: true, extra: ['/api/legacy/save'] } });
  try {
    assert.equal(lines.filter(l => l.event === 'manifest_unbound_operations').length, 1);
    assert.equal(lines.find(l => l.event === 'manifest_unbound_operations').count, 2);
    assert.equal((await g.post('/api/legacy/save')).status, 200);
  } finally { await g.handle.stop(); await stub.close(); }
});

test('header gates: duplicates, X-LeanApp-Request, Origin and content type, each positive and negative', async () => {
  const stub = await startStub({ manifest: { operations: [operation('/api/things/save')] } });
  const g = await gateway(stub, { routes: { extra: ['/api/echo'] } });
  try {
    const dupe = header => g.raw(`POST /api/things/save HTTP/1.1\r\nHost: x\r\nOrigin: ${g.origin}\r\nContent-Type: application/json\r\nX-LeanApp-Request: 1\r\n${header}\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}`);
    assert.equal(await dupe(`Cookie: a=1\r\nCookie: b=2`), 400);
    assert.equal(await dupe(`Origin: ${g.origin}`), 400);
    assert.equal(await dupe(`X-LeanApp-Request: 1`), 400);
    assert.equal(await dupe(`Accept: */*\r\nAccept: text/plain`), 400);
    assert.equal(await dupe(`X-Other: 1\r\nX-Other: 2`), 200, 'duplicates outside the forwarded list are not the gateway\'s concern');
    assert.equal((await g.call('/api/things/save', { method: 'POST', headers: { origin: g.origin, 'content-type': 'application/json' }, body: '{}' })).status, 403);
    assert.equal((await g.call('/api/things/save', { method: 'POST', headers: { ...json, origin: g.origin, 'x-leanapp-request': '2' }, body: '{}' })).status, 403);
    assert.equal((await g.call('/api/echo', { headers: { accept: 'application/json' } })).status, 403);
    assert.equal((await g.call('/api/echo', { headers: json })).status, 200, 'GET needs only the custom header');
    assert.equal((await g.post('/api/things/save', '{}', { origin: 'https://evil.example' })).status, 403);
    assert.equal((await g.call('/api/things/save', { method: 'POST', headers: json, body: '{}' })).status, 403, 'POST without Origin');
    assert.equal((await g.post('/api/things/save', '{}', { 'content-type': 'text/plain' })).status, 403);
    assert.equal((await g.post('/api/things/save', '{}', { 'content-type': 'application/json; charset=utf-8' })).status, 200);
    assert.equal((await g.post('/api/things/save', '{}', { 'content-type': 'Application/JSON' })).status, 200);
    const forbidden = await g.post('/api/things/save', '{}', { origin: 'https://evil.example' });
    assert.equal(forbidden.headers.get('content-type'), 'application/json');
    assert.deepEqual(await forbidden.json(), { error: 'auth.forbidden' });
    assert.equal((await g.call('/health/ready')).status, 200, 'readiness needs no headers');
  } finally { await g.handle.stop(); await stub.close(); }
});

test('forwarded and returned header lists, security headers and HSTS only outside development', async () => {
  const stub = await startStub();
  const g = await gateway(stub, { routes: { extra: ['/api/echo'] } });
  try {
    const reply = await g.call('/api/echo', { headers: { ...json, cookie: 'leanapp_session=abc', 'x-csrf-token': 't', accept: 'application/json',
      'x-forwarded-for': '1.2.3.4', authorization: 'Bearer nope' } });
    const echoed = (await reply.json()).headers;
    assert.equal(echoed.cookie, 'leanapp_session=abc'); assert.equal(echoed['x-csrf-token'], 't'); assert.equal(echoed.accept, 'application/json');
    assert.equal(echoed['x-forwarded-for'], undefined); assert.equal(echoed.authorization, undefined);
    assert.equal(echoed['content-length'], '0');
    assert.equal(reply.headers.get('set-cookie'), 'leanapp_session=x; Path=/; HttpOnly');
    assert.equal(reply.headers.get('retry-after'), '5'); assert.equal(reply.headers.get('x-private'), null);
    for (const [k, v] of [['cache-control', 'no-store'], ['x-content-type-options', 'nosniff'], ['referrer-policy', 'no-referrer'], ['x-frame-options', 'DENY']])
      assert.equal(reply.headers.get(k), v, k);
    assert.match(reply.headers.get('content-security-policy'), /^default-src 'self'/);
    assert.equal(reply.headers.get('strict-transport-security'), null);
    assert.equal((await g.call('/nope')).headers.get('x-frame-options'), 'DENY', 'security headers on gateway replies too');
  } finally { await g.handle.stop(); }
  const production = await gateway(stub, { development: false, host: '127.0.0.1', routes: { extra: ['/api/echo'] }, headers: { csp: "default-src 'none'" } });
  try {
    const reply = await production.call('/health/ready');
    assert.equal(reply.headers.get('strict-transport-security'), 'max-age=31536000');
    assert.equal(reply.headers.get('content-security-policy'), "default-src 'none'");
  } finally { await production.handle.stop(); await stub.close(); }
});

test('static assets, HEAD, and SPA fallback', async () => {
  const stub = await startStub();
  const dir = await mkdtemp(resolve(tmpdir(), 'gateway-assets-'));
  await writeFile(resolve(dir, 'index.html'), '<h1>hi</h1>'); await writeFile(resolve(dir, 'main.js'), 'x'); await writeFile(resolve(dir, 'style.css'), 'y');
  const g = await gateway(stub, { assets: { dir } });
  try {
    const index = await g.call('/'); assert.equal(index.status, 200);
    assert.equal(index.headers.get('content-type'), 'text/html; charset=utf-8'); assert.equal(await index.text(), '<h1>hi</h1>');
    assert.equal((await g.call('/main.js')).headers.get('content-type'), 'text/javascript; charset=utf-8');
    const head = await g.call('/style.css', { method: 'HEAD' }); assert.equal(head.status, 200); assert.equal(await head.text(), '');
    assert.equal((await g.call('/', { method: 'POST' })).status, 404);
    assert.equal((await g.call('/docs/thing')).status, 404);
  } finally { await g.handle.stop(); }
  const spa = await gateway(stub, { assets: { dir, spa: true } });
  try {
    assert.equal(await (await spa.call('/docs/thing')).text(), '<h1>hi</h1>');
    assert.equal((await spa.call('/docs/thing.png')).status, 404);
    assert.equal((await spa.call('/docs/thing', { method: 'POST' })).status, 404);
  } finally { await spa.handle.stop(); await stub.close(); }
});

test('body caps: default, per-route override, and manifest caps win over config', async () => {
  const stub = await startStub({ manifest: { operations: [operation('/api/small'), operation('/api/big', { http: { maxBodyBytes: 64 } })] } });
  const g = await gateway(stub, { routes: { extra: ['/api/echo', '/api/cfg'], bodyBytes: { default: 16, '/api/cfg': 32, '/api/big': 8 } } });
  try {
    assert.equal(g.handle.routes.caps.get('/api/big'), 64);
    assert.equal((await g.post('/api/small', '{'.padEnd(16, ' '))).status, 200);
    const over = await g.post('/api/small', '{'.padEnd(17, ' '));
    assert.equal(over.status, 413); assert.equal(over.headers.get('connection'), 'close');
    assert.equal((await g.post('/api/cfg', '{'.padEnd(32, ' '))).status, 200);
    assert.equal((await g.post('/api/cfg', '{'.padEnd(33, ' '))).status, 413);
    assert.equal((await g.post('/api/big', '{'.padEnd(64, ' '))).status, 200);
    assert.equal((await g.post('/api/big', '{'.padEnd(65, ' '))).status, 413);
    assert.equal((await g.post('/api/echo', '{"a":1}')).status, 200);
    assert.equal(stub.hits.at(-1).headers['content-length'], '7');
  } finally { await g.handle.stop(); await stub.close(); }
});

test('in-flight cap answers 429 with retry-after, releases on completion, and never gates readiness', async () => {
  const stub = await startStub({ manifest: { operations: [operation('/api/hang')] } });
  const g = await gateway(stub, { limits: { inFlight: 2 } });
  try {
    const hung = [g.post('/api/hang'), g.post('/api/hang')];
    await until(() => stub.hits.filter(h => h.url === '/api/hang').length === 2);
    const throttled = await g.post('/api/hang');
    assert.equal(throttled.status, 429); assert.equal(throttled.headers.get('retry-after'), '60');
    assert.deepEqual(await throttled.json(), { error: 'auth.throttled' });
    assert.equal(stub.hits.filter(h => h.url === '/api/hang').length, 2, 'the throttled request never reached the backend');
    assert.equal((await g.call('/health/ready')).status, 200);
    stub.release();
    for (const reply of await Promise.all(hung)) assert.equal(reply.status, 200);
    const next = g.post('/api/hang');
    await until(() => stub.hits.filter(h => h.url === '/api/hang').length === 3);
    stub.release(); assert.equal((await next).status, 200, 'slots are released when exchanges complete');
  } finally { stub.release(); await g.handle.stop(); await stub.close(); }
});

test('upstream failures: 502 when the backend is gone, statuses and hooks otherwise', async () => {
  const stub = await startStub({ manifest: { operations: [operation('/api/things/save'), operation('/api/reply/422')] } });
  const seen = [];
  const g = await gateway(stub, { hooks: { onProxied: (req, reply) => seen.push({ path: req.url, status: reply.status, body: JSON.parse(reply.body) }) } });
  try {
    assert.equal((await g.post('/api/reply/422')).status, 422);
    assert.equal((await g.post('/api/things/save')).status, 200);
    assert.deepEqual(seen.map(s => [s.path, s.status, s.body.tag]), [['/api/reply/422', 422, 'domainError'], ['/api/things/save', 200, 'success']]);
    await stub.close();
    assert.equal((await g.post('/api/things/save')).status, 502);
  } finally { await g.handle.stop(); }
});

test('SIGTERM drains: admission stops, active exchange completes, listener closes, child is terminated, exit 0', { timeout: 20000 }, async () => {
  const port = await freePort(), backend = await freePort(), origin = `http://127.0.0.1:${port}`;
  const child = spawn(process.execPath, ['tests/gateway/run.mjs'], { stdio: ['ignore', 'pipe', 'pipe'], env: { ...process.env, STUB_HANG_MS: '1500',
    GATEWAY_CONFIG: JSON.stringify({ port, origin, development: true, drainMs: 6000, log: 'json', routes: { extra: ['/api/hang'] },
      backend: { binary: process.execPath, args: ['tests/gateway/stub.mjs'], port: backend, env: { STUB_HANG_MS: '1500' } } }) } });
  let logs = ''; child.stdout.on('data', b => logs += b); child.stderr.on('data', b => logs += b);
  try {
    for (let n = 0; n < 100; n++) {
      if (child.exitCode !== null) throw new Error(logs);
      try { if ((await fetch(origin + '/health/ready')).ok) break; } catch {}
      await new Promise(r => setTimeout(r, 50));
    }
    const slow = fetch(origin + '/api/hang', { method: 'POST', headers: { ...json, origin }, body: '{}' });
    await new Promise(r => setTimeout(r, 200));
    const start = Date.now(); child.kill('SIGTERM');
    await new Promise(r => setTimeout(r, 100));
    let refused = false;
    try { refused = (await fetch(origin + '/health/ready')).status === 503; } catch { refused = true; }
    assert.ok(refused, 'no new admission during drain');
    assert.equal((await slow).status, 200, 'the active exchange completes');
    const [code] = await once(child, 'exit');
    assert.equal(code, 0); assert.ok(Date.now() - start < 5000, `drained in ${Date.now() - start} ms, before the deadline`);
    assert.ok(logs.includes('"event":"listening"'));
  } finally { if (child.exitCode === null) child.kill('SIGKILL'); }
});

test('drain deadline force-closes a stuck exchange and SIGKILLs a child that ignores SIGTERM', { timeout: 20000 }, async () => {
  const port = await freePort(), backend = await freePort(), origin = `http://127.0.0.1:${port}`;
  const child = spawn(process.execPath, ['tests/gateway/run.mjs'], { stdio: ['ignore', 'pipe', 'pipe'], env: { ...process.env,
    GATEWAY_CONFIG: JSON.stringify({ port, origin, development: true, drainMs: 1000, log: 'silent', routes: { extra: ['/api/hang'] }, limits: { upstreamTimeoutMs: 30000 },
      backend: { binary: process.execPath, args: ['-e', `process.on('SIGTERM', () => {}); import('${resolve('tests/gateway/stub.mjs').replace(/\\/g, '/')}').then(m => m.startStub({ port: ${backend}, hangMs: 60000 }))`], port: backend } }) } });
  let logs = ''; child.stdout.on('data', b => logs += b); child.stderr.on('data', b => logs += b);
  try {
    for (let n = 0; n < 100; n++) {
      if (child.exitCode !== null) throw new Error(logs);
      try { if ((await fetch(origin + '/health/ready')).ok) break; } catch {}
      await new Promise(r => setTimeout(r, 50));
    }
    const stuck = fetch(origin + '/api/hang', { method: 'POST', headers: { ...json, origin }, body: '{}' }).catch(error => error);
    await new Promise(r => setTimeout(r, 200));
    const start = Date.now(); child.kill('SIGTERM');
    const [code] = await once(child, 'exit');
    const elapsed = Date.now() - start;
    assert.equal(code, 0); assert.ok(elapsed >= 900 && elapsed < 4000, `forced close at the deadline (${elapsed} ms)`);
    assert.ok((await stuck) instanceof Error, 'the stuck exchange was cut');
  } finally { if (child.exitCode === null) child.kill('SIGKILL'); }
});

test('backend exit propagates its code through the gateway process', { timeout: 20000 }, async () => {
  const port = await freePort(), backend = await freePort(), origin = `http://127.0.0.1:${port}`;
  const child = spawn(process.execPath, ['tests/gateway/run.mjs'], { stdio: ['ignore', 'pipe', 'pipe'], env: { ...process.env,
    GATEWAY_CONFIG: JSON.stringify({ port, origin, development: true, log: 'json', routes: { extra: ['/api/crash'] },
      backend: { binary: 'tests/gateway/stub.mjs', port: backend } }) } });
  let logs = ''; child.stdout.on('data', b => logs += b); child.stderr.on('data', b => logs += b);
  try {
    for (let n = 0; n < 100; n++) {
      if (child.exitCode !== null) throw new Error(logs);
      try { if ((await fetch(origin + '/health/ready')).ok) break; } catch {}
      await new Promise(r => setTimeout(r, 50));
    }
    const exited = once(child, 'exit');
    assert.equal((await fetch(origin + '/api/crash', { method: 'POST', headers: { ...json, origin }, body: '{}' })).status, 502);
    const [code] = await exited;
    assert.equal(code, 7); assert.ok(logs.includes('"event":"backend_exit"'));
  } finally { if (child.exitCode === null) child.kill('SIGKILL'); }
});

test('a missing binary or a port collision fails startup cleanly', async () => {
  const port = await freePort();
  await assert.rejects(createGateway({ port, origin: `http://127.0.0.1:${port}`, development: true, log: 'silent', signals: false, exit: false,
    backend: { binary: '/nonexistent/leanapp', port } }), /distinct port/);
  await assert.rejects(createGateway({ port, origin: `http://127.0.0.1:${port}`, development: true, log: 'silent', signals: false, exit: false,
    backend: { binary: '/nonexistent/leanapp', port: await freePort() } }), /did not become ready/);
  await assert.rejects(createGateway({ port, origin: 'http://127.0.0.1:1/x', development: true, log: 'silent', signals: false, exit: false,
    backend: { attach: { url: 'http://127.0.0.1:1' } } }), /exact http\(s\) origin/);
  await assert.rejects(createGateway({ port, origin: `http://127.0.0.1:${port}`, development: true, log: 'silent', signals: false, exit: false,
    backend: { attach: { url: 'http://example.com:80' } } }), /loopback/);
});
