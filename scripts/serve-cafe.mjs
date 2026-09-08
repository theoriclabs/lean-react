// Presentation/HTTP process only. Credentials, prices and persistence are owned by Lean.
import { createServer, request } from 'node:http';
import { spawn } from 'node:child_process';
import { readFile, mkdir } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';
const root = fileURLToPath(new URL('../', import.meta.url));
const development = process.env.LEANAPP_DEVELOPMENT === '1';
const port = Number(process.env.PORT ?? 4180);
const backendPort = Number(process.env.LEANAPP_BACKEND_PORT ?? 4181);
if (![port, backendPort].every(p => Number.isInteger(p) && p > 0 && p <= 65535) || port === backendPort)
  throw new Error('Invalid ports');
const origin = process.env.LEANAPP_ORIGIN ?? (development ? `http://127.0.0.1:${port}` :
  process.env.RAILWAY_PUBLIC_DOMAIN ? `https://${process.env.RAILWAY_PUBLIC_DOMAIN}` : '');
if (!origin) throw new Error('Set LEANAPP_ORIGIN to the public HTTPS origin.');
if (!development && !process.env.LEANAPP_DB_PATH && !process.env.RAILWAY_VOLUME_MOUNT_PATH)
  throw new Error('Persistent storage required: set LEANAPP_DB_PATH or attach a Railway volume.');
const db = process.env.LEANAPP_DB_PATH ?? (development ? resolve(root, '.lake/cafe.sqlite') :
  resolve(process.env.RAILWAY_VOLUME_MOUNT_PATH, 'cafe.sqlite'));
await mkdir(dirname(db), { recursive: true });
const binary = process.env.LEANAPP_CAFE_BINARY ?? resolve(root, 'adapters/native/.lake/build/bin/leanapp_cafe');
const assets = {};
for (const [path, file, type] of [['/', 'index.html', 'text/html'], ['/main.js', 'main.js', 'text/javascript'], ['/style.css', 'style.css', 'text/css']])
  assets[path] = { bytes: await readFile(resolve(root, 'examples/dist-cafe', file)), type };
const backend = spawn(binary, [], { stdio: ['ignore', 'inherit', 'inherit'], env: { ...process.env,
  LEANAPP_ORIGIN: origin, LEANAPP_DB_PATH: db, LEANAPP_BACKEND_PORT: String(backendPort) } });
let stopping = false, server, shutdownTimer, frontendClosed = true, backendExited = false;
const clearDeadlineIfStopped = () => { if (frontendClosed && backendExited) clearTimeout(shutdownTimer); };
function shutdown(code = 0) {
  if (stopping) return;
  stopping = true; process.exitCode = code;
  // Stop admission, drain active public exchanges, then terminate the child.
  const finish = () => { frontendClosed = true; backend.kill('SIGTERM'); clearDeadlineIfStopped(); };
  if (server?.listening) { frontendClosed = false; server.close(finish); server.closeIdleConnections(); } else finish();
  shutdownTimer = setTimeout(() => { server?.closeAllConnections(); backend.kill('SIGKILL'); }, 20000);
  shutdownTimer.unref();
  clearDeadlineIfStopped();
}
backend.on('error', () => { backendExited = true; console.error('Lean backend could not start'); shutdown(1); clearDeadlineIfStopped(); });
backend.on('exit', code => {
  backendExited = true;
  if (!stopping) { console.error('Lean backend exited'); shutdown(code || 1); }
  clearDeadlineIfStopped();
});
process.on('SIGTERM', () => shutdown());
process.on('SIGINT', () => shutdown());
const target = `http://127.0.0.1:${backendPort}`;
let ready = false;
for (let n = 0; n < 200 && !stopping; n++) {
  try { if ((await fetch(`${target}/health/ready`, { signal: AbortSignal.timeout(500) })).ok) { ready = true; break; } }
  catch { /* Startup only; no credentials or diagnostic bodies logged. */ }
  await new Promise(r => setTimeout(r, 100));
}
if (!ready) { shutdown(1); } else {
  const security = { 'cache-control': 'no-store', 'x-content-type-options': 'nosniff',
    'referrer-policy': 'no-referrer', 'x-frame-options': 'DENY',
    'content-security-policy': "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; object-src 'none'; base-uri 'none'; frame-ancestors 'none'; form-action 'self'",
    ...(!development ? { 'strict-transport-security': 'max-age=31536000' } : {}) };
  const forward = ['origin', 'cookie', 'content-type', 'x-csrf-token', 'x-leanapp-request', 'accept'];
  const backward = ['set-cookie', 'content-type', 'retry-after'];
  // Bound active work; rejected anonymous traffic cannot consume a global time quota.
  // Credential KDF work has its own native admission gate and work budgets.
  let inFlight = 0;
  server = createServer(async (req, res) => {
    res.on('error', () => {});
    const send = (status, body = '') => { if (!res.headersSent) res.writeHead(status, security); res.end(body); };
    if (stopping) { send(503); return; }
    const path = req.url;
    if (assets[path] && ['GET', 'HEAD'].includes(req.method)) {
      const asset = assets[path]; res.writeHead(200, { ...security, 'content-type': `${asset.type}; charset=utf-8` });
      res.end(req.method === 'HEAD' ? undefined : asset.bytes); return;
    }
    if (!/^\/(auth\/[a-z]+|api\/recipes\/(list|save|delete)|health\/ready)$/.test(path) || !['GET', 'POST'].includes(req.method)) { send(404); return; }
    const names = req.rawHeaders.filter((_, i) => i % 2 === 0).map(s => s.toLowerCase());
    if (forward.some(k => names.filter(n => n === k).length > 1)) { send(400); return; }
    if (path !== '/health/ready' && (req.headers['x-leanapp-request'] !== '1' ||
        (req.method === 'POST' && (req.headers.origin !== origin ||
          req.headers['content-type']?.split(';')[0].trim().toLowerCase() !== 'application/json')))) {
      res.writeHead(403, { ...security, 'content-type': 'application/json' });
      res.end('{"error":"auth.forbidden"}'); return;
    }
    if (path !== '/health/ready' && inFlight >= 32) {
      res.writeHead(429, { ...security, 'content-type': 'application/json', 'retry-after': '60' });
      res.end('{"error":"auth.throttled"}'); return;
    }
    inFlight++;
    let released = false;
    res.once('close', () => { if (!released) { released = true; inFlight--; } });
    try {
      let size = 0; const chunks = [];
      for await (const chunk of req) {
        size += chunk.length;
        if (size > 8192) { res.setHeader('connection', 'close'); send(413); return; }
        chunks.push(chunk);
      }
      const body = Buffer.concat(chunks);
      const headers = Object.fromEntries(forward.filter(k => req.headers[k] !== undefined).map(k => [k, req.headers[k]]));
      headers['content-length'] = String(body.length);
      const up = request(target, { method: req.method, path, headers, timeout: 15000 }, reply => {
        res.writeHead(reply.statusCode, { ...security, ...Object.fromEntries(backward.filter(k => reply.headers[k] !== undefined).map(k => [k, reply.headers[k]])) });
        reply.on('error', () => res.destroy()); reply.pipe(res);
      });
      up.on('timeout', () => up.destroy());
      up.on('error', () => send(502)); res.on('close', () => up.destroy()); up.end(body);
    } catch { send(400); }
  });
  server.requestTimeout = 10000; server.headersTimeout = 10000; server.keepAliveTimeout = 2000;
  server.maxConnections = 64;
  server.on('error', () => { console.error('Public listener could not start'); shutdown(1); });
  server.listen(port, development ? '127.0.0.1' : '0.0.0.0', () => console.log(`Proof & Pour listening on port ${port}`));
}
