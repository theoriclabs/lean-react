import { build } from 'esbuild';
import { mkdir, copyFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { resolve } from 'node:path';
import { run } from './process.mjs';
const root = fileURLToPath(new URL('../', import.meta.url));
await run('lake', ['build', 'Cafe', 'LeanJS'], { cwd: root });
await run('lake', ['env', 'lean', 'scripts/GenerateCafe.lean'], { cwd: root });
const out = resolve(root, 'examples/dist-cafe');
await mkdir(out, { recursive: true });
await build({ entryPoints: [resolve(root, 'examples/cafe/main.mjs')], outfile: resolve(out, 'main.js'),
  bundle: true, minify: true, format: 'esm', platform: 'browser', loader: { '.mjs': 'jsx' },
  define: { 'process.env.NODE_ENV': '"production"' }, logLevel: 'info' });
for (const file of ['index.html', 'style.css']) await copyFile(resolve(root, 'examples/cafe', file), resolve(out, file));
