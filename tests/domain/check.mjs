// Endpoint pages (`form`, `call`, `load`, `App`) over LeanAPI's `TestsCore.PostPart1` domain:
// compile the fixtures, check the rejected pages fail with their expected messages, generate the
// LeanJS module and client, then run the jsdom tests.
import { mkdir, readFile, readdir } from 'node:fs/promises';
import path from 'node:path';
import { capture, run } from '../../scripts/process.mjs';
import { projectRoot } from '../../scripts/build.mjs';

const cwd = projectRoot;
const build = path.join(cwd, 'tests/domain/.build');
await mkdir(path.join(build, 'tests/domain'), { recursive: true });
await run('lake', ['build', 'LeanReactDomain', 'TestsCore.PostPart1', 'LeanContract.Browser', 'LeanContract.Generate', 'LeanApi.Core.Memory'], { cwd });
const base = (await capture('lake', ['env', 'printenv', 'LEAN_PATH'], { cwd })).output.trim();
const env = { ...process.env, LEAN_PATH: `${build}${path.delimiter}${base}` };
const lean = (args, options = {}) => run('lean', args, { cwd, env, ...options });

for (const module of ['SignUpEvolution', 'PostViews', 'Browser']) {
  await lean(['-o', path.join(build, `tests/domain/${module}.olean`), `tests/domain/${module}.lean`]);
}

const expected = JSON.parse(await readFile(path.join(cwd, 'tests/domain/negative/expected.json'), 'utf8'));
const negatives = (await readdir(path.join(cwd, 'tests/domain/negative'))).filter(name => name.endsWith('.lean'));
for (const file of negatives) {
  const name = file.slice(0, -'.lean'.length);
  if (!(name in expected)) throw new Error(`tests/domain/negative/${file} has no expected message`);
  const { code, output } = await capture('lean', [`tests/domain/negative/${file}`], { cwd, env });
  if (code === 0) throw new Error(`tests/domain/negative/${file} compiled; expected: ${expected[name]}`);
  if (!output.includes(expected[name])) throw new Error(`tests/domain/negative/${file} failed differently:\n${output}`);
}
console.log(`Domain page rejections: ${negatives.length} fixtures fail as expected.`);

await lean(['--run', 'tests/domain/Generate.lean'], { stdio: ['ignore', 'ignore', 'inherit'] });
await run('node', ['--test', 'tests/domain/app.test.mjs', 'tests/domain/browser.test.mjs'], { cwd });
