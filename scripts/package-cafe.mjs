// Snapshot only application/dependency sources. Never copy caches, accounts or test databases.
import { lstat, readdir, readFile, mkdir, mkdtemp, writeFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { resolve, dirname, relative, extname, basename } from 'node:path';
const root = fileURLToPath(new URL('../', import.meta.url));
const dependencies = {
  leandb_v2: resolve(process.env.LEANAPP_LEANDB_SOURCE ?? resolve(root, '../leandb_v2')),
  leanhttp: resolve(process.env.LEANAPP_LEANHTTP_SOURCE ?? resolve(root, '../leanhttp')),
  leanws: resolve(process.env.LEANAPP_LEANWS_SOURCE ?? resolve(root, '../leanws')),
  leansqlite: resolve(process.env.LEANAPP_LEANSQLITE_SOURCE ?? resolve(root, '../leandb_v2/.lake/packages/leansqlite')),
};
const parent = resolve(root, '.lake/releases');
await mkdir(parent, { recursive: true });
const out = await mkdtemp(resolve(parent, 'proof-and-pour-'));
const files = [];
async function copy(source, target, recursive = false) {
  const stat = await lstat(source);
  if (stat.isSymbolicLink()) throw new Error(`Refusing source symlink: ${source}`);
  if (stat.isDirectory()) {
    if (!recursive) throw new Error(`Expected file: ${source}`);
    for (const name of (await readdir(source)).sort()) {
      if (name.startsWith('.') || ['node_modules', 'generated', 'dist'].includes(name)) continue;
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
  files.push({ path: relative(out, target), bytes: bytes.length,
    sha256: createHash('sha256').update(bytes).digest('hex') });
}
for (const name of ['package.json', 'package-lock.json', 'lakefile.toml', 'lean-toolchain', 'LICENSE'])
  await copy(resolve(root, name), resolve(out, 'leanreact', name));
// `engine` includes `engine/gateway`, the public process module serve-cafe.mjs configures.
for (const name of ['engine', 'examples/ordering', 'examples/cafe', 'adapters/native/LeanAppNative', 'adapters/native/bindings'])
  await copy(resolve(root, name), resolve(out, 'leanreact', name), true);
for (const name of ['adapters/native/lakefile.lean', 'adapters/native/lean-toolchain', 'adapters/native/CafeMain.lean',
  'adapters/native/CryptoChecks.lean', 'scripts/build-cafe.mjs', 'scripts/process.mjs', 'scripts/GenerateCafe.lean', 'scripts/serve-cafe.mjs'])
  await copy(resolve(root, name), resolve(out, 'leanreact', name));
for (const [dep, source] of Object.entries(dependencies)) {
  const entries = dep === 'leandb_v2' ? ['LeanDb', 'LeanDb.lean', 'lakefile.toml', 'lean-toolchain', 'LICENSE'] :
    dep === 'leanhttp' ? ['LeanHttp', 'LeanHttp.lean', 'bindings', 'lakefile.lean', 'lean-toolchain', 'LICENSE'] :
    dep === 'leanws' ? ['LeanWs', 'LeanWs.lean', 'lakefile.lean', 'lean-toolchain', 'LICENSE'] :
      ['SQLite', 'SQLite.lean', 'bindings', 'lakefile.lean', 'lean-toolchain', 'LICENSE'];
  for (const name of entries) await copy(resolve(source, name), resolve(out, dep, name), true);
}
await copy(resolve(root, 'deploy/cafe/Dockerfile'), resolve(out, 'Dockerfile'));
files.sort((a, b) => a.path.localeCompare(b.path));
await writeFile(resolve(out, 'SOURCE-MANIFEST.json'), JSON.stringify({ format: 'leanapp-source-v1',
  release: '0.2.0-rc.1', lean: '4.33.0', files }, null, 2) + '\n', { flag: 'wx' });
console.log(out);
console.log(`${files.length} source files; ${files.reduce((n, f) => n + f.bytes, 0)} bytes. No caches or databases.`);
