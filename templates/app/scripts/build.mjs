// Build order: the native library (it owns the approved operations) → the generated wire client →
// the portable library → the compiled screen → the browser bundle.
import { build } from 'esbuild';
import { mkdir, copyFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import { engine, lakeOverrides, root, run } from './lib.mjs';

const native = resolve(root, 'native');
await run('lake', [...lakeOverrides(), 'build', '{{Name}}Native'], { cwd: native });
await run('lake', [...lakeOverrides(), 'env', 'lean', '--run', 'GenerateClient.lean'], { cwd: native });
await run('lake', [...lakeOverrides(), 'build', '{{Name}}'], { cwd: root });
await run('lake', [...lakeOverrides(), 'env', 'lean', 'Generate.lean'], { cwd: root });
const out = resolve(root, 'dist');
await mkdir(out, { recursive: true });
await build({
  entryPoints: [resolve(root, 'web/main.mjs')], outfile: resolve(out, 'main.js'),
  bundle: true, minify: true, format: 'esm', platform: 'browser', loader: { '.mjs': 'jsx' },
  alias: { '@leanapp/engine': engine },
  define: { 'process.env.NODE_ENV': '"production"' }, logLevel: 'info',
});
for (const file of ['index.html', 'style.css']) await copyFile(resolve(root, 'web', file), resolve(out, file));
