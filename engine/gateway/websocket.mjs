// WebSocket upgrade passthrough: the same gates as HTTP, then a byte pipe to Lean's loopback listener.
// The gateway never parses frames and holds no protocol state; Lean validates the session and owns the session.
import { connect } from 'node:net';
import { createHash, randomBytes } from 'node:crypto';

const reasons = { 400: 'Bad Request', 401: 'Unauthorized', 403: 'Forbidden', 404: 'Not Found', 426: 'Upgrade Required',
  429: 'Too Many Requests', 502: 'Bad Gateway', 503: 'Service Unavailable', 504: 'Gateway Timeout' };
const sessionCookie = /(?:^|;\s*)(?:__Host-)?leanapp_session=([^;]*)/;
const guarded = ['origin', 'cookie', 'sec-websocket-key', 'sec-websocket-version', 'sec-websocket-protocol'];
const forwarded = [...guarded, 'sec-websocket-extensions'];

export const websocketDefaults = { path: '/ws', maxSockets: 4096, maxPerCookie: 8, handshakeTimeoutMs: 5000, idleTimeoutMs: 90000 };

/** Install the `upgrade` handler. Without `websocket` config every upgrade request is answered 404. */
export function attachWebSocket(server, { websocket, origin, metrics, emit, isStopping, onSocketClosed }) {
  const sockets = new Map(), perCookie = new Map();
  const upgrades = metrics.counter('ws_upgrades_total', 'Upgrade requests by outcome');
  const piped = metrics.counter('ws_bytes_total', 'Bytes piped through upgraded connections by direction');
  metrics.gauge('ws_sockets', 'Upgraded connections currently piped', () => sockets.size);
  server.on('upgrade', (req, socket, head) => {
    const started = performance.now(), requestId = randomBytes(12).toString('base64url');
    const line = { requestId, kind: 'upgrade', method: req.method, path: req.url.split('?')[0], status: null, upstreamStatus: null,
      durations: { total: null, upstream: null }, bytes: { in: 0, out: 0 }, reason: null };
    socket.on('error', () => {});
    const finish = (status, reason) => {
      line.status = status; line.reason = reason; line.durations.total = Number((performance.now() - started).toFixed(1));
      upgrades.inc({ outcome: reason }); emit(line);
    };
    const raw = (status, extra = '') => `HTTP/1.1 ${status} ${reasons[status]}\r\n${extra}Connection: close\r\nContent-Length: 0\r\nX-Request-Id: ${requestId}\r\n\r\n`;
    const reject = (status, reason, extra) => { socket.write(raw(status, extra)); socket.destroySoon(); finish(status, reason); };
    if (!websocket) return reject(404, 'no_websocket');
    if (isStopping()) return reject(503, 'draining');
    if (line.path !== websocket.path) return reject(404, 'path');
    if (req.method !== 'GET' || req.headers.upgrade?.toLowerCase() !== 'websocket') return reject(400, 'not_websocket');
    const names = req.rawHeaders.filter((_, i) => i % 2 === 0).map(s => s.toLowerCase());
    if (guarded.some(k => names.filter(n => n === k).length > 1)) return reject(400, 'duplicate_header');
    if (req.headers.origin !== origin) return reject(403, 'origin');
    const session = sessionCookie.exec(req.headers.cookie ?? '')?.[1];
    if (!session) return reject(401, 'cookie');
    if (req.headers['sec-websocket-version'] !== '13') return reject(426, 'version', 'Sec-WebSocket-Version: 13\r\n');
    if (!(req.headers['sec-websocket-protocol'] ?? '').split(',').some(p => p.trim() === 'leanapp.v1')) return reject(400, 'protocol');
    if (!req.headers['sec-websocket-key']) return reject(400, 'key');
    if (sockets.size >= websocket.maxSockets) return reject(503, 'max_sockets');
    // The cookie value is hashed for counting only; it is never logged.
    const cookieHash = createHash('sha256').update(session).digest('base64url').slice(0, 22);
    const count = perCookie.get(cookieHash) ?? 0;
    if (count >= websocket.maxPerCookie) return reject(429, 'max_per_cookie');
    perCookie.set(cookieHash, count + 1);
    const upstream = connect(websocket.backendPort, '127.0.0.1');
    upstream.on('error', () => {});
    let closed = false;
    const teardown = (status, reason) => {
      if (closed) return;
      closed = true; clearTimeout(handshakeTimer); sockets.delete(socket);
      const remaining = (perCookie.get(cookieHash) ?? 1) - 1;
      if (remaining > 0) perCookie.set(cookieHash, remaining); else perCookie.delete(cookieHash);
      if (status) socket.write(raw(status));
      socket.destroySoon(); upstream.destroy();
      finish(status ?? line.upstreamStatus ?? 0, reason); onSocketClosed?.();
    };
    sockets.set(socket, teardown);
    const handshakeTimer = setTimeout(() => teardown(504, 'handshake_timeout'), websocket.handshakeTimeoutMs);
    upstream.on('connect', () => {
      const headers = forwarded.filter(k => req.headers[k] !== undefined).map(k => `${k}: ${req.headers[k]}\r\n`).join('');
      upstream.write(`GET ${req.url} HTTP/1.1\r\nHost: 127.0.0.1:${websocket.backendPort}\r\nConnection: Upgrade\r\nUpgrade: websocket\r\n${headers}x-request-id: ${requestId}\r\n\r\n`);
      if (head.length) upstream.write(head);
      // Only the status line of the first upstream chunk is inspected, for the log; every byte passes through.
      upstream.once('data', chunk => {
        const match = /^HTTP\/1\.1 (\d{3})/.exec(chunk.subarray(0, 12).toString('latin1'));
        line.upstreamStatus = match ? Number(match[1]) : 0; line.durations.upstream = Number((performance.now() - started).toFixed(1));
        clearTimeout(handshakeTimer);
      });
      upstream.on('data', chunk => { line.bytes.out += chunk.length; piped.inc({ direction: 'out' }, chunk.length); });
      socket.on('data', chunk => { line.bytes.in += chunk.length; piped.inc({ direction: 'in' }, chunk.length); });
      socket.pipe(upstream); upstream.pipe(socket);
    });
    // A half-close from either side ends the pipe: WebSocket has no use for half-open TCP.
    socket.setTimeout(websocket.idleTimeoutMs, () => teardown(null, 'idle'));
    for (const event of ['end', 'close']) socket.on(event, () => teardown(null, 'client_closed'));
    socket.on('error', () => teardown(null, 'client_error'));
    // An upstream that closes before answering the handshake (refused, or gone) is a 502 to the client.
    const upstreamGone = () => { if (line.upstreamStatus === null) teardown(502, 'upstream_error'); else teardown(null, 'upstream_closed'); };
    upstream.on('end', upstreamGone); upstream.on('close', upstreamGone);
  });
  return { sockets, destroyAll() { for (const teardown of [...sockets.values()]) teardown(null, 'drain_deadline'); } };
}
