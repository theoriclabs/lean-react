// `leanreact build|test` (scripts/leanreact.mjs) on this repository's examples. Needs Chromium.
import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, readFile, readdir, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { capture } from '../../scripts/process.mjs';
import { projectRoot } from '../../scripts/build.mjs';

const cli = (args) => capture('node', ['scripts/leanreact.mjs', ...args], { cwd: projectRoot });
const pages = ['--page', '/=Examples.Showcase.Counter', '--page', '/styles=Examples.Styles.Demo',
  '--page', '/diagram/*=Examples.Diagram.Demo'];

test('build writes one bundle for several pages, the extracted styles and a page shell; test mounts each page', async () => {
  const out = await mkdtemp(join(tmpdir(), 'leanreact-cli-'));
  const result = await cli(['test', 'Examples.Showcase', 'Examples.Styles', 'Examples.Diagram', ...pages,
    '--styles', 'Examples.Styles', '--css', 'examples/web/style.css', '--title', 'CLI <check>', '--out', out]);
  assert.equal(result.code, 0, result.output);
  const files = await readdir(out);
  for (const file of ['app.js', 'index.html', 'styles.css', 'style.css', 'screenshots']) assert.ok(files.includes(file), file);
  const html = await readFile(join(out, 'index.html'), 'utf8');
  assert.match(html, /<title>CLI &lt;check><\/title>/);
  assert.match(html, /<link rel="stylesheet" href="\/styles.css" \/>/);
  assert.match(await readFile(join(out, 'styles.css'), 'utf8'), /^:root\{--accent:/);
  const shots = await readdir(join(out, 'screenshots'));
  assert.deepEqual(shots.sort(), ['diagram-desktop.png', 'diagram-mobile.png', 'index-desktop.png', 'index-mobile.png',
    'styles-desktop.png', 'styles-mobile.png']);
  for (const line of ['ok   / at desktop', 'ok   /styles at mobile', 'ok   /diagram/ at desktop']) assert.ok(result.output.includes(line), line);
});

test('test fails on horizontal overflow, and names the page and width', async () => {
  const out = await mkdtemp(join(tmpdir(), 'leanreact-cli-'));
  const wide = join(out, 'wide.css');
  await writeFile(wide, '#root { min-width: 900px; }\n');
  const result = await cli(['test', 'Examples.Showcase', '--page', '/=Examples.Showcase.Counter', '--css', wide, '--out', out]);
  assert.notEqual(result.code, 0);
  assert.match(result.output, /\/ \(mobile, 390px\): horizontal overflow of \d+px/);
  assert.doesNotMatch(result.output, /\(desktop, 1280px\): horizontal overflow/);
});

test('an unknown page declaration fails the build', async () => {
  const out = await mkdtemp(join(tmpdir(), 'leanreact-cli-'));
  const result = await cli(['test', 'Examples.Showcase', '--page', '/=Examples.Showcase.Nope', '--out', out]);
  assert.notEqual(result.code, 0);
  assert.match(result.output, /unknown|Unknown/);
});
