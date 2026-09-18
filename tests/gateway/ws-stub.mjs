// Minimal RFC 6455 echo backend and raw client helpers for gateway tests. Fixture only; no dependency.
import { createServer } from 'node:http';
import { createServer as createNetServer, connect } from 'node:net';
import { once } from 'node:events';
import { createHash, randomBytes } from 'node:crypto';
import { freePort } from './stub.mjs';

const GUID = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';

/** Encode one unfragmented frame; payloads below 64 KiB. Clients must mask. */
export function encodeFrame(opcode, payload, mask = false) {
  const data = Buffer.isBuffer(payload) ? payload : Buffer.from(payload);
  const length = data.length < 126 ? [data.length] : [126, data.length >> 8, data.length & 255];
  const header = Buffer.from([0x80 | opcode, (mask ? 0x80 : 0) | length[0], ...length.slice(1)]);
  if (!mask) return Buffer.concat([header, data]);
  const key = randomBytes(4), masked = Buffer.from(data.map((b, i) => b ^ key[i % 4]));
  return Buffer.concat([header, key, masked]);
}

/** Decode one frame from the start of `buffer`, or null when incomplete. */
export function parseFrame(buffer) {
  if (buffer.length < 2) return null;
  const opcode = buffer[0] & 0x0f, masked = Boolean(buffer[1] & 0x80);
  let length = buffer[1] & 0x7f, offset = 2;
  if (length === 126) { if (buffer.length < 4) return null; length = buffer.readUInt16BE(2); offset = 4; }
  else if (length === 127) throw new Error('fixture: 64-bit lengths unsupported');
  const size = offset + (masked ? 4 : 0) + length;
  if (buffer.length < size) return null;
  const key = masked ? buffer.subarray(offset, offset + 4) : null;
  const raw = buffer.subarray(offset + (masked ? 4 : 0), size);
  const payload = masked ? Buffer.from(raw.map((b, i) => b ^ key[i % 4])) : Buffer.from(raw);
  return { opcode, payload, size };
}

/** Echo server: text/binary frames come back unmasked; close frames are answered and the socket ended. */
export async function startWsEcho({ port, requireCookie = true } = {}) {
  port ??= await freePort();
  const seen = [], sockets = new Set();
  const server = createServer((req, res) => { res.writeHead(426); res.end(); });
  server.on('upgrade', (req, socket, head) => {
    seen.push({ url: req.url, headers: req.headers });
    sockets.add(socket); socket.on('close', () => sockets.delete(socket));
    socket.on('error', () => {}); socket.on('end', () => socket.end());
    if (requireCookie && !req.headers.cookie) { socket.end('HTTP/1.1 401 Unauthorized\r\nConnection: close\r\nContent-Length: 0\r\n\r\n'); return; }
    const accept = createHash('sha1').update(req.headers['sec-websocket-key'] + GUID).digest('base64');
    socket.write(`HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ${accept}\r\nSec-WebSocket-Protocol: leanapp.v1\r\n\r\n`);
    let buffer = head;
    socket.on('data', chunk => {
      buffer = Buffer.concat([buffer, chunk]);
      for (let frame = parseFrame(buffer); frame; frame = parseFrame(buffer)) {
        buffer = buffer.subarray(frame.size);
        if (frame.opcode === 8) { socket.end(encodeFrame(8, frame.payload)); return; }
        if (frame.opcode === 1 || frame.opcode === 2) socket.write(encodeFrame(frame.opcode, frame.payload));
      }
    });
  });
  server.listen(port, '127.0.0.1'); await once(server, 'listening');
  return { port, seen, sockets, close: () => new Promise(r => { for (const s of sockets) s.destroy(); server.closeAllConnections(); server.close(r); }) };
}

/** A TCP listener that accepts and never answers, for handshake timeouts. */
export async function startSilent() {
  const port = await freePort(), sockets = [];
  const server = createNetServer(socket => { sockets.push(socket); socket.on('error', () => {}); });
  server.listen(port, '127.0.0.1'); await once(server, 'listening');
  return { port, close: () => new Promise(r => { for (const s of sockets) s.destroy(); server.close(r); }) };
}

/**
 * Raw client: performs the upgrade against `port` and resolves with `{ status, headers, socket, send, next, close }`
 * once the response head arrives. Frames after the head are decoded through `next()`.
 */
export function wsClient(port, { path = '/ws', origin, cookie = 'leanapp_session=abc', protocol = 'leanapp.v1', version = '13', upgrade = 'websocket', extra = '' } = {}) {
  return new Promise((done, fail) => {
    const socket = connect(port, '127.0.0.1'); let buffer = Buffer.alloc(0), head = null;
    const frames = [], waiters = [];
    const closed = new Promise(r => socket.on('close', () => { r(); for (const w of waiters.splice(0)) w(null); }));
    socket.on('error', () => {});
    socket.on('connect', () => socket.write(`GET ${path} HTTP/1.1\r\nHost: 127.0.0.1:${port}\r\nConnection: Upgrade\r\nUpgrade: ${upgrade}\r\n` +
      (origin === null ? '' : `Origin: ${origin}\r\n`) + (cookie === null ? '' : `Cookie: ${cookie}\r\n`) +
      (version === null ? '' : `Sec-WebSocket-Version: ${version}\r\n`) + (protocol === null ? '' : `Sec-WebSocket-Protocol: ${protocol}\r\n`) +
      `Sec-WebSocket-Key: ${randomBytes(16).toString('base64')}\r\n${extra}\r\n`));
    socket.on('data', chunk => {
      buffer = Buffer.concat([buffer, chunk]);
      if (!head) {
        const end = buffer.indexOf('\r\n\r\n'); if (end < 0) return;
        const [line, ...rest] = buffer.subarray(0, end).toString().split('\r\n');
        head = { status: Number(line.split(' ')[1]), headers: Object.fromEntries(rest.map(h => { const i = h.indexOf(':'); return [h.slice(0, i).toLowerCase(), h.slice(i + 1).trim()]; })) };
        buffer = buffer.subarray(end + 4);
        done({ ...head, socket, closed,
          send: (text, opcode = 1) => socket.write(encodeFrame(opcode, text, true)),
          next: () => frames.length ? Promise.resolve(frames.shift()) : new Promise(r => waiters.push(r)),
          close: () => { socket.destroy(); return closed; } });
      }
      for (let frame = parseFrame(buffer); frame; frame = parseFrame(buffer)) {
        buffer = buffer.subarray(frame.size);
        const decoded = { opcode: frame.opcode, text: frame.payload.toString() };
        if (waiters.length) waiters.shift()(decoded); else frames.push(decoded);
      }
    });
    socket.on('close', () => { if (!head) fail(new Error('closed before response head')); });
  });
}
