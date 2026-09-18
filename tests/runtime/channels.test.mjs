import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createChannelRuntime, decodeFrame, encodeFrame } from '../../engine/runtime/channels.mjs';

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
  close() { this.readyState = 3; this.emit('close'); }
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
