// What dominates generated LeanJS modules: bytes per declaration, per module of origin, and
// declarations several modules each carry a copy of.
//   node scripts/size-report.mjs examples/generated/*.manifest.json [--top 15] [--json report.json]
import { readFile, stat, writeFile } from 'node:fs/promises';

const args = process.argv.slice(2);
const option = (name, fallback) => {
  const i = args.indexOf(name);
  if (i < 0) return fallback;
  const [value] = args.splice(i, 2).slice(1);
  return value;
};
const top = Number(option('--top', '15'));
const jsonOut = option('--json', null);
const manifests = args;
if (manifests.length === 0) { console.error('usage: size-report.mjs <file.manifest.json>… [--top N] [--json out]'); process.exit(2); }

const kb = bytes => `${(bytes / 1024).toFixed(1)} KB`;
const table = (rows, width = 60) => rows.map(([name, bytes]) => `  ${kb(bytes).padStart(9)}  ${name.length > width ? name.slice(0, width - 1) + '…' : name}`).join('\n');
const sorted = map => [...map].sort((a, b) => b[1] - a[1]);
const groupOf = module => module === null ? '(constructors and core builtins)'
  : module.split('.').slice(0, module.startsWith('Init') || module.startsWith('Std') || module.startsWith('Lean') ? 1 : 2).join('.');

const report = { modules: [], shared: [] };
const owners = new Map();
for (const file of manifests) {
  const manifest = JSON.parse(await readFile(file, 'utf8'));
  const output = file.replace(/\.manifest\.json$/, '.mjs');
  const total = (await stat(output)).size;
  const declarations = manifest.declarations ?? [];
  const counted = declarations.reduce((sum, d) => sum + (d.bytes ?? 0), 0);
  const byGroup = new Map();
  for (const d of declarations) {
    byGroup.set(groupOf(d.module ?? null), (byGroup.get(groupOf(d.module ?? null)) ?? 0) + (d.bytes ?? 0));
    if (!d.importedFrom) {
      const entry = owners.get(d.name) ?? { bytes: d.bytes ?? 0, files: [] };
      entry.files.push(output);
      owners.set(d.name, entry);
    }
  }
  const largest = [...declarations].sort((a, b) => (b.bytes ?? 0) - (a.bytes ?? 0)).slice(0, top).map(d => [d.name, d.bytes ?? 0]);
  report.modules.push({ file: output, bytes: total, declarations: declarations.length, declarationBytes: counted,
    otherBytes: total - counted, byGroup: Object.fromEntries(sorted(byGroup)), largest });
  console.log(`${output}: ${kb(total)}, ${declarations.length} declarations (${kb(counted)}); runtime, imports and exports ${kb(total - counted)}`);
  console.log(` by module of origin:\n${table(sorted(byGroup).slice(0, top))}`);
  console.log(` largest declarations:\n${table(largest)}`);
}
if (manifests.length > 1) {
  const shared = [...owners].filter(([, entry]) => entry.files.length > 1);
  const duplicated = shared.reduce((sum, [, entry]) => sum + entry.bytes * (entry.files.length - 1), 0);
  report.shared = shared.map(([name, entry]) => ({ name, bytes: entry.bytes, copies: entry.files.length }));
  console.log(`\n${shared.length} declarations are compiled into more than one module: ${kb(duplicated)} of repeated copies.`);
  console.log(table(shared.sort((a, b) => b[1].bytes * b[1].files.length - a[1].bytes * a[1].files.length).slice(0, top)
    .map(([name, entry]) => [`${name} ×${entry.files.length}`, entry.bytes * entry.files.length])));
}
if (jsonOut) await writeFile(jsonOut, JSON.stringify(report, null, 2));
