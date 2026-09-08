/** Dev-only cleartext loopback proxy. Run:
 * LEANAPP_AUTH_API=http://127.0.0.1:<backendport> node scripts/auth-dev.mjs
 * PORT defaults to 4175. Configure that exact UI origin at the backend, with its
 * explicit development cookie mode. No CDN, dotenv loading, credential logging,
 * arbitrary upstream URL, or production hosting claim. --build-only builds assets.
 * Receipt/checks: node --test tests/integration/auth-client.test.mjs.
 * Passed locally: 11 mocked-fetch tests and the --build-only esbuild entry point.
 * Tests cover headers, session shape/error validation, all auth actions, queued
 * transitions, late successes/errors, ownership invalidation and Contract matching.
 * Client API: createAuthClient({fetch?}), signup/login/logout/restore,
 * getSnapshot/subscribe, protected request and Contract call. CSRF remains private;
 * neither browser storage nor diagnostics contain credentials. Password inputs are
 * cleared on submit; queued transitions retain credentials only until dispatch.
 * Proxy body limit: 16 KiB; timeout: 30 seconds; upstream fixed to explicit loopback.
 * Assets are rebuilt at startup (restart after edits); no watch/HMR implementation.
 * Real browser/HTTP qualification is owned by the parent integration task.
 */
import { createServer, request } from 'node:http';
import { readFile, mkdir, copyFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { resolve } from 'node:path';
import { build } from 'esbuild';

const root = fileURLToPath(new URL('../', import.meta.url));
const target = new URL(process.env.LEANAPP_AUTH_API ?? 'invalid:');
if (target.protocol !== 'http:' || !['127.0.0.1', '[::1]'].includes(target.hostname) ||
    target.username || target.password || target.pathname !== '/' || target.search || target.hash)
  throw new Error('LEANAPP_AUTH_API must be an explicit http://loopback:port origin.');
const port = Number(process.env.PORT ?? 4175);
if (!Number.isInteger(port) || port < 1 || port > 65535) throw new Error('Invalid PORT.');
const dist = resolve(root, 'examples/dist-auth');
await mkdir(dist, { recursive: true });
await build({ entryPoints: [resolve(root, 'examples/auth/main.mjs')], outfile: resolve(dist, 'main.js'),
  bundle: true, format: 'esm', platform: 'browser', loader: { '.mjs': 'jsx' }, logLevel: 'silent' });
await copyFile(resolve(root, 'examples/auth/index.html'), resolve(dist, 'index.html'));
await copyFile(resolve(root, 'examples/auth/style.css'), resolve(dist, 'style.css'));

const MAX_BODY = 16 * 1024;
const forward = ['origin', 'cookie', 'content-type', 'x-csrf-token', 'x-leanapp-request', 'accept'];
const backward = ['set-cookie', 'content-type', 'cache-control', 'pragma', 'expires', 'vary', 'retry-after'];
async function proxy(req, res, path) {
  if (!['GET', 'POST', 'HEAD'].includes(req.method)) { res.writeHead(405); res.end(); return; }
  let size = 0;
  const chunks = [];
  for await (const chunk of req) {
    size += chunk.length;
    if (size > MAX_BODY) { res.writeHead(413, { 'connection': 'close' }); res.end(); return; }
    chunks.push(chunk);
  }
  const body = Buffer.concat(chunks);
  const headers = Object.fromEntries(forward.filter(k => req.headers[k] !== undefined).map(k => [k, req.headers[k]]));
  if (body.length || req.method === 'POST') headers['content-length'] = String(body.length);
  const upstream = request(target, { method: req.method, path, headers, timeout: 30000 }, response => {
    res.writeHead(response.statusCode, Object.fromEntries(backward.filter(k => response.headers[k] !== undefined).map(k => [k, response.headers[k]])));
    response.on('error', () => res.destroy());
    response.pipe(res);
  });
  upstream.on('timeout', () => upstream.destroy());
  upstream.on('error', () => { if (!res.headersSent) res.writeHead(502, { 'cache-control': 'no-store' }); res.end(); });
  res.on('close', () => upstream.destroy());
  upstream.end(body);
}
if (!process.argv.includes('--build-only')) {
  const server = createServer(async (req, res) => {
    try {
      if (!req.url.startsWith('/') || req.url.startsWith('//') || req.url.includes('\\')) { res.writeHead(400); res.end(); return; }
      const url = new URL(req.url, `http://127.0.0.1:${port}`);
      if (url.pathname.startsWith('/auth/') || url.pathname.startsWith('/api/') || url.pathname === '/health/ready') {
        await proxy(req, res, url.pathname + url.search); return;
      }
      const files = { '/': ['index.html', 'text/html'], '/index.html': ['index.html', 'text/html'],
        '/main.js': ['main.js', 'text/javascript'], '/style.css': ['style.css', 'text/css'] };
      const file = files[url.pathname];
      if (!file || !['GET', 'HEAD'].includes(req.method)) { res.writeHead(404); res.end(); return; }
      const body = await readFile(resolve(dist, file[0]));
      res.writeHead(200, { 'content-type': file[1] + '; charset=utf-8', 'cache-control': 'no-store',
        'x-content-type-options': 'nosniff', 'referrer-policy': 'no-referrer' });
      res.end(req.method === 'HEAD' ? undefined : body);
    } catch { if (!res.headersSent) res.writeHead(500); res.end('Development server error'); }
  });
  server.listen(port, '127.0.0.1', () => console.log(`Auth UI: http://127.0.0.1:${port} (development only)`));
}
