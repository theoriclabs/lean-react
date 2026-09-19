// Every Lake manifest in the repository must resolve its dependencies to immutable Git
// revisions, or to path dependencies inside this repository. A manifest that records a path
// outside the checkout (a sibling clone, an absolute developer path) only builds on the machine
// that wrote it, which LA-12 rules out.
import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { resolve, relative, isAbsolute, dirname } from 'node:path';

const root = fileURLToPath(new URL('../', import.meta.url));
const manifests = ['adapters/native/lake-manifest.json', 'examples/native/lake-manifest.json', 'lake-manifest.json'];
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
if (problems > 0) { console.error(`${problems} manifest problem(s)`); process.exit(1); }
console.log(`Checked ${checked} Lake dependency entries across ${manifests.length} manifests: all Git-pinned or inside the repository.`);
