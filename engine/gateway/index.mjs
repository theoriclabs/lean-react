// Public process only: assets, route allowlist, origin/body/admission limits and process lifecycle.
// Authentication, authorization and persistence are owned by the Lean backend it fronts.
import { createServer, request } from 'node:http';
import { spawn } from 'node:child_process';
import { readFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import { randomBytes } from 'node:crypto';
import { createMetrics, isLoopback } from './metrics.mjs';
import { attachWebSocket, websocketDefaults } from './websocket.mjs';

/** Same literal-path rule as `HttpBinding.validate` and `defineHttpOperation` (Fetch.mjs). */
export const literalPath = path => typeof path === 'string' && /^\/[A-Za-z0-9/_.-]*$/.test(path) &&
  (path === '/' || !path.endsWith('/')) && !path.includes('//') &&
  !path.split('/').some(part => part === '.' || part === '..');

const defaultFiles = [['/', 'index.html', 'text/html'], ['/main.js', 'main.js', 'text/javascript'], ['/style.css', 'style.css', 'text/css']];
const defaultCsp = "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; object-src 'none'; base-uri 'none'; frame-ancestors 'none'; form-action 'self'";
const forward = ['origin', 'cookie', 'content-type', 'x-csrf-token', 'x-leanapp-request', 'accept'];
const backward = ['set-cookie', 'content-type', 'retry-after'];
const sleep = ms => new Promise(r => setTimeout(r, ms));

function checkPort(value, name) {
  if (!Number.isInteger(value) || value < 1 || value > 65535) throw new TypeError(`gateway: invalid ${name}`);
  return value;
}
function checkOrigin(origin) {
  let url; try { url = new URL(origin); } catch { url = null; }
  if (!url || url.origin !== origin || !['http:', 'https:'].includes(url.protocol)) throw new TypeError('gateway: origin must be an exact http(s) origin');
  return origin;
}
function checkAttach(value) {
  const url = new URL(value);
  if (url.protocol !== 'http:' || !['127.0.0.1', '[::1]'].includes(url.hostname) || url.username || url.password ||
      url.pathname !== '/' || url.search || url.hash) throw new TypeError('gateway: backend.attach.url must be an explicit http://loopback:port origin');
  return url.origin;
}
function checkCap(value, name) {
  if (!Number.isInteger(value) || value < 1 || value > 2 ** 32) throw new TypeError(`gateway: invalid body cap for ${name}`);
  return value;
}

/**
 * Start the public process: spawn (or attach to) the backend, wait for readiness, learn the route
 * allowlist from its manifest and listen. Resolves once listening; rejects after cleaning up on failure.
 */
export async function createGateway(config) {
  const development = config.development ?? process.env.LEANAPP_DEVELOPMENT === '1';
  const port = checkPort(config.port, 'port');
  const host = config.host ?? (development ? '127.0.0.1' : '0.0.0.0');
  const origin = checkOrigin(config.origin);
  const backend = config.backend ?? {};
  const attached = backend.attach !== undefined;
  const target = attached ? checkAttach(backend.attach.url) : `http://127.0.0.1:${checkPort(backend.port, 'backend.port')}`;
  if (!attached && (backend.port === port || typeof backend.binary !== 'string')) throw new TypeError('gateway: backend needs a binary and a distinct port');
  const routes = { fromManifest: true, extra: [], bodyBytes: {}, manifestPath: '/api/manifest', health: '/health/ready', ...config.routes };
  const limits = { inFlight: 32, maxConnections: 64, upstreamTimeoutMs: 15000, requestTimeoutMs: 10000, headersTimeoutMs: 10000, keepAliveTimeoutMs: 2000, ...config.limits };
  const drainMs = config.drainMs ?? 20000;
  const { csp = defaultCsp, hsts = 'max-age=31536000', ...extraHeaders } = config.headers ?? {};
  const security = { 'cache-control': 'no-store', 'x-content-type-options': 'nosniff',
    'referrer-policy': 'no-referrer', 'x-frame-options': 'DENY', 'content-security-policy': csp,
    ...(!development && hsts ? { 'strict-transport-security': hsts } : {}), ...extraHeaders };
  const hooks = config.hooks ?? {};
  const name = config.name ?? 'Gateway';
  const websocket = config.websocket ? { ...websocketDefaults, ...config.websocket } : null;
  if (websocket) {
    checkPort(websocket.backendPort, 'websocket.backendPort');
    if (!literalPath(websocket.path) || websocket.path === '/') throw new TypeError('gateway: websocket.path must be a literal path');
  }
  // Versioned JSON lines (`v: 1`); a function sink receives the same records.
  const stamp = record => ({ v: 1, ts: new Date().toISOString(), ...record });
  const emit = typeof config.log === 'function' ? record => config.log(stamp(record)) : config.log === 'silent' ? () => {} :
    record => process.stdout.write(JSON.stringify(stamp(record)) + '\n');

  const assets = {};
  if (config.assets) {
    const dir = resolve(config.assets.dir);
    for (const [path, file, type] of config.assets.files ?? defaultFiles) assets[path] = { bytes: await readFile(resolve(dir, file)), type };
  }
  const spa = config.assets?.spa ? assets['/'] : undefined;

  const allow = new Set([routes.manifestPath, routes.health]), prefixes = [], caps = new Map();
  for (const entry of routes.extra) {
    if (typeof entry === 'string' && entry.endsWith('/*') && literalPath(entry.slice(0, -2))) prefixes.push(entry.slice(0, -1));
    else if (literalPath(entry)) allow.add(entry);
    else throw new TypeError(`gateway: invalid routes.extra entry ${JSON.stringify(entry)}`);
  }
  for (const [path, cap] of Object.entries(routes.bodyBytes)) if (path !== 'default') caps.set(path, checkCap(cap, path));
  const defaultCap = checkCap(routes.bodyBytes.default ?? 8192, 'default');
  const allowed = path => allow.has(path) || (literalPath(path) && prefixes.some(prefix => path.startsWith(prefix)));

  // Process lifecycle: stop admission, drain active public exchanges, then terminate the child.
  const child = attached ? null : spawn(backend.binary, backend.args ?? [], { stdio: ['ignore', 'inherit', 'inherit'], env: {
    ...process.env, ...backend.env, LEANAPP_ORIGIN: origin, LEANAPP_BACKEND_PORT: String(backend.port) } });
  let stopping = false, requested = false, server, ws, shutdownTimer, frontendClosed = true, backendExited = attached, exitCode = 0;
  let resolveStopped; const stopped = new Promise(r => { resolveStopped = r; });
  const connections = new Set();
  const clearDeadlineIfStopped = () => { if (frontendClosed && backendExited && !ws?.sockets.size) { clearTimeout(shutdownTimer); resolveStopped(exitCode); } };
  // HTTP exchanges drain before Lean is told to stop; upgraded pipes stay open so Lean can close sessions itself.
  const drained = () => [...connections].every(socket => ws?.sockets.has(socket));
  let finish, finished = false;
  function shutdown(code = 0) {
    if (stopping) return;
    stopping = true; exitCode = code;
    if (config.exit !== false) process.exitCode = code;
    finish = () => { if (finished) return; finished = frontendClosed = true; child?.kill('SIGTERM'); clearDeadlineIfStopped(); };
    if (server?.listening) { frontendClosed = false; server.close(); server.closeIdleConnections(); if (drained()) finish(); } else finish();
    shutdownTimer = setTimeout(() => { server?.closeAllConnections(); ws?.destroyAll(); child?.kill('SIGKILL'); }, drainMs);
    shutdownTimer.unref();
    clearDeadlineIfStopped();
  }
  child?.on('error', () => { backendExited = true; emit({ event: 'backend_error', message: 'Lean backend could not start' }); shutdown(1); clearDeadlineIfStopped(); });
  child?.on('exit', code => {
    backendExited = true;
    if (!stopping) { emit({ event: 'backend_exit', code }); shutdown(code || 1); }
    clearDeadlineIfStopped();
  });
  const onSignal = () => { requested = true; shutdown(); };
  if (config.signals !== false) {
    process.on('SIGTERM', onSignal); process.on('SIGINT', onSignal);
    stopped.then(() => { process.off('SIGTERM', onSignal); process.off('SIGINT', onSignal); });
  }
  const handle = { server: undefined, port, origin, target, routes: { paths: allow, prefixes, caps }, stopped,
    stop(code = 0) { requested = true; shutdown(code); return stopped; } };
  const fail = async message => {
    shutdown(1); await stopped;
    if (requested) return handle;
    throw new Error(message);
  };

  let ready = false;
  for (let n = 0; n < (backend.readyAttempts ?? 200) && !stopping; n++) {
    try { if ((await fetch(`${target}${routes.health}`, { signal: AbortSignal.timeout(500) })).ok) { ready = true; break; } }
    catch { /* Startup only; no credentials or diagnostic bodies logged. */ }
    await sleep(100);
  }
  if (!ready) return fail('gateway: backend did not become ready');

  // The manifest is the approval record: every literal path it lists is proxied, nothing else.
  let manifest = null;
  if (routes.fromManifest) {
    try {
      const response = await fetch(`${target}${routes.manifestPath}`, { signal: AbortSignal.timeout(5000) });
      if (!response.ok) throw new Error(String(response.status));
      manifest = await response.json();
    } catch { return fail('gateway: manifest unreachable'); }
    if (!Array.isArray(manifest?.operations)) return fail('gateway: manifest malformed');
    let unbound = 0;
    for (const operation of manifest.operations) {
      const http = operation?.http;
      if (http === undefined || http === null) { unbound++; continue; }
      if (!literalPath(http.path)) return fail(`gateway: manifest path rejected: ${JSON.stringify(http.path)}`);
      allow.add(http.path);
      if (http.maxBodyBytes !== undefined && http.maxBodyBytes !== null) {
        if (!Number.isInteger(http.maxBodyBytes) || http.maxBodyBytes < 1) return fail(`gateway: manifest body cap rejected for ${http.path}`);
        caps.set(http.path, http.maxBodyBytes);
      }
    }
    if (unbound) emit({ event: 'manifest_unbound_operations', count: unbound, message: 'operations without http.path; relying on routes.extra' });
  }
  handle.manifest = manifest;

  // Bound active work; rejected anonymous traffic cannot consume a global time quota.
  // Credential KDF work has its own native admission gate and work budgets.
  let inFlight = 0;
  const metrics = createMetrics();
  const requests = metrics.counter('requests_total', 'Public responses by status');
  const rejected = metrics.counter('rejected_total', 'Requests answered by the gateway without reaching Lean, by reason');
  const upstream = metrics.counter('upstream_total', 'Proxied exchanges by upstream status');
  const upstreamMs = metrics.counter('upstream_ms_total', 'Milliseconds spent waiting for upstream headers');
  metrics.gauge('in_flight', 'Proxied exchanges currently admitted', () => inFlight);
  handle.metrics = metrics;
  const proxied = (req, reply) => { try { hooks.onProxied?.(req, reply); } catch { /* hooks never affect the exchange */ } };
  server = createServer(async (req, res) => {
    res.on('error', () => {});
    // One line per exchange; the path is logged without its query, never cookies or bodies.
    const started = performance.now(), requestId = randomBytes(12).toString('base64url'), socket = req.socket, written = socket.bytesWritten;
    const line = { requestId, method: req.method, path: req.url.split('?')[0], status: null, upstreamStatus: null,
      durations: { total: null, upstream: null }, bytes: { in: 0, out: 0 }, streamEventsPublished: 0 };
    res.once('close', () => {
      line.status = res.headersSent ? res.statusCode : null; line.durations.total = Number((performance.now() - started).toFixed(1));
      line.bytes.out = Math.max(0, socket.bytesWritten - written); requests.inc({ status: line.status ?? 'aborted' }); emit(line);
    });
    const base = { ...security, 'x-request-id': requestId };
    const send = (status, body = '', reason) => { if (reason) rejected.inc({ reason }); if (!res.headersSent) res.writeHead(status, base); res.end(body); };
    const path = req.url;
    if (path.startsWith('/internal/')) {
      if (path === '/internal/metrics' && req.method === 'GET' && isLoopback(socket.remoteAddress)) {
        res.writeHead(200, { ...base, 'content-type': 'text/plain; version=0.0.4; charset=utf-8' }); res.end(metrics.render());
      } else send(404, '', 'internal');
      return;
    }
    if (stopping) { send(503, '', 'draining'); return; }
    const serve = asset => {
      res.writeHead(200, { ...base, 'content-type': `${asset.type}; charset=utf-8` });
      res.end(req.method === 'HEAD' ? undefined : asset.bytes);
    };
    if (assets[path] && ['GET', 'HEAD'].includes(req.method)) { serve(assets[path]); return; }
    if (!allowed(path) || !['GET', 'POST'].includes(req.method)) {
      if (spa && ['GET', 'HEAD'].includes(req.method) && literalPath(path) && !path.split('/').pop().includes('.')) serve(spa);
      else send(404, '', 'not_allowed');
      return;
    }
    const names = req.rawHeaders.filter((_, i) => i % 2 === 0).map(s => s.toLowerCase());
    if (forward.some(k => names.filter(n => n === k).length > 1)) { send(400, '', 'duplicate_header'); return; }
    if (path !== routes.health && (req.headers['x-leanapp-request'] !== '1' ||
        (req.method === 'POST' && (req.headers.origin !== origin ||
          req.headers['content-type']?.split(';')[0].trim().toLowerCase() !== 'application/json')))) {
      rejected.inc({ reason: 'forbidden' });
      res.writeHead(403, { ...base, 'content-type': 'application/json' });
      res.end('{"error":"auth.forbidden"}'); return;
    }
    if (path !== routes.health && inFlight >= limits.inFlight) {
      rejected.inc({ reason: 'throttled' });
      res.writeHead(429, { ...base, 'content-type': 'application/json', 'retry-after': '60' });
      res.end('{"error":"auth.throttled"}'); return;
    }
    inFlight++;
    let released = false;
    res.once('close', () => { if (!released) { released = true; inFlight--; } });
    try {
      let size = 0; const chunks = []; const cap = caps.get(path) ?? defaultCap;
      for await (const chunk of req) {
        size += chunk.length;
        if (size > cap) { res.setHeader('connection', 'close'); send(413, '', 'body_too_large'); return; }
        chunks.push(chunk);
      }
      const body = Buffer.concat(chunks); line.bytes.in = body.length;
      const headers = Object.fromEntries(forward.filter(k => req.headers[k] !== undefined).map(k => [k, req.headers[k]]));
      headers['content-length'] = String(body.length); headers['x-request-id'] = requestId;
      const sent = performance.now();
      const up = request(target, { method: req.method, path, headers, timeout: limits.upstreamTimeoutMs }, reply => {
        line.upstreamStatus = reply.statusCode; line.durations.upstream = Number((performance.now() - sent).toFixed(1));
        upstream.inc({ status: reply.statusCode }); upstreamMs.inc({}, line.durations.upstream);
        res.writeHead(reply.statusCode, { ...base, ...Object.fromEntries(backward.filter(k => reply.headers[k] !== undefined).map(k => [k, reply.headers[k]])) });
        const buffered = hooks.onProxied ? [] : null; let replyBytes = 0;
        reply.on('data', chunk => { replyBytes += chunk.length; if (buffered && replyBytes <= (hooks.bodyBytes ?? 1048576)) buffered.push(chunk); });
        reply.on('end', () => proxied(req, { status: reply.statusCode, headers: reply.headers, requestId, line,
          body: buffered && replyBytes <= (hooks.bodyBytes ?? 1048576) ? Buffer.concat(buffered) : null }));
        reply.on('error', () => res.destroy()); reply.pipe(res);
      });
      up.on('timeout', () => up.destroy());
      up.on('error', () => send(502, '', 'upstream_error')); res.on('close', () => up.destroy()); up.end(body);
    } catch { send(400, '', 'bad_request'); }
  });
  stopped.then(() => metrics.close());
  server.on('connection', socket => {
    connections.add(socket);
    socket.on('close', () => { connections.delete(socket); if (stopping && drained()) finish(); });
  });
  ws = attachWebSocket(server, { websocket, origin, metrics, emit, isStopping: () => stopping, onSocketClosed: () => { if (stopping) clearDeadlineIfStopped(); } });
  server.requestTimeout = limits.requestTimeoutMs; server.headersTimeout = limits.headersTimeoutMs; server.keepAliveTimeout = limits.keepAliveTimeoutMs;
  server.maxConnections = limits.maxConnections;
  handle.server = server;
  let failed;
  try {
    await new Promise((listening, reject) => { failed = reject; server.once('error', failed); server.listen(port, host, listening); });
  } catch { return fail('gateway: public listener could not start'); }
  server.off('error', failed);
  server.on('error', () => { emit({ event: 'listener_error' }); shutdown(1); });
  emit({ event: 'listening', name, port });
  return handle;
}
