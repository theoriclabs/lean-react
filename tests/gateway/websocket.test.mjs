import test from 'node:test';
import assert from 'node:assert/strict';
import { createGateway } from '../../engine/gateway/index.mjs';
import { startStub, freePort } from './stub.mjs';
import { startWsEcho, startSilent, wsClient } from './ws-stub.mjs';

async function gateway(stub, config = {}) {
  const port = await freePort(), origin = `http://127.0.0.1:${port}`;
  const lines = [];
  const handle = await createGateway({ port, origin, development: true, log: line => lines.push(line), signals: false, exit: false, drainMs: 1000,
    backend: { attach: { url: stub.url }, readyAttempts: 20 }, ...config });
  return { handle, port, origin, lines, client: options => wsClient(port, { origin, ...options }),
    metrics: async () => (await fetch(`${origin}/internal/metrics`)).text(), settled: () => new Promise(r => setTimeout(r, 30)) };
}

test('a valid upgrade is piped end to end: the echo frame round-trips and only the forwarded headers reach the backend', async () => {
  const stub = await startStub(), echo = await startWsEcho();
  const g = await gateway(stub, { websocket: { backendPort: echo.port } });
  try {
    const ws = await g.client({ cookie: 'other=1; leanapp_session=abc; theme=dark', extra: 'X-Forwarded-For: 1.2.3.4\r\nSec-WebSocket-Extensions: permessage-deflate\r\nAuthorization: nope\r\n' });
    assert.equal(ws.status, 101); assert.equal(ws.headers['sec-websocket-protocol'], 'leanapp.v1'); assert.ok(ws.headers['sec-websocket-accept']);
    ws.send('hello through the gateway');
    assert.deepEqual(await ws.next(), { opcode: 1, text: 'hello through the gateway' });
    ws.send(Buffer.from([1, 2, 3]), 2);
    assert.equal((await ws.next()).opcode, 2);
    const seen = echo.seen[0];
    assert.equal(seen.url, '/ws'); assert.equal(seen.headers.origin, g.origin); assert.equal(seen.headers.cookie, 'other=1; leanapp_session=abc; theme=dark');
    assert.equal(seen.headers['sec-websocket-version'], '13'); assert.equal(seen.headers['sec-websocket-protocol'], 'leanapp.v1');
    assert.equal(seen.headers['sec-websocket-extensions'], 'permessage-deflate'); assert.ok(seen.headers['sec-websocket-key']);
    assert.match(seen.headers['x-request-id'], /^[A-Za-z0-9_-]{16}$/);
    assert.equal(seen.headers['x-forwarded-for'], undefined); assert.equal(seen.headers.authorization, undefined);
    assert.equal(seen.headers.host, `127.0.0.1:${echo.port}`);
    assert.match(await g.metrics(), /^leanapp_gateway_ws_sockets 1$/m);
    ws.send('', 8); await ws.closed; await g.settled();
    const line = g.lines.find(l => l.kind === 'upgrade');
    assert.equal(line.status, 101); assert.equal(line.upstreamStatus, 101); assert.equal(line.reason, 'upstream_closed');
    assert.ok(line.bytes.in > 0 && line.bytes.out > 0); assert.equal(line.requestId, seen.headers['x-request-id']);
    assert.ok(!JSON.stringify(g.lines).includes('abc'), 'cookie values never logged');
    const text = await g.metrics();
    assert.match(text, /^leanapp_gateway_ws_sockets 0$/m); assert.match(text, /^leanapp_gateway_ws_upgrades_total\{outcome="upstream_closed"\} 1$/m);
    assert.match(text, /^leanapp_gateway_ws_bytes_total\{direction="in"\} \d+$/m);
  } finally { await g.handle.stop(); await echo.close(); await stub.close(); }
});

test('upgrade gates: origin, cookie, version, subprotocol, path, method and duplicates, each rejected with a raw 4xx', async () => {
  const stub = await startStub(), echo = await startWsEcho();
  const g = await gateway(stub, { websocket: { backendPort: echo.port } });
  try {
    const expect = async (options, status) => {
      const ws = await g.client(options); assert.equal(ws.status, status, JSON.stringify(options));
      if (status !== 101) { assert.equal(ws.headers.connection, 'close'); await ws.closed; }
      return ws;
    };
    await expect({ origin: 'https://evil.example' }, 403);
    await expect({ origin: null }, 403);
    await expect({ cookie: null }, 401);
    await expect({ cookie: 'theme=dark' }, 401);
    await expect({ cookie: 'leanapp_session=' }, 401);
    const version = await expect({ version: '8' }, 426); assert.equal(version.headers['sec-websocket-version'], '13');
    await expect({ version: null }, 426);
    await expect({ protocol: null }, 400);
    await expect({ protocol: 'chat, other.v2' }, 400);
    await expect({ path: '/ws2' }, 404);
    await expect({ path: '/ws?x=1' }, 101).then(ws => ws.close());
    await expect({ upgrade: 'h2c' }, 400);
    await expect({ extra: `Origin: ${g.origin}\r\n` }, 400);
    await expect({ extra: 'Cookie: leanapp_session=zzz\r\n' }, 400);
    await expect({ cookie: '__Host-leanapp_session=abc', protocol: 'other.v1, leanapp.v1' }, 101).then(ws => ws.close());
    assert.equal(echo.seen.length, 2, 'rejected upgrades never reach the backend');
    await g.settled();
    const outcomes = g.lines.filter(l => l.kind === 'upgrade').map(l => l.reason);
    assert.deepEqual(outcomes.slice(0, 13), ['origin', 'origin', 'cookie', 'cookie', 'cookie', 'version', 'version', 'protocol', 'protocol', 'path', 'client_closed', 'not_websocket', 'duplicate_header']);
    for (const line of g.lines.filter(l => l.kind === 'upgrade')) assert.match(line.requestId, /^[A-Za-z0-9_-]{16}$/);
  } finally { await g.handle.stop(); await echo.close(); await stub.close(); }
});

test('maxPerCookie and maxSockets are enforced with hashed cookie counting that releases on close', async () => {
  const stub = await startStub(), echo = await startWsEcho();
  const g = await gateway(stub, { websocket: { backendPort: echo.port, maxPerCookie: 2, maxSockets: 3 } });
  try {
    const a1 = await g.client({ cookie: 'leanapp_session=alice' }), a2 = await g.client({ cookie: 'leanapp_session=alice' });
    assert.equal(a1.status, 101); assert.equal(a2.status, 101);
    const a3 = await g.client({ cookie: 'leanapp_session=alice' }); assert.equal(a3.status, 429); await a3.closed;
    const b1 = await g.client({ cookie: 'leanapp_session=bob' }); assert.equal(b1.status, 101);
    const c1 = await g.client({ cookie: 'leanapp_session=carol' }); assert.equal(c1.status, 503); await c1.closed;
    await a1.close(); await g.settled();
    const a4 = await g.client({ cookie: 'leanapp_session=alice' }); assert.equal(a4.status, 101);
    assert.ok(!JSON.stringify(g.lines).includes('alice'));
    const text = await g.metrics();
    assert.match(text, /^leanapp_gateway_ws_upgrades_total\{outcome="max_per_cookie"\} 1$/m); assert.match(text, /^leanapp_gateway_ws_upgrades_total\{outcome="max_sockets"\} 1$/m);
    await Promise.all([a2.close(), b1.close(), a4.close()]);
  } finally { await g.handle.stop(); await echo.close(); await stub.close(); }
});

test('backend down → 502, silent backend → 504 after the handshake timeout, idle pipes are cut', async () => {
  const stub = await startStub();
  const down = await gateway(stub, { websocket: { backendPort: await freePort() } });
  try {
    const ws = await down.client(); assert.equal(ws.status, 502); await ws.closed; await down.settled();
    assert.equal(down.lines.find(l => l.kind === 'upgrade').reason, 'upstream_error');
    assert.match(await down.metrics(), /^leanapp_gateway_ws_sockets 0$/m);
  } finally { await down.handle.stop(); }
  const silent = await startSilent();
  const slow = await gateway(stub, { websocket: { backendPort: silent.port, handshakeTimeoutMs: 200 } });
  try {
    const started = Date.now(); const ws = await slow.client();
    assert.equal(ws.status, 504); assert.ok(Date.now() - started >= 150); await ws.closed;
  } finally { await slow.handle.stop(); await silent.close(); }
  const echo = await startWsEcho();
  const idle = await gateway(stub, { websocket: { backendPort: echo.port, idleTimeoutMs: 200 } });
  try {
    const ws = await idle.client(); assert.equal(ws.status, 101);
    const started = Date.now(); await ws.closed;
    assert.ok(Date.now() - started >= 150 && Date.now() - started < 2000); await idle.settled();
    assert.equal(idle.lines.find(l => l.kind === 'upgrade').reason, 'idle');
  } finally { await idle.handle.stop(); await echo.close(); await stub.close(); }
});

test('without websocket config every upgrade request is 404 and HTTP proxying is unchanged', async () => {
  const stub = await startStub();
  const g = await gateway(stub, { routes: { extra: ['/api/echo'] } });
  try {
    const ws = await g.client(); assert.equal(ws.status, 404); await ws.closed;
    assert.equal((await fetch(`${g.origin}/api/echo`, { headers: { 'x-leanapp-request': '1' } })).status, 200);
    await g.settled(); assert.equal(g.lines.find(l => l.kind === 'upgrade').reason, 'no_websocket');
  } finally { await g.handle.stop(); await stub.close(); }
  await assert.rejects(gateway(stub, { websocket: { backendPort: 70000 } }), /websocket.backendPort/);
  await assert.rejects(gateway(stub, { websocket: { backendPort: 1, path: 'ws' } }), /websocket.path/);
});

test('drain: new upgrades are refused first, existing pipes keep flowing and are destroyed at the deadline', async () => {
  const stub = await startStub(), echo = await startWsEcho();
  const g = await gateway(stub, { drainMs: 600, websocket: { backendPort: echo.port } });
  const ws = await g.client(); assert.equal(ws.status, 101);
  const started = Date.now();
  const stopped = g.handle.stop();
  await assert.rejects(g.client(), /closed before response head|ECONNREFUSED/, 'the listener is closed before anything else');
  ws.send('still here'); assert.deepEqual(await ws.next(), { opcode: 1, text: 'still here' }, 'the pipe survives the HTTP drain');
  await ws.closed;
  const elapsed = Date.now() - started;
  assert.ok(elapsed >= 500 && elapsed < 3000, `destroyed at the deadline (${elapsed} ms)`);
  await stopped;
  assert.deepEqual(g.lines.filter(l => l.kind === 'upgrade').map(l => [l.status, l.reason]), [[101, 'drain_deadline']]);
  await echo.close(); await stub.close();
});
