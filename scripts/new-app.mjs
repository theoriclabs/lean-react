#!/usr/bin/env node
/** Scaffold a standalone LeanApp repository from templates/app.
 *
 *   node scripts/new-app.mjs --name leangd --namespace leangd --out ../leangd [--pin <rev>] [--url <git url>]
 *
 * `{{name}}` is the package name (lowercase, digits, hyphens or underscores), `{{Name}}` the derived
 * Lean namespace, `{{namespace}}` the wire namespace of the operations. The generated native package
 * pins LeanDB, LeanHttp, leanws and LeanSQLite by Git revision and lean-react by `--pin`, which
 * defaults to the commit this checkout is at; pass `--pin v0.2.0` once such a tag exists. */
import { mkdir, readdir, readFile, writeFile, stat } from 'node:fs/promises';
import { execFileSync } from 'node:child_process';
import { dirname, join, relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const root = resolve(here, '..');
const template = resolve(root, 'templates/app');
const args = process.argv.slice(2);
const opt = (name, fallback) => {
  const i = args.indexOf(`--${name}`);
  return i >= 0 && i + 1 < args.length ? args[i + 1] : fallback;
};
const name = opt('name');
const out = opt('out');
if (!name || !out || args.includes('--help')) {
  console.error('usage: node scripts/new-app.mjs --name <package> [--namespace <wire namespace>] --out <dir> [--pin <rev>] [--url <git url>]');
  process.exit(1);
}
if (!/^[a-z][a-z0-9_-]*$/.test(name)) throw new Error(`--name must be lowercase letters, digits, hyphens or underscores: ${name}`);
const namespace = opt('namespace', name);
if (!/^[a-z][a-z0-9_.-]*$/.test(namespace)) throw new Error(`--namespace must be a lowercase identifier: ${namespace}`);
const Name = name.replace(/(^|[-_])([a-z0-9])/g, (_, __, c) => c.toUpperCase());
const url = opt('url', 'https://github.com/theoriclabs/lean-react');
const pin = opt('pin', (() => {
  try { return execFileSync('git', ['rev-parse', 'HEAD'], { cwd: root, encoding: 'utf8' }).trim(); }
  catch { throw new Error('pass --pin <rev>: this checkout has no git HEAD to pin lean-react to'); }
})());
const toolchain = (await readFile(resolve(root, 'lean-toolchain'), 'utf8')).trim();
const dest = resolve(out);
try {
  const existing = await readdir(dest);
  if (existing.length > 0) throw new Error(`refusing to scaffold into a non-empty directory: ${dest}`);
} catch (error) { if (error.code !== 'ENOENT') throw error; }

const substitutions = { '{{name}}': name, '{{Name}}': Name, '{{namespace}}': namespace,
  '{{leanreactUrl}}': url, '{{leanreactRev}}': pin, '{{toolchain}}': toolchain };
const substitute = text => Object.entries(substitutions).reduce((acc, [key, value]) => acc.split(key).join(value), text);

async function walk(dir) {
  const entries = await readdir(dir, { withFileTypes: true });
  const files = [];
  for (const entry of entries) {
    const full = join(dir, entry.name);
    if (entry.isDirectory()) files.push(...await walk(full));
    else files.push(full);
  }
  return files;
}
let count = 0;
for (const source of (await walk(template)).sort()) {
  const rel = relative(template, source).split('__Name__').join(Name);
  const target = join(dest, rel);
  await mkdir(dirname(target), { recursive: true });
  await writeFile(target, substitute(await readFile(source, 'utf8')));
  count += 1;
}
await stat(dest);
console.log(`Scaffolded ${Name} (${count} files) into ${dest}`);
console.log(`lean-react pinned to ${url} @ ${pin}; native dependencies pinned in native/lakefile.lean.`);
console.log('Next: npm install && npm run build && (cd native && lake build) && npm test');
