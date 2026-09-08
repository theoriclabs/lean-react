import { build } from 'esbuild';
import { mkdir, copyFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { resolve } from 'node:path';
import { run } from './process.mjs';
const root = fileURLToPath(new URL('../', import.meta.url));
await run('node', ['scripts/check-security.mjs'], { cwd: root });
const out = resolve(root, 'examples/dist-notes'); await mkdir(out, { recursive: true });
await build({ entryPoints: [resolve(root, 'examples/notes/main.mjs')], outfile: resolve(out, 'main.js'),
  bundle: true, minify: true, format: 'esm', platform: 'browser', loader: { '.mjs': 'jsx' },
  define: { 'process.env.NODE_ENV': '"production"' }, logLevel: 'info' });
for (const file of ['index.html', 'style.css']) await copyFile(resolve(root, 'examples/notes', file), resolve(out, file));
for (const [source, target] of [['.lake/security/evidence.json', 'evidence.json'],
  ['examples/security/PrivateNotes/Spec.lean', 'spec.lean'], ['examples/security/PrivateNotes/Model.lean', 'model.lean']])
  await copyFile(resolve(root, source), resolve(out, target));
