import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createStreamRuntime, reconnectPolicy } from '../../engine/runtime/streams.mjs';

class MockEventSource {
  static instances = [];
  constructor(url) {
    this.url = url;
    this.closed = false;
    this.onopen = null;
    this.onmessage = null;
    this.onerror = null;
    MockEventSource.instances.push(this);
    queueMicrotask(() => this.onopen?.());
  }
  close() { this.closed = true; }
}

test('stream opens, delivers, and records lastEventId on reconnect', async () => {
  MockEventSource.instances = [];
  const events = [];
  const states = [];
  const runtime = createStreamRuntime({ EventSourceImpl: MockEventSource });
  const handle = runtime.open({
    url: 'http://127.0.0.1/stream',
    lastEventId: '7',
    onEvent: e => events.push(e),
    onState: s => states.push(s.status),
  });
  await new Promise(r => setTimeout(r, 10));
  assert.equal(MockEventSource.instances.length, 1);
  assert.match(MockEventSource.instances[0].url, /lastEventId=7/);
  MockEventSource.instances[0].onmessage?.({ lastEventId: '8', data: 'tick' });
  assert.deepEqual(events, [{ id: '8', event: 'tick' }]);
  MockEventSource.instances[0].onerror?.();
  await new Promise(r => setTimeout(r, 10));
  handle.close();
  assert.ok(states.includes('open'));
  assert.ok(states.includes('reconnecting') || states.includes('closed'));
});

test('streams share the channel reconnect policy including 503 spread', () => {
  const delays = [];
  const sources = [];
  const runtime = createStreamRuntime({
    EventSourceImpl: class {
      constructor() {
        this.onopen = null;
        this.onmessage = null;
        this.onerror = null;
        sources.push(this);
      }
      close() {}
    },
    random: () => 0.25,
    setTimeoutFn: (_fn, ms) => { delays.push(ms); return 0; },
    clearTimeoutFn() {},
    reconnectPolicy: { goingAwaySpreadMs: 8000 },
  });
  const handle = runtime.open({ url: 'http://127.0.0.1/stream', onEvent() {}, onState() {} });
  assert.equal(runtime.reconnectPolicy.goingAwaySpreadMs, 8000);
  sources[0].onerror();
  assert.equal(delays[0], 2000);
  assert.equal(reconnectPolicy({ attempt: 0, reason: 503, random: () => 0.25, goingAwaySpreadMs: 8000 }), 2000);
  handle.close();
});
