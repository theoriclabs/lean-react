import test from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdtemp, readFile, readdir, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { operations, manifest } from '../../examples/cafe/wire/operations.mjs';

test('the committed café client is what the native contract generates', async () => {
  const scratch = await mkdtemp(join(tmpdir(), 'cafe-client-'));
  try {
    execFileSync('lake', ['env', 'lean', '--run', 'GenerateCafeClient.lean', scratch], { cwd: resolve('adapters/native'), encoding: 'utf8' });
    const files = (await readdir(scratch)).sort();
    assert.deepEqual(files, ['manifest.json', 'operations.d.mts', 'operations.d.ts', 'operations.mjs']);
    for (const file of files)
      assert.equal(await readFile(join(scratch, file), 'utf8'), await readFile(resolve('examples/cafe/wire', file), 'utf8'),
        `${file} differs; run: cd adapters/native && lake env lean --run GenerateCafeClient.lean`);
  } finally { await rm(scratch, { recursive: true, force: true }); }
  assert.deepEqual(Object.keys(operations), ['list', 'save', 'delete']);
  assert.deepEqual(manifest.operations.map(op => [op.name, op.http.path, op.metadata.describePolicy]),
    [['list', '/api/recipes/list', 'authenticated'], ['save', '/api/recipes/save', 'authenticated'], ['delete', '/api/recipes/delete', 'authenticated']]);
  assert.equal(operations.save.errorStatus('recipe_limit'), 422);
});
