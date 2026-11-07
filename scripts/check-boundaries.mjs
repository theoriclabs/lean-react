// Inspect Lean's actual import closure and evaluated intrinsic registry, then import the
// real adapter namespace so re-exports and aliases are covered too.
import assert from 'node:assert/strict';
import { fileURLToPath } from 'node:url';
import { capture, run } from './process.mjs';
import * as adapter from '../engine/adapters/leanjs-react.mjs';

const cwd = fileURLToPath(new URL('../', import.meta.url));
await run('lake', ['build', 'Examples', 'LeanReact.Domain'], { cwd });
const { code, output } = await capture('lake', ['env', 'lean', 'scripts/LeanReactClosure.lean'], { cwd });
assert.equal(code, 0, output);
const { modules, intrinsics } = JSON.parse(output.trim().split('\n').at(-1));
assert.ok(intrinsics.length > 0, 'Empty intrinsic registry');
for (const { leanName, exportName } of intrinsics)
  assert.ok(Object.hasOwn(adapter, exportName), `${leanName}: adapter does not export ${exportName}`);
console.log(`PASS UI libraries and Examples: ${modules} imports, no removed or native server modules`);
console.log(`PASS all ${intrinsics.length} React intrinsics have adapter exports`);
