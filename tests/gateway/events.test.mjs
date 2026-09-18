import test from 'node:test';
import assert from 'node:assert/strict';
import { connect } from 'node:net';
import { once } from 'node:events';
import { randomBytes } from 'node:crypto';
import { createGateway } from '../../engine/gateway/index.mjs';
import { startStub, freePort, operation } from './stub.mjs';

const json = { 'x-leanapp-request': '1', 'content-type': 'application/json' };
const publish = { topicField: 'doc', topicPrefix: 'doc', eventName: 'ops', alsoToActorField: null };
const manifest = () => ({ operations: [
  operation('/api/doc/submit', { metadata: { publish } }),
  operation('/api/shares/grant', { metadata: { publish: { topicField: 'doc', topicPrefix: 'doc', eventName: 'share', alsoToActorField: 'grantee' } } }),
  operation('/api/cursor/move', { metadata: { publish: { topicField: 'doc', topicPrefix: 'doc', eventName: 'cursor' } } }),
  operation('/api/stream/open', { metadata: { issuesStreamTicket: true } }),
  operation('/api/doc/rename'),
] });
const ticketReply = (topics, expiresAt = Date.now() + 60000) => () => ({ body: { tag: 'success', value: { ticket: randomBytes(24).toString('base64url'), expiresAt, topics } } });

async function gateway(stub, config = {}) {
  const port = await freePort(), origin = `http://127.0.0.1:${port}`;
  const lines = [];
  const handle = await createGateway({ port, origin, development: true, log: line => lines.push(line), signals: false, exit: false, drainMs: 1000,
    backend: { attach: { url: stub.url }, readyAttempts: 20 }, limits: { maxConnections: 256 }, ...config });
  const post = (path, body = {}, cookie) => fetch(origin + path, { method: 'POST', headers: { ...json, origin, ...(cookie ? { cookie } : {}) }, body: JSON.stringify(body) });
  const open = async (cookie, topics = ['doc:1']) => (await (await post('/api/stream/open', { topics }, cookie)).json()).value.ticket;
  /** Subscribe with fetch and parse SSE frames into `{ event, id, data }` objects via `next()`. */
  const subscribe = async (ticket, cookie, headers = {}) => {
    const controller = new AbortController();
    const response = await fetch(`${origin}/stream?ticket=${ticket}`, { headers: { accept: 'text/event-stream', ...(cookie ? { cookie } : {}), ...headers }, signal: controller.signal });
    if (response.status !== 200) return { status: response.status, response };
    const reader = response.body.getReader(), decoder = new TextDecoder(); let buffer = ''; const frames = [], meta = {};
    const pump = (async () => { for (;;) { const { value, done } = await reader.read(); if (done) return; buffer += decoder.decode(value, { stream: true });
      let at; while ((at = buffer.indexOf('\n\n')) >= 0) { const raw = buffer.slice(0, at); buffer = buffer.slice(at + 2); const frame = {};
        for (const l of raw.split('\n')) { const i = l.indexOf(':'); const k = l.slice(0, i), v = l.slice(i + 1).trim(); frame[k] = k === 'data' ? JSON.parse(v) : v; }
        if (frame.event !== undefined) frames.push(frame); else Object.assign(meta, frame); } } })().catch(() => {});
    const next = async (ms = 2000) => { const t = Date.now(); while (!frames.length) { if (Date.now() - t > ms) throw new Error('no frame'); await new Promise(r => setTimeout(r, 5)); } return frames.shift(); };
    const idle = async (ms = 150) => { await new Promise(r => setTimeout(r, ms)); return frames.length === 0; };
    return { status: 200, response, frames, meta, next, idle, ended: pump, close: () => controller.abort() };
  };
  return { handle, port, origin, lines, post, open, subscribe, metrics: async () => (await fetch(`${origin}/internal/metrics`)).text(), settled: () => new Promise(r => setTimeout(r, 30)) };
}

test('apps without publish or ticket metadata get no /stream route; invalid publish metadata refuses startup', async () => {
  const plain = await startStub({ manifest: { operations: [operation('/api/things/save')] } });
  const g = await gateway(plain);
  try {
    assert.equal(g.handle.events, null);
    assert.equal((await fetch(`${g.origin}/stream?ticket=x`, { headers: { accept: 'text/event-stream', cookie: 'leanapp_session=a' } })).status, 404);
  } finally { await g.handle.stop(); await plain.close(); }
  const broken = await startStub({ manifest: { operations: [operation('/api/x', { metadata: { publish: { topicField: 'doc' } } })] } });
  try { await assert.rejects(gateway(broken), /invalid publish metadata/); } finally { await broken.close(); }
});

test('a proxied success reply reaches two subscribers of its topic and not a third on another topic; domain errors publish nothing', async () => {
  const stub = await startStub({ manifest: manifest(), replies: { '/api/stream/open': (body) => ticketReply(JSON.parse(body).topics)(),
    '/api/doc/submit': body => JSON.parse(body).rev === 'stale' ? { status: 409, body: { tag: 'domainError', value: { doc: '1', code: 'stale' } } } :
      { body: { tag: 'success', value: { doc: '1', rev: JSON.parse(body).rev } } },
    '/api/doc/rename': () => ({ body: { tag: 'success', value: { doc: '1', title: 'x' } } }) } });
  const g = await gateway(stub);
  try {
    const alice = 'leanapp_session=alice', bob = 'leanapp_session=bob', carol = 'leanapp_session=carol';
    const a = await g.subscribe(await g.open(alice), alice), b = await g.subscribe(await g.open(bob), bob), c = await g.subscribe(await g.open(carol, ['doc:2']), carol);
    for (const s of [a, b, c]) { assert.equal(s.status, 200); const hello = await s.next(); assert.equal(hello.event, 'hello'); assert.equal(hello.data.lastEventId, null); }
    assert.equal(a.meta.retry, '3000', 'the retry hint precedes hello');
    assert.deepEqual((await g.subscribe(await g.open(alice), alice, { 'last-event-id': '41' }).then(s => s.next().then(f => { s.close(); return f; }))).data, { topics: ['doc:1'], lastEventId: '41' });
    assert.equal(a.response.headers.get('content-type'), 'text/event-stream'); assert.equal(a.response.headers.get('cache-control'), 'no-store');
    const submit = await g.post('/api/doc/submit', { rev: 7 }, alice); assert.equal(submit.status, 200);
    for (const s of [a, b]) { const ops = await s.next(); assert.equal(ops.event, 'ops'); assert.deepEqual(ops.data, { doc: '1', rev: 7 }); assert.match(ops.id, /^\d+$/); }
    assert.ok(await c.idle(), 'the other topic hears nothing');
    assert.equal((await g.post('/api/doc/submit', { rev: 'stale' }, alice)).status, 409);
    await g.post('/api/doc/rename', {}, alice);
    assert.ok(await a.idle() && await b.idle(), 'domain errors and unannotated operations publish nothing');
    await g.settled();
    const submitted = g.lines.find(l => l.path === '/api/doc/submit'); assert.equal(submitted.streamEventsPublished, 2);
    assert.equal(g.lines.find(l => l.path === '/api/doc/rename').streamEventsPublished, 0);
    assert.ok(!JSON.stringify(g.lines).includes('ticket='), 'tickets never logged');
    assert.match(await g.metrics(), /^leanapp_gateway_streams 3$/m);
    assert.match(await g.metrics(), /^leanapp_gateway_stream_publishes_total\{event="ops"\} 1$/m);
    a.close(); b.close(); c.close(); await g.settled();
    assert.match(await g.metrics(), /^leanapp_gateway_streams 0$/m);
  } finally { await g.handle.stop(); await stub.close(); }
});

test('alsoToActorField publishes to user:<actor> as well; topic values may be numbers or nested', async () => {
  const stub = await startStub({ manifest: manifest(), replies: { '/api/stream/open': body => ticketReply(JSON.parse(body).topics)(),
    '/api/shares/grant': () => ({ body: { tag: 'success', value: { doc: 9, grantee: 'u-bob' } } }) } });
  const g = await gateway(stub);
  try {
    const alice = 'leanapp_session=alice', bob = 'leanapp_session=bob';
    const doc = await g.subscribe(await g.open(alice, ['doc:9']), alice), inbox = await g.subscribe(await g.open(bob, ['user:u-bob']), bob);
    await doc.next(); await inbox.next();
    await g.post('/api/shares/grant', {}, alice);
    assert.equal((await doc.next()).event, 'share'); assert.deepEqual((await inbox.next()).data, { doc: 9, grantee: 'u-bob' });
    doc.close(); inbox.close();
  } finally { await g.handle.stop(); await stub.close(); }
});

test('stream gates: ticket bound to the cookie, expiry, accept, origin, method, per-cookie and global limits, topic cap', async () => {
  const stub = await startStub({ manifest: manifest(), replies: { '/api/stream/open': body => { const { topics, expiresAt } = JSON.parse(body); return ticketReply(topics, expiresAt)(); } } });
  const g = await gateway(stub, { events: { maxStreams: 3, maxStreamsPerCookie: 2, maxTopicsPerTicket: 2 } });
  try {
    const alice = 'leanapp_session=alice', bob = 'leanapp_session=bob';
    const ticket = await g.open(alice);
    assert.equal((await g.subscribe(ticket, bob)).status, 403, 'another cookie');
    assert.equal((await g.subscribe(ticket, null)).status, 403, 'no cookie');
    assert.equal((await g.subscribe(ticket, 'theme=dark')).status, 403, 'no session cookie');
    assert.equal((await g.subscribe('unknown', alice)).status, 403);
    assert.equal((await g.subscribe(ticket, alice, { accept: 'application/json' })).status, 406);
    assert.equal((await g.subscribe(ticket, alice, { origin: 'https://evil.example' })).status, 403);
    assert.equal((await fetch(`${g.origin}/stream?ticket=${ticket}`, { method: 'POST', headers: { accept: 'text/event-stream', cookie: alice } })).status, 405);
    const expired = (await (await g.post('/api/stream/open', { topics: ['doc:1'], expiresAt: Date.now() - 1 }, alice)).json()).value.ticket;
    assert.equal(g.handle.events.tickets.has(expired), false, 'already-expired tickets are not recorded');
    const soon = (await (await g.post('/api/stream/open', { topics: ['doc:1'], expiresAt: Date.now() + 80 }, alice)).json()).value.ticket;
    await new Promise(r => setTimeout(r, 120));
    assert.equal((await g.subscribe(soon, alice)).status, 403, 'expired');
    assert.equal(g.handle.events.tickets.has(soon), false);
    const iso = (await (await g.post('/api/stream/open', { topics: ['doc:1'], expiresAt: new Date(Date.now() + 60000).toISOString() }, alice)).json()).value.ticket;
    assert.ok(g.handle.events.tickets.has(iso), 'ISO expiry accepted');
    const wide = (await (await g.post('/api/stream/open', { topics: ['a', 'b', 'c'] }, alice)).json()).value.ticket;
    assert.equal(g.handle.events.tickets.has(wide), false, 'over maxTopicsPerTicket is ignored');
    assert.equal((await g.post('/api/stream/open', { topics: ['doc:1'] })).status, 200);
    assert.ok(g.lines.some(l => l.event === 'stream_ticket_ignored' && l.reason === 'no_session_cookie'));
    const a1 = await g.subscribe(ticket, alice), a2 = await g.subscribe(ticket, alice);
    assert.equal(a1.status, 200); assert.equal(a2.status, 200, 'reconnect within expiry reuses the ticket');
    const a3 = await g.subscribe(ticket, alice); assert.equal(a3.status, 429); assert.equal(a3.response.headers.get('retry-after'), '60');
    const b1 = await g.subscribe(await g.open(bob), bob); assert.equal(b1.status, 200);
    const carol = 'leanapp_session=carol';
    const c1 = await g.subscribe(await g.open(carol), carol); assert.equal(c1.status, 503); assert.equal(c1.response.headers.get('retry-after'), '5');
    a1.close(); await g.settled();
    assert.equal((await g.subscribe(await g.open(carol), carol)).status, 200, 'slots are released');
    const text = await g.metrics();
    for (const reason of ['cookie_mismatch', 'cookie', 'ticket', 'accept', 'origin', 'method', 'expired', 'max_streams_per_cookie', 'max_streams'])
      assert.match(text, new RegExp(`^leanapp_gateway_stream_rejected_total\\{reason="${reason}"\\} [1-9]`, 'm'), reason);
    assert.ok(!JSON.stringify(g.lines).includes('alice'));
  } finally { await g.handle.stop(); await stub.close(); }
});

test('backpressure drops the oldest droppable frames but closes the stream rather than dropping an ops event', async () => {
  const stub = await startStub({ manifest: manifest(), replies: { '/api/stream/open': body => ticketReply(JSON.parse(body).topics)() } });
  const g = await gateway(stub, { events: { queueBytes: 4096 } });
  try {
    const alice = 'leanapp_session=alice';
    const stalled = async () => {
      const socket = connect(g.port, '127.0.0.1'); await once(socket, 'connect');
      socket.write(`GET /stream?ticket=${await g.open(alice)} HTTP/1.1\r\nHost: x\r\nAccept: text/event-stream\r\nCookie: ${alice}\r\n\r\n`);
      await once(socket, 'data'); socket.pause(); return socket;
    };
    const hub = g.handle.events, big = 'x'.repeat(8192);
    const first = await stalled();
    // The client never reads, so res.write() returns false and the bounded queue takes over.
    let n = 0; while (n < 200) { hub.publish('doc:1', 'cursor', { n: n++, big }); if (n % 50 === 0) await g.settled(); }
    assert.equal(hub.streams.size, 1, 'droppable frames never close the stream');
    assert.match(await g.metrics(), /^leanapp_gateway_stream_dropped_total [1-9]\d*$/m);
    n = 0; while (hub.streams.size === 1 && n < 20000) { hub.publish('doc:1', 'ops', { n: n++, big }); if (n % 100 === 0) await g.settled(); }
    assert.equal(hub.streams.size, 0, 'a must-deliver frame that cannot be queued closes the stream');
    assert.ok(n < 20000);
    assert.match(await g.metrics(), /^leanapp_gateway_stream_closed_total\{reason="backpressure"\} 1$/m);
    assert.match(await g.metrics(), /^leanapp_gateway_streams 0$/m);
    first.resume(); await once(first, 'close'); assert.ok(first.destroyed);
  } finally { await g.handle.stop(); await stub.close(); }
});

test('drain sends bye and ends every stream before the listener closes; ping keeps idle streams alive', async () => {
  const stub = await startStub({ manifest: manifest(), replies: { '/api/stream/open': body => ticketReply(JSON.parse(body).topics)() } });
  const g = await gateway(stub, { events: { pingMs: 60 } });
  const alice = 'leanapp_session=alice';
  const s = await g.subscribe(await g.open(alice), alice);
  assert.equal((await s.next()).event, 'hello');
  const ping = await s.next(); assert.equal(ping.event, 'ping'); assert.ok(Number.isInteger(ping.data.ts));
  const stopped = g.handle.stop();
  const bye = await s.next(); assert.equal(bye.event, 'bye');
  await s.ended; await stopped;
  assert.equal(g.lines.filter(l => l.path === '/stream').length, 1);
  assert.equal(g.lines.find(l => l.path === '/stream').status, 200);
  await stub.close();
});
