import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createChannelRuntime, decodeFrame, encodeFrame, reconnectPolicy } from '../../engine/runtime/channels.mjs';

class MockSocket {
  static instances = [];
  constructor(url, protocol) {
    this.url = url;
    this.protocol = protocol;
    this.readyState = 0;
    this.sent = [];
    this.listeners = { open: [], message: [], close: [] };
    MockSocket.instances.push(this);
    queueMicrotask(() => { this.readyState = 1; this.emit('open'); });
  }
  addEventListener(type, fn) { this.listeners[type].push(fn); }
  send(data) { this.sent.push(JSON.parse(data)); }
  close(code = 1000) { this.readyState = 3; this.emit('close', { code }); }
  emit(type, event = {}) { for (const fn of this.listeners[type]) fn(event); }
  peer(frame) { this.emit('message', { data: JSON.stringify(frame) }); }
}

test('one socket is shared and hello precedes subscribe', async () => {
  MockSocket.instances = [];
  const runtime = createChannelRuntime({ WebSocketImpl: MockSocket, csrf: () => 'tok', origin: 'http://127.0.0.1:1' });
  const a = runtime.use({ channel: { namespace: 't', name: 'watch', version: '1' }, params: { scope: 'mine' }, onEvent() {} });
  const b = runtime.use({ channel: { namespace: 't', name: 'watch', version: '1' }, params: { scope: 'mine' }, onEvent() {} });
  await new Promise(r => setTimeout(r, 10));
  assert.equal(MockSocket.instances.length, 1);
  const sent = MockSocket.instances[0].sent;
  assert.equal(sent[0].tag, 'hello');
  assert.equal(sent[0].csrf, 'tok');
  assert.ok(sent.some(f => f.tag === 'subscribe' && f.sub === a.id));
  assert.ok(sent.some(f => f.tag === 'subscribe' && f.sub === b.id));
});

test('seq gap triggers resubscribe; stale generation is ignored', async () => {
  MockSocket.instances = [];
  const events = [];
  const runtime = createChannelRuntime({ WebSocketImpl: MockSocket, csrf: () => 'x', origin: 'http://127.0.0.1:1' });
  const sub = runtime.use({
    channel: { namespace: 't', name: 'watch', version: '1' },
    params: {},
    onEvent: (seq, payload) => events.push([seq, payload]),
  });
  await new Promise(r => setTimeout(r, 10));
  const sock = MockSocket.instances[0];
  sock.peer({ tag: 'event', sub: sub.id, seq: 0, payload: { n: 1 } });
  sock.peer({ tag: 'event', sub: sub.id, seq: 2, payload: { n: 2 } });
  assert.deepEqual(events, [[0, { n: 1 }]]);
  assert.ok(sock.sent.some(f => f.tag === 'subscribe' && f.sub === sub.id));
});

test('frame codec round-trips', () => {
  const frame = { tag: 'hello', protocol: 1, csrf: 'ab' };
  assert.deepEqual(decodeFrame(encodeFrame(frame)), frame);
});

test('attempt-N delays are uniform on [0, min(30s, 2^N s)]', () => {
  const samples = 4000;
  for (const attempt of [0, 1, 3, 5, 10]) {
    const max = Math.min(30000, 1000 * 2 ** Math.min(attempt, 30));
    const delays = Array.from({ length: samples }, (_, i) =>
      reconnectPolicy({ attempt, reason: 1006, random: () => i / samples }));
    assert.equal(Math.min(...delays), 0);
    assert.ok(Math.max(...delays) <= max);
    assert.ok(delays.some(d => d > max * 0.4));
    assert.ok(delays.every(d => d >= 0 && d <= max));
  }
});

test('ordinary drop reconnects within 1s on average', () => {
  let i = 0;
  const n = 2000;
  const delays = Array.from({ length: n }, () =>
    reconnectPolicy({ attempt: 0, reason: 1006, random: () => (i++ + 0.5) / n }));
  const mean = delays.reduce((a, b) => a + b, 0) / n;
  assert.ok(mean < 1000, `mean ${mean}`);
});

test('1001 reconnects spread: p5–p95 spans at least 8s', () => {
  const delays = [];
  const scheduled = [];
  for (let i = 0; i < 1000; i++) {
    MockSocket.instances = [];
    const runtime = createChannelRuntime({
      WebSocketImpl: MockSocket,
      csrf: () => 'x',
      origin: 'http://127.0.0.1:1',
      random: () => (i + 0.5) / 1000,
      setTimeoutFn: (fn, ms) => { scheduled.push(ms); return 0; },
      clearTimeoutFn() {},
    });
    runtime.use({ channel: { namespace: 't', name: 'watch', version: '1' }, params: {}, onEvent() {} });
    const sock = MockSocket.instances[0];
    sock.readyState = 1;
    sock.emit('open');
    sock.close(1001);
    delays.push(scheduled.at(-1));
  }
  const sorted = [...delays].sort((a, b) => a - b);
  const p5 = sorted[Math.floor(sorted.length * 0.05)];
  const p95 = sorted[Math.floor(sorted.length * 0.95)];
  assert.ok(p95 - p5 >= 8000, `p5=${p5} p95=${p95} span=${p95 - p5}`);
  assert.ok(Math.min(...delays) >= 0);
  assert.ok(Math.max(...delays) < 10000);
});

test('background priority resubscribes after live subscriptions', async () => {
  MockSocket.instances = [];
  const timers = [];
  const runtime = createChannelRuntime({
    WebSocketImpl: MockSocket,
    csrf: () => 'x',
    origin: 'http://127.0.0.1:1',
    random: () => 0.5,
    setTimeoutFn: (fn, ms) => { timers.push({ fn, ms }); return timers.length; },
    clearTimeoutFn() {},
  });
  runtime.use({
    channel: { namespace: 'user', name: 'inbox', version: '1' },
    params: {},
    priority: 'background',
    onEvent() {},
  });
  runtime.use({
    channel: { namespace: 'doc', name: 'live', version: '1' },
    params: {},
    onEvent() {},
  });
  await new Promise(r => queueMicrotask(r));
  const sock = MockSocket.instances[0];
  sock.sent.length = 0;
  sock.close(1006);
  const reconnect = timers.filter(t => t.ms < 1000).at(-1);
  reconnect?.fn();
  const sock2 = MockSocket.instances.at(-1);
  sock2.readyState = 1;
  sock2.emit('open');
  const subs = sock2.sent.filter(f => f.tag === 'subscribe');
  assert.equal(subs.length, 1);
  assert.equal(subs[0].channel.namespace, 'doc');
  const bg = timers.filter(t => t.ms >= 1000 && t.ms <= 3000);
  assert.ok(bg.length >= 1, 'background subscribe is deferred 1–3s');
  bg[0].fn();
  assert.ok(sock2.sent.some(f => f.tag === 'subscribe' && f.channel.namespace === 'user'));
});

test('runtime.channels.reconnectPolicy is configurable', () => {
  const runtime = createChannelRuntime({
    WebSocketImpl: MockSocket,
    reconnectPolicy: { goingAwaySpreadMs: 4000, cap: 8000 },
  });
  assert.equal(runtime.reconnectPolicy.goingAwaySpreadMs, 4000);
  assert.equal(runtime.reconnectPolicy.cap, 8000);
  assert.equal(reconnectPolicy({ attempt: 0, reason: 1001, random: () => 0.5, goingAwaySpreadMs: 4000 }), 2000);
});
