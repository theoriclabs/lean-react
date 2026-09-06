import { build } from 'esbuild';
import { mkdir, copyFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { resolve } from 'node:path';
import { run } from './process.mjs';

export const projectRoot = fileURLToPath(new URL('../', import.meta.url));

export async function buildExample({ compile = true } = {}) {
  await mkdir(resolve(projectRoot, 'examples/generated'), { recursive: true });
  await mkdir(resolve(projectRoot, 'examples/dist'), { recursive: true });
  if (compile) {
    await run('lake', ['build', 'Examples'], { cwd: projectRoot });
    await run('lake', ['env', 'lean', '-R', 'examples/lean', 'examples/lean/Examples/GenerateDomain.lean'], { cwd: projectRoot });
    await run('lake', ['env', 'lean', '-R', 'examples/lean', 'examples/lean/Examples/Generate.lean'], { cwd: projectRoot });
    await run('lake', ['env', 'lean', '-R', 'examples/lean', 'examples/lean/Examples/Smoke.lean'], { cwd: projectRoot });
    await run('lake', ['env', 'lean', '-R', 'examples/lean', 'examples/lean/Examples/GenerateComposability.lean'], { cwd: projectRoot });
  }
  await build({
    absWorkingDir: projectRoot,
    entryPoints: ['examples/web/main.mjs'],
    outfile: 'examples/dist/app.js',
    bundle: true,
    format: 'esm',
    platform: 'browser',
    sourcemap: true,
    target: ['es2022'],
    loader: { '.lean': 'text' },
    logLevel: 'info',
  });
  await copyFile(resolve(projectRoot, 'examples/web/index.html'), resolve(projectRoot, 'examples/dist/index.html'));
  await copyFile(resolve(projectRoot, 'examples/web/style.css'), resolve(projectRoot, 'examples/dist/style.css'));
  await copyFile(resolve(projectRoot, 'examples/web/favicon.svg'), resolve(projectRoot, 'examples/dist/favicon.svg'));
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try { await buildExample(); }
  catch (error) { console.error(error.message); process.exitCode = 1; }
}
