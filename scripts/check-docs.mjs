// Validate local navigation and execute complete Lean examples in the developer guides.
// No external URL crawl, native database, public listener or hosted mutation.
import assert from 'node:assert/strict';
import { readFile, stat, mkdir, mkdtemp, writeFile } from 'node:fs/promises';
import { dirname, resolve, extname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { run } from './process.mjs';

const root = fileURLToPath(new URL('../', import.meta.url));
const documents = [
  'README.md', 'CONTRIBUTING.md', 'engine/README.md', 'examples/README.md',
  'engine/LeanReact/API.md', 'engine/runtime/README.md', 'docs/ABI.md',
  'docs/README.md', 'docs/GETTING_STARTED.md', 'docs/DOMAIN_MODELING.md',
  'docs/ARCHITECTURE.md', 'docs/LEANREACT.md', 'docs/HOW_TO.md',
  'docs/FULLSTACK_INTERFACES.md', 'docs/NATIVE.md', 'docs/IMPLEMENTED.md',
  'docs/AUTH.md', 'docs/HOSTING.md', 'docs/RELEASE.md', 'docs/LEANAPP_STATUS.md',
  'docs/AUTHORIZATION_DEMO.md', 'docs/AUTHORIZATION_DESIGN.md',
  'docs/PRIVATE_NOTES.md', 'deploy/notes/README.md',
];
const withoutFences = text => text.replace(/^(`{3,}|~{3,})[^\n]*\n[\s\S]*?^\1\s*$/gm, '');
function anchors(text) {
  const ids = new Set(), counts = new Map();
  for (const match of withoutFences(text).matchAll(/^#{1,6}\s+(.+?)\s*#*\s*$/gm)) {
    const name = match[1].replace(/<[^>]*>/g, '').replace(/\[([^\]]+)\]\([^)]*\)/g, '$1')
      .toLowerCase().replace(/[^\p{L}\p{N}\p{M}_\-\s]/gu, '').replace(/\s/g, '-');
    const count = counts.get(name) ?? 0;
    counts.set(name, count + 1); ids.add(count ? `${name}-${count}` : name);
  }
  for (const match of text.matchAll(/\b(?:id|name)=["']([^"']+)["']/g)) ids.add(match[1]);
  return ids;
}
const content = new Map();
async function markdown(path) {
  if (!content.has(path)) content.set(path, await readFile(path, 'utf8'));
  return content.get(path);
}
let links = 0;
const examples = new Map();
for (const name of documents) {
  const path = resolve(root, name), text = await markdown(path);
  for (const match of withoutFences(text).matchAll(/!?\[[^\]\n]*\]\(([^)\n]+)\)/g)) {
    const target = match[1].replace(/^<([^>]+)>.*$/, '$1').split(/\s+["']/)[0];
    if (/^(?:[a-z][a-z0-9+.-]*:|\/\/)/i.test(target)) continue;
    const hashAt = target.indexOf('#');
    const pathname = hashAt < 0 ? target : target.slice(0, hashAt);
    const fragment = hashAt < 0 ? '' : decodeURIComponent(target.slice(hashAt + 1));
    const destination = pathname ? resolve(dirname(path), decodeURIComponent(pathname)) : path;
    try { await stat(destination); }
    catch { throw new Error(`${name}: missing local link ${target}`); }
    if (fragment && extname(destination) === '.md')
      assert.ok(anchors(await markdown(destination)).has(fragment), `${name}: missing anchor ${target}`);
    ++links;
  }
  for (const match of text.matchAll(/^<!-- lean-check: ([a-z0-9-]+) -->\s*```lean\r?\n([\s\S]*?)\r?\n```/gm)) {
    assert.ok(!examples.has(match[1]), `Duplicate Lean documentation example: ${match[1]}`);
    examples.set(match[1], match[2]);
  }
  const markerCount = [...text.matchAll(/^<!-- lean-check:/gm)].length;
  const snippetCount = [...text.matchAll(/^<!-- lean-check: ([a-z0-9-]+) -->\s*```lean\r?\n([\s\S]*?)\r?\n```/gm)].length;
  assert.equal(snippetCount, markerCount, `${name}: malformed Lean example marker/fence`);
}
assert.ok(examples.size > 0, 'No executable Lean documentation examples found');
console.log(`Checked ${links} local links/anchors across ${documents.length} developer documents.`);

const pkg = JSON.parse(await readFile(resolve(root, 'package.json'), 'utf8'));
const lock = JSON.parse(await readFile(resolve(root, 'package-lock.json'), 'utf8'));
assert.equal(pkg.name, 'leanapp-workspace'); assert.equal(pkg.private, true);
assert.equal(lock.name, pkg.name); assert.equal(lock.packages[''].name, pkg.name);
assert.equal(lock.version, pkg.version); assert.equal(lock.packages[''].version, pkg.version);
assert.equal(pkg.license, 'MIT'); assert.equal(lock.packages[''].license, pkg.license);
assert.match(await readFile(resolve(root, 'lakefile.toml'), 'utf8'), /^name = "leanreact"$/m);

await run('lake', ['build', 'LeanApp', 'LeanReact', 'Ordering', 'Cafe', 'PrivateNotes'], { cwd: root });
await mkdir(resolve(root, '.lake'), { recursive: true });
const out = await mkdtemp(resolve(root, '.lake/docs-check-'));
for (const [name, source] of examples) {
  const file = resolve(out, `${name}.lean`);
  await writeFile(file, source + '\n', { flag: 'wx' });
  await run('lake', ['env', 'lean', file], { cwd: root });
  console.log(`PASS: ${name}`);
}
console.log(`${examples.size} Lean documentation examples passed; compatible library/package names retained. Fixtures: ${out}`);
