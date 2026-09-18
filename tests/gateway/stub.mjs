#!/usr/bin/env node
// Process-boundary fixture only: a Node stand-in for the Lean backend. Never shipped.
import { createServer } from 'node:http';
import { once } from 'node:events';
import { createServer as createNetServer } from 'node:net';
import { pathToFileURL } from 'node:url';

export async function freePort() {
  const s = createNetServer(); s.listen(0, '127.0.0.1'); await once(s, 'listening');
  const p = s.address().port; await new Promise(r => s.close(r)); return p;
}

export const operation = (path, extra = {}) => ({ namespace: 'stub', name: path.split('/').pop(), version: '1', kind: 'command',
  input: {}, output: {}, error: {}, http: { path, method: 'POST', maxBodyBytes: null, ...extra.http },
  metadata: { title: '', description: '', publish: null, issuesStreamTicket: false, ...extra.metadata } });

/**
 * Routes: `/health/ready`, `/api/manifest`, `/api/crash` (exit 7), `/api/hang` (replies when `release()` is
 * called or after `hangMs`), `/api/echo` (JSON of forwarded headers and body size), `/api/reply/<n>` (status n).
 * Every other path answers a success envelope built from `replies[path]` when present.
 */
export async function startStub({ port, manifest = { operations: [] }, hangMs = 30000, replies = {} } = {}) {
  port ??= await freePort();
  const hits = [], pending = new Set();
  const server = createServer((req, res) => {
    hits.push({ method: req.method, url: req.url, headers: req.headers });
    const json = (status, body, headers = {}) => { res.writeHead(status, { 'content-type': 'application/json', ...headers }); res.end(JSON.stringify(body)); };
    if (req.url === '/health/ready') return json(200, { ready: true });
    if (req.url === '/api/manifest') return json(200, manifest);
    if (req.url === '/api/crash') process.exit(7);
    const chunks = [];
    req.on('data', c => chunks.push(c));
    req.on('end', () => {
      const body = Buffer.concat(chunks);
      if (req.url === '/api/hang') {
        const reply = () => { pending.delete(reply); json(200, { tag: 'success', value: { hung: true } }); };
        pending.add(reply); setTimeout(reply, hangMs).unref(); return;
      }
      if (req.url === '/api/echo') return json(200, { headers: req.headers, bodyBytes: body.length, method: req.method }, { 'set-cookie': 'leanapp_session=x; Path=/; HttpOnly', 'retry-after': '5', 'x-private': 'never' });
      const status = req.url.match(/^\/api\/reply\/(\d{3})$/);
      if (status) return json(Number(status[1]), { tag: 'domainError', value: { code: status[1] } });
      const reply = replies[req.url];
      if (typeof reply === 'function') { const out = reply(body, req); return json(out.status ?? 200, out.body); }
      json(200, { tag: 'success', operation: { namespace: 'stub', name: req.url.split('/').pop(), version: '1' }, value: reply ?? { ok: true } });
    });
  });
  server.listen(port, '127.0.0.1'); await once(server, 'listening');
  return { port, url: `http://127.0.0.1:${port}`, hits, release: () => { for (const reply of [...pending]) reply(); },
    close: () => new Promise(r => { server.closeAllConnections(); server.close(r); }) };
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const manifest = process.env.STUB_MANIFEST ? JSON.parse(process.env.STUB_MANIFEST) : { operations: [operation('/api/things/save')] };
  await startStub({ port: Number(process.env.LEANAPP_BACKEND_PORT), manifest, hangMs: Number(process.env.STUB_HANG_MS ?? 30000) });
}
