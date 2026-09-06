import { createServer } from 'node:http';
import { readFile, stat } from 'node:fs/promises';
import { watch } from 'node:fs';
import { resolve, extname, sep } from 'node:path';
import { buildExample, projectRoot } from './build.mjs';

const port = Number(process.env.PORT ?? 4173);
const dist = resolve(projectRoot, 'examples/dist');
const mime = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8', '.css': 'text/css; charset=utf-8', '.map': 'application/json' };
if (!process.argv.includes('--no-build')) await buildExample();

const server = createServer(async (req, res) => {
  try {
    const url = new URL(req.url, `http://127.0.0.1:${port}`);
    if (url.pathname.startsWith('/api/') && process.env.LEANREACT_API) {
      const chunks = [];
      for await (const chunk of req) chunks.push(chunk);
      const response = await fetch(new URL(url.pathname + url.search, process.env.LEANREACT_API), {
        method: req.method,
        headers: { 'content-type': 'application/json', ...(req.headers['x-leanreact-contract'] ? { 'x-leanreact-contract': req.headers['x-leanreact-contract'] } : {}) },
        ...(!['GET', 'HEAD'].includes(req.method) ? { body: Buffer.concat(chunks) } : {}),
      });
      res.writeHead(response.status, { 'content-type': response.headers.get('content-type') ?? 'application/json' });
      res.end(Buffer.from(await response.arrayBuffer()));
      return;
    }
    const filename = resolve(dist, '.' + decodeURIComponent(url.pathname === '/' ? '/index.html' : url.pathname));
    if (!filename.startsWith(dist + sep)) { res.writeHead(403); res.end(); return; }
    const body = await readFile(filename);
    res.writeHead(200, { 'content-type': mime[extname(filename)] ?? 'application/octet-stream', 'cache-control': 'no-store' });
    res.end(body);
  } catch (error) {
    res.writeHead(error.code === 'ENOENT' ? 404 : 500);
    res.end(error.code === 'ENOENT' ? 'Not found' : 'Development server error');
  }
});
server.listen(port, '127.0.0.1', () => console.log(`LeanReact example: http://127.0.0.1:${port}`));

if (process.argv.includes('--watch')) {
  let timer;
  let building = false;
  let pending = false;
  const rebuild = async () => {
    if (building) { pending = true; return; }
    building = true;
    try { await buildExample(); console.log('Rebuilt. Refresh the browser.'); }
    catch (error) { console.error(error.message); }
    finally {
      building = false;
      if (pending) { pending = false; void rebuild(); }
    }
  };
  for (const dir of ['engine', 'examples']) {
    const path = resolve(projectRoot, dir);
    try { if (!(await stat(path)).isDirectory()) continue; } catch { continue; }
    watch(path, { recursive: true }, (_event, filename) => {
      if (!filename) return;
      const parts = String(filename).split(/[\\/]/);
      if (parts.some(part => ['.lake', 'generated', 'dist'].includes(part))) return;
      if (/\.(lean|js|mjs|css|html)$/.test(filename)) {
        clearTimeout(timer);
        timer = setTimeout(() => void rebuild(), 200);
      }
    });
  }
}
