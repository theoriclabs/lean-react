import test from 'node:test';
import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { mkdtemp, readFile, readdir, rm, stat } from 'node:fs/promises';
import { resolve, join, relative } from 'node:path';

const run = promisify(execFile);
const root = resolve(import.meta.dirname, '../..');
// Scaffold under the repository so the generated project resolves this checkout's node_modules.
const parent = resolve(root, '.lake/scaffold');
const full = process.env.LEANAPP_SCAFFOLD_FULL === '1';

async function walk(dir) {
  const out = [];
  for (const entry of await readdir(dir, { withFileTypes: true })) {
    const path = join(dir, entry.name);
    if (entry.isDirectory()) { if (!['node_modules', '.lake', 'dist', 'web/generated'].includes(entry.name)) out.push(...await walk(path)); }
    else out.push(path);
  }
  return out;
}

test('leanapp new scaffolds a complete, substituted project', { timeout: 120000 }, async () => {
  await (await import('node:fs/promises')).mkdir(parent, { recursive: true });
  const dir = await mkdtemp(resolve(parent, 'demo-'));
  await rm(dir, { recursive: true });
  const { stdout } = await run('node', ['scripts/new-app.mjs', '--name', 'demo_notes', '--namespace', 'demo', '--out', dir], { cwd: root });
  assert.match(stdout, /Scaffolded DemoNotes/);
  const expected = ['package.json', 'lakefile.lean', 'lean-toolchain', 'Generate.lean', 'DemoNotes.lean',
    'DemoNotes/Domain.lean', 'DemoNotes/Contracts.lean', 'DemoNotes/UI/App.lean',
    'native/lakefile.lean', 'native/lean-toolchain', 'native/Main.lean', 'native/Checks.lean', 'native/GenerateClient.lean',
    'native/DemoNotesNative.lean', 'native/DemoNotesNative/Storage.lean', 'native/DemoNotesNative/Application.lean',
    'web/index.html', 'web/main.mjs', 'web/style.css', 'gateway/serve.mjs',
    'scripts/build.mjs', 'scripts/dev.mjs', 'scripts/package.mjs', 'scripts/lib.mjs', 'scripts/browser-server.mjs',
    'tests/http/api.test.mjs', 'tests/browser/app.spec.mjs', 'playwright.config.mjs', 'deploy/Dockerfile', 'README.md', '.gitignore'];
  for (const file of expected) assert.ok((await stat(join(dir, file))).isFile(), `missing ${file}`);
  const files = await walk(dir);
  for (const file of files) {
    const text = await readFile(file, 'utf8');
    assert.ok(!text.includes('{{'), `unsubstituted placeholder in ${relative(dir, file)}`);
    assert.ok(!file.includes('__Name__'), `unsubstituted path ${relative(dir, file)}`);
  }
  const pkg = JSON.parse(await readFile(join(dir, 'package.json'), 'utf8'));
  assert.equal(pkg.name, 'demo_notes');
  const lakefile = await readFile(join(dir, 'native/lakefile.lean'), 'utf8');
  const head = (await run('git', ['rev-parse', 'HEAD'], { cwd: root })).stdout.trim();
  assert.ok(lakefile.includes(`.git "https://github.com/theoriclabs/lean-react" (some "${head}") none`), 'lean-react pinned to this commit');
  for (const pin of ['theoriclabs/LeanDB" (some "v0.4.0")', 'theoriclabs/leanhttp" (some "v0.3.1")', 'theoriclabs/leanws" (some "40900ccb', 'leanprover/leansqlite" (some "0be4df90'])
    assert.ok(lakefile.includes(pin), `native pin present: ${pin}`);
  assert.ok((await readFile(join(dir, 'DemoNotes/Contracts.lean'), 'utf8')).includes('def packageId := "demo"'));
  // web/main.mjs is JSX for esbuild; every Node-executed script must parse as plain ESM.
  for (const file of files.filter(f => f.endsWith('.mjs') && !relative(dir, f).startsWith('web/'))) await run('node', ['--check', file]);
  const readme = await readFile(join(dir, 'README.md'), 'utf8');
  for (const command of ['npm install', 'npm run build', '(cd native && lake build)', 'npm test']) assert.ok(readme.includes(command), `README documents ${command}`);
  await rm(dir, { recursive: true });
});

test('a scaffolded project builds against this checkout and passes its own tests', { skip: !full && 'set LEANAPP_SCAFFOLD_FULL=1 (npm run test:framework:native runs it)', timeout: 1800000 }, async () => {
  await (await import('node:fs/promises')).mkdir(parent, { recursive: true });
  const dir = await mkdtemp(resolve(parent, 'full-'));
  await rm(dir, { recursive: true });
  await run('node', ['scripts/new-app.mjs', '--name', 'demo_notes', '--namespace', 'demo', '--out', dir], { cwd: root });
  const packages = resolve(root, 'adapters/native/.lake/packages');
  // The scaffold's own `npm test` must not report to this runner as a child (NODE_TEST_CONTEXT).
  const { NODE_TEST_CONTEXT: _nested, ...inherited } = process.env;
  const env = { ...inherited,
    LEANAPP_LEANREACT_SOURCE: root, LEANAPP_LEANDB_SOURCE: resolve(packages, 'leandb'),
    LEANAPP_LEANHTTP_SOURCE: resolve(packages, 'leanhttp'), LEANAPP_LEANWS_SOURCE: resolve(packages, 'leanws'),
    LEANAPP_LEANSQLITE_SOURCE: resolve(packages, 'leansqlite') };
  const overrides = ['leanreact', 'leanapp_native', 'leandb', 'leanhttp', 'leanws', 'leansqlite'].map(name =>
    `-K${name}=${name === 'leanreact' ? root : name === 'leanapp_native' ? resolve(root, 'adapters/native') : resolve(packages, name)}`);
  const exec = (cmd, args, cwd) => run(cmd, args, { cwd, env, maxBuffer: 64 * 1024 * 1024 });
  // The README's commands, with the local-source overrides the README documents.
  await exec('npm', ['run', 'build'], dir);
  await exec('lake', [...overrides, 'build'], resolve(dir, 'native'));
  await exec(resolve(dir, 'native/.lake/build/bin/demo_notes_checks'), [], resolve(dir, 'native'));
  const { stdout } = await exec('npm', ['test'], dir);
  assert.match(stdout, /pass 1/);
  await rm(dir, { recursive: true });
});
