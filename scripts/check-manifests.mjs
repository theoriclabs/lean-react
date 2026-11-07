// Every Lake manifest in the repository must resolve its dependencies to immutable Git
// revisions, or to path dependencies inside this repository. A manifest that records a path
// outside the checkout (a sibling clone, an absolute developer path) only builds on the machine
// that wrote it, which LA-12 rules out.
import { readFile, readdir } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { resolve, relative, isAbsolute, dirname } from 'node:path';

const root = fileURLToPath(new URL('../', import.meta.url));
async function discover(directory = '') {
  const result = [];
  for (const entry of await readdir(resolve(root, directory), { withFileTypes: true })) {
    if (entry.name.startsWith('.') || ['node_modules', 'generated', 'dist'].includes(entry.name)) continue;
    const path = directory ? directory + '/' + entry.name : entry.name;
    if (entry.isDirectory()) result.push(...await discover(path));
    else if (/^lake(?:-manifest\.json|file\.(?:lean|toml))$/.test(entry.name)) result.push(path);
  }
  return result;
}
const files = await discover();
const manifests = files.filter(file => file.endsWith('lake-manifest.json'));
let problems = 0;
let checked = 0;
for (const file of manifests) {
  const manifest = JSON.parse(await readFile(resolve(root, file), 'utf8'));
  for (const pkg of manifest.packages ?? []) {
    checked += 1;
    if (pkg.type === 'git') {
      if (!/^[0-9a-f]{40}$/.test(pkg.rev ?? '')) { console.error(`${file}: ${pkg.name} is not pinned to a commit`); problems += 1; }
      if (!/^https:\/\/github\.com\//.test(pkg.url ?? '')) { console.error(`${file}: ${pkg.name} is not fetched from GitHub over HTTPS`); problems += 1; }
      continue;
    }
    if (pkg.type === 'path') {
      const target = resolve(dirname(resolve(root, file)), pkg.dir);
      const inside = !relative(root, target).startsWith('..') && !isAbsolute(relative(root, target));
      if (!inside || isAbsolute(pkg.dir)) { console.error(`${file}: ${pkg.name} resolves outside the repository (${pkg.dir})`); problems += 1; }
      continue;
    }
    console.error(`${file}: ${pkg.name} has unknown source type ${pkg.type}`);
    problems += 1;
  }
}
// Compare declared pins with every discovered manifest.
const lakefiles = files.filter(file => /lakefile\.(?:lean|toml)$/.test(file));
const pins = new Map();
const record = (url, rev, where) => {
  if (!pins.has(url)) pins.set(url, new Map());
  const revs = pins.get(url);
  revs.set(rev, [...(revs.get(rev) ?? []), where]);
};
for (const file of lakefiles) {
  const text = await readFile(resolve(root, file), 'utf8');
  const pattern = file.endsWith('.toml') ? /git = "([^"]+)"\s*\nrev = "([^"]+)"/g : /\.git "([^"]+)" \(some "([^"]+)"\)/g;
  for (const [, url, rev] of text.matchAll(pattern)) record(url, rev, file);
}
for (const file of manifests)
  for (const pkg of JSON.parse(await readFile(resolve(root, file), 'utf8')).packages ?? [])
    if (pkg.type === 'git' && pkg.inputRev) record(pkg.url, pkg.inputRev, file);
for (const [url, revs] of pins) {
  if (revs.size === 1) continue;
  console.error(`${url} is pinned inconsistently: ${[...revs].map(([rev, files]) => `${rev} in ${files.join(', ')}`).join('; ')}`);
  problems += 1;
}
const resolved = new Map();
for (const file of manifests)
  for (const pkg of JSON.parse(await readFile(resolve(root, file), 'utf8')).packages ?? [])
    if (pkg.type === 'git') {
      const seen = resolved.get(pkg.url);
      if (seen && seen.rev !== pkg.rev) { console.error(`${pkg.url} resolves to ${seen.rev} in ${seen.file} but ${pkg.rev} in ${file}`); problems += 1; }
      else resolved.set(pkg.url, { rev: pkg.rev, file });
    }
if (problems > 0) { console.error(`${problems} manifest problem(s)`); process.exit(1); }
console.log(`Checked ${checked} Lake dependency entries across ${manifests.length} manifests: all Git-pinned or inside the repository.`);
console.log(`Checked ${pins.size} pinned sources across ${lakefiles.length} lakefiles and the manifests: all consistent.`);
