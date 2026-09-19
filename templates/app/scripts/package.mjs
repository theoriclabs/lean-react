// A self-contained source snapshot for the Dockerfile: this application plus the pinned
// dependency sources as Lake fetched them, with a SHA-256 manifest. No caches or databases.
import { lstat, readdir, readFile, mkdir, mkdtemp, writeFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { resolve, dirname, relative, extname, basename } from 'node:path';
import { leanreact, root } from './lib.mjs';

const packages = resolve(root, '.lake/packages');
const dependencies = {
  leanreact: leanreact ?? resolve(packages, 'leanreact'),
  leandb: process.env.LEANAPP_LEANDB_SOURCE ?? resolve(packages, 'leandb'),
  leanhttp: process.env.LEANAPP_LEANHTTP_SOURCE ?? resolve(packages, 'leanhttp'),
  leanws: process.env.LEANAPP_LEANWS_SOURCE ?? resolve(packages, 'leanws'),
  leansqlite: process.env.LEANAPP_LEANSQLITE_SOURCE ?? resolve(packages, 'leansqlite'),
};
const parent = resolve(root, '.lake/releases');
await mkdir(parent, { recursive: true });
const out = await mkdtemp(resolve(parent, '{{name}}-'));
const files = [];
async function copy(source, target, recursive = false) {
  const stat = await lstat(source);
  if (stat.isSymbolicLink()) throw new Error(`Refusing source symlink: ${source}`);
  if (stat.isDirectory()) {
    if (!recursive) throw new Error(`Expected file: ${source}`);
    for (const name of (await readdir(source)).sort()) {
      if (name.startsWith('.') || ['node_modules', 'generated', 'dist', 'test-results'].includes(name)) continue;
      await copy(resolve(source, name), resolve(target, name), true);
    }
    return;
  }
  if (!stat.isFile()) throw new Error(`Non-regular source: ${source}`);
  if (recursive && !['LICENSE', 'lean-toolchain'].includes(basename(source)) &&
      !['.lean', '.js', '.mjs', '.ts', '.css', '.html', '.c', '.h', '.json', '.toml'].includes(extname(source))) return;
  await mkdir(dirname(target), { recursive: true });
  const bytes = await readFile(source);
  await writeFile(target, bytes, { flag: 'wx' });
  files.push({ path: relative(out, target), bytes: bytes.length, sha256: createHash('sha256').update(bytes).digest('hex') });
}
for (const name of ['package.json', 'lakefile.lean', 'lean-toolchain', 'Generate.lean', '{{Name}}.lean'])
  await copy(resolve(root, name), resolve(out, 'app', name));
try { await copy(resolve(root, 'package-lock.json'), resolve(out, 'app/package-lock.json')); } catch {}
for (const name of ['{{Name}}', 'native', 'web', 'gateway', 'scripts'])
  await copy(resolve(root, name), resolve(out, 'app', name), true);
const entries = {
  leanreact: ['engine', 'adapters/native', 'lakefile.toml', 'lean-toolchain', 'LICENSE'],
  leandb: ['LeanDb', 'LeanDb.lean', 'lakefile.toml', 'lean-toolchain', 'LICENSE'],
  leanhttp: ['LeanHttp', 'LeanHttp.lean', 'bindings', 'lakefile.lean', 'lean-toolchain', 'LICENSE'],
  leanws: ['LeanWs', 'LeanWs.lean', 'lakefile.lean', 'lean-toolchain', 'LICENSE'],
  leansqlite: ['SQLite', 'SQLite.lean', 'bindings', 'lakefile.lean', 'lean-toolchain', 'LICENSE'],
};
for (const [dep, source] of Object.entries(dependencies))
  for (const name of entries[dep]) await copy(resolve(source, name), resolve(out, dep, name), true);
await copy(resolve(root, 'deploy/Dockerfile'), resolve(out, 'Dockerfile'));
files.sort((a, b) => a.path.localeCompare(b.path));
await writeFile(resolve(out, 'SOURCE-MANIFEST.json'), JSON.stringify({ format: 'leanapp-source-v1',
  application: '{{name}}', lean: '4.33.0', files }, null, 2) + '\n', { flag: 'wx' });
console.log(out);
console.log(`${files.length} source files; ${files.reduce((n, f) => n + f.bytes, 0)} bytes. No caches or databases.`);
