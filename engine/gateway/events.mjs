// Live events over SSE: the gateway re-broadcasts Lean's own success replies to ticket-holding streams.
// Authority stays in Lean — what is published comes from manifest metadata, who may listen from a ticket
// that an approved Lean command issued, bound here to the browser session cookie. Nothing is replayed.
import { createHash } from 'node:crypto';

export const eventsDefaults = { path: '/stream', maxStreams: 2000, maxStreamsPerCookie: 8, maxTopicsPerTicket: 4,
  pingMs: 20000, retryMs: 3000, queueBytes: 65536, mustDeliver: ['ops'], ticketSweepMs: 60000 };
const sessionCookie = /(?:^|;\s*)(?:__Host-)?leanapp_session=([^;]*)/;
const hash = value => createHash('sha256').update(value).digest('base64url').slice(0, 22);
const text = value => typeof value === 'string' && value.length > 0;
const field = (value, path) => path.split('.').reduce((v, k) => (v !== null && typeof v === 'object' ? v[k] : undefined), value);
const topicKey = value => (text(value) || (typeof value === 'number' && Number.isFinite(value))) ? String(value) : null;
const expiry = value => {
  if (typeof value === 'number' || /^\d+$/.test(String(value))) { const n = Number(value); return n >= 1e11 ? n : n * 1000; }
  return Date.parse(value);
};

/**
 * Build the hub from manifest metadata: `operations[].metadata.publish` (`{topicField, topicPrefix, eventName,
 * alsoToActorField}`) and `issuesStreamTicket`. Returns null when no operation publishes or issues tickets,
 * in which case the gateway installs no stream route.
 */
export function createEventHub({ manifest, events, origin, metrics, emit }) {
  const publishers = new Map(), issuers = new Set();
  for (const operation of manifest?.operations ?? []) {
    const path = operation?.http?.path, metadata = operation?.metadata ?? {};
    if (!text(path)) continue;
    const publish = metadata.publish;
    if (publish !== undefined && publish !== null) {
      if (!text(publish.topicField) || !text(publish.topicPrefix) || !text(publish.eventName) ||
          (publish.alsoToActorField !== undefined && publish.alsoToActorField !== null && !text(publish.alsoToActorField)))
        throw new TypeError(`gateway: invalid publish metadata for ${path}`);
      publishers.set(path, { topicField: publish.topicField, topicPrefix: publish.topicPrefix, eventName: publish.eventName,
        alsoToActorField: publish.alsoToActorField ?? null });
    }
    if (metadata.issuesStreamTicket === true) issuers.add(path);
  }
  if (publishers.size === 0 && issuers.size === 0) return null;

  const mustDeliver = new Set(events.mustDeliver);
  const topics = new Map(), streams = new Set(), perCookie = new Map(), tickets = new Map();
  let sequence = 0;
  const published = metrics.counter('stream_publishes_total', 'Events published to topics, by event name');
  const delivered = metrics.counter('stream_deliveries_total', 'Event frames written to streams');
  const dropped = metrics.counter('stream_dropped_total', 'Droppable frames discarded under backpressure');
  const closed = metrics.counter('stream_closed_total', 'Streams ended by the gateway, by reason');
  const rejected = metrics.counter('stream_rejected_total', 'Stream requests refused, by reason');
  const opened = metrics.counter('streams_total', 'Streams accepted');
  metrics.gauge('streams', 'Open event streams', () => streams.size);
  metrics.gauge('stream_topics', 'Topics with at least one subscriber', () => topics.size);
  metrics.gauge('stream_tickets', 'Unexpired tickets recorded from Lean replies', () => tickets.size);

  const sweep = () => { const now = Date.now(); for (const [ticket, record] of tickets) if (record.exp <= now) tickets.delete(ticket); };
  const sweeper = setInterval(sweep, events.ticketSweepMs); sweeper.unref();

  const detach = (stream, reason) => {
    if (!streams.delete(stream)) return;
    clearInterval(stream.ping);
    for (const topic of stream.topics) { const set = topics.get(topic); set?.delete(stream); if (set?.size === 0) topics.delete(topic); }
    const remaining = (perCookie.get(stream.cookieHash) ?? 1) - 1;
    if (remaining > 0) perCookie.set(stream.cookieHash, remaining); else perCookie.delete(stream.cookieHash);
    if (reason) { closed.inc({ reason }); stream.res.end(); }
  };
  // Bounded per-connection queue: oldest droppable frames go first; a frame that must be delivered closes the stream instead.
  const flush = stream => {
    stream.blocked = false;
    while (stream.queue.length && !stream.blocked) {
      const frame = stream.queue.shift(); stream.queued -= frame.bytes.length;
      if (!stream.res.write(frame.bytes)) stream.blocked = true;
    }
  };
  const write = (stream, event, bytes) => {
    if (!streams.has(stream)) return;
    if (!stream.blocked) {
      if (!stream.res.write(bytes)) { stream.blocked = true; stream.res.once('drain', () => flush(stream)); }
      delivered.inc(); return;
    }
    while (stream.queued + bytes.length > events.queueBytes) {
      const index = stream.queue.findIndex(frame => !mustDeliver.has(frame.event));
      if (index >= 0) { stream.queued -= stream.queue[index].bytes.length; stream.queue.splice(index, 1); dropped.inc(); continue; }
      if (!mustDeliver.has(event)) { dropped.inc(); return; }
      detach(stream, 'backpressure'); stream.res.destroy(); return;
    }
    stream.queue.push({ event, bytes }); stream.queued += bytes.length; delivered.inc();
  };
  const frame = (event, data, id) => Buffer.from(`event: ${event}\n${id === undefined ? '' : `id: ${id}\n`}data: ${JSON.stringify(data)}\n\n`);

  const hub = {
    path: events.path,
    publishers, issuers, tickets, streams,
    observes: path => publishers.has(path) || issuers.has(path),
    /** Fan one event out to a topic's subscribers; returns the number of streams addressed. */
    publish(topic, event, data) {
      const set = topics.get(topic);
      published.inc({ event });
      if (!set) return 0;
      const bytes = frame(event, data, ++sequence);
      for (const stream of [...set]) write(stream, event, bytes);
      return set.size;
    },
    /** Called after each proxied exchange: publish success values and record issued tickets. */
    onProxied(req, reply) {
      if (reply.status !== 200 || !reply.body) return;
      let envelope; try { envelope = JSON.parse(reply.body); } catch { return; }
      if (envelope?.tag !== 'success' || envelope.value === null || typeof envelope.value !== 'object') return;
      const { value } = envelope, path = req.url;
      const publisher = publishers.get(path);
      if (publisher) {
        const key = topicKey(field(value, publisher.topicField));
        let count = 0;
        if (key !== null) count += hub.publish(`${publisher.topicPrefix}:${key}`, publisher.eventName, value);
        const actor = publisher.alsoToActorField ? topicKey(field(value, publisher.alsoToActorField)) : null;
        if (actor !== null) count += hub.publish(`user:${actor}`, publisher.eventName, value);
        if (reply.line) reply.line.streamEventsPublished = count;
      }
      if (issuers.has(path)) {
        const session = sessionCookie.exec(req.headers.cookie ?? '')?.[1];
        const exp = expiry(value.expiresAt);
        const ok = text(value.ticket) && value.ticket.length >= 16 && Array.isArray(value.topics) && value.topics.length > 0 &&
          value.topics.length <= events.maxTopicsPerTicket && value.topics.every(text) && Number.isFinite(exp) && exp > Date.now();
        if (!ok || !session) { emit({ event: 'stream_ticket_ignored', path, reason: !session ? 'no_session_cookie' : 'invalid_ticket_value' }); return; }
        tickets.set(value.ticket, { topics: [...value.topics], exp, cookieHash: hash(session) });
        if (tickets.size % 1024 === 0) sweep();
      }
    },
    /** GET /stream?ticket=… — same-origin cookie, `Accept: text/event-stream`, unexpired ticket bound to this cookie. */
    handleStream(req, res, base, url) {
      const refuse = (status, reason, headers = {}) => { rejected.inc({ reason }); res.writeHead(status, { ...base, ...headers }); res.end(); };
      if (req.method !== 'GET') return refuse(405, 'method', { allow: 'GET' });
      if (!(req.headers.accept ?? '').split(',').some(a => a.trim().split(';')[0] === 'text/event-stream' || a.trim().startsWith('*/*'))) return refuse(406, 'accept');
      if (req.headers.origin !== undefined && req.headers.origin !== origin) return refuse(403, 'origin');
      const session = sessionCookie.exec(req.headers.cookie ?? '')?.[1];
      if (!session) return refuse(403, 'cookie');
      const ticket = url.searchParams.get('ticket'), record = ticket ? tickets.get(ticket) : undefined;
      if (!record) return refuse(403, 'ticket');
      if (record.exp <= Date.now()) { tickets.delete(ticket); return refuse(403, 'expired'); }
      const cookieHash = hash(session);
      if (record.cookieHash !== cookieHash) return refuse(403, 'cookie_mismatch');
      if (streams.size >= events.maxStreams) return refuse(503, 'max_streams', { 'retry-after': '5' });
      const count = perCookie.get(cookieHash) ?? 0;
      if (count >= events.maxStreamsPerCookie) return refuse(429, 'max_streams_per_cookie', { 'retry-after': '60' });
      perCookie.set(cookieHash, count + 1); opened.inc();
      const stream = { res, topics: record.topics, cookieHash, queue: [], queued: 0, blocked: false, ping: null };
      streams.add(stream);
      for (const topic of record.topics) { if (!topics.has(topic)) topics.set(topic, new Set()); topics.get(topic).add(stream); }
      res.on('close', () => detach(stream));
      res.writeHead(200, { ...base, 'content-type': 'text/event-stream', 'x-accel-buffering': 'no' });
      res.write(`retry: ${events.retryMs}\n\n`);
      const lastEventId = req.headers['last-event-id'];
      write(stream, 'hello', frame('hello', { topics: record.topics, lastEventId: typeof lastEventId === 'string' ? lastEventId.slice(0, 64) : null }));
      stream.ping = setInterval(() => write(stream, 'ping', frame('ping', { ts: Date.now() })), events.pingMs);
    },
    /** Drain: tell every stream to go away and end it, before the backend is stopped. */
    drain() {
      clearInterval(sweeper);
      const bye = frame('bye', {});
      for (const stream of [...streams]) { detach(stream); closed.inc({ reason: 'drain' }); stream.res.end(bye); }
      streams.clear(); topics.clear(); perCookie.clear();
    },
  };
  return hub;
}
