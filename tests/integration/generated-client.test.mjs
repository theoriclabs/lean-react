import test from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdtemp, readFile, readdir, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { operations, manifest, manifestPath, createClient, canonical, types } from '../../examples/adapters/tickets-client/operations.mjs';
import { CallFailure } from '../../engine/LeanContract/Fetch.mjs';

const clientDir = resolve('examples/adapters/tickets-client');
const lean = (file, ...args) => execFileSync('lake', ['env', 'lean', '--run', file, ...args], { encoding: 'utf8' });
const roundTrip = (codec, wire) => canonical(codec.encode(codec.decode(wire)));

test('regenerating the Tickets client reproduces the committed files byte for byte', async () => {
  const scratch = await mkdtemp(join(tmpdir(), 'tickets-client-'));
  try {
    lean('examples/lean/Examples/GenerateClient.lean', scratch);
    const files = (await readdir(scratch)).sort();
    assert.deepEqual(files, ['manifest.json', 'operations.d.mts', 'operations.d.ts', 'operations.mjs']);
    for (const file of files)
      assert.equal(await readFile(join(scratch, file), 'utf8'), await readFile(join(clientDir, file), 'utf8'), `${file} differs; run npm run build`);
  } finally { await rm(scratch, { recursive: true, force: true }); }
});

test('Lean codec fixtures decode in the generated client and re-encode identically', async () => {
  const fixtures = JSON.parse(lean('tests/integration/ClientFixtures.lean'));
  assert.equal(canonical(fixtures.manifest), canonical(manifest));
  assert.equal(canonical(JSON.parse(await readFile(join(clientDir, 'manifest.json'), 'utf8'))), canonical(manifest));
  assert.equal(roundTrip(operations.list.input, fixtures.list.input), canonical(fixtures.list.input));
  assert.equal(roundTrip(operations.list.output, fixtures.list.output), canonical(fixtures.list.output));
  const listed = operations.list.output.decode(fixtures.list.output);
  assert.equal(listed.at(-1).revision, 2n ** 128n + 9007199254740993n);
  assert.equal(typeof listed[0].revision, 'bigint');
  assert.equal(roundTrip(operations.save.input, fixtures.save.input), canonical(fixtures.save.input));
  assert.equal(roundTrip(operations.save.output, fixtures.save.output), canonical(fixtures.save.output));
  fixtures.save.errors.forEach((error, index) => {
    assert.equal(roundTrip(operations.save.error, error), canonical(error));
    assert.equal(operations.save.errorStatus(operations.save.error.decode(error)), fixtures.save.statuses[index]);
  });
  assert.equal(operations.save.errorStatus({ tag: 'unknown' }), undefined);
  const errors = types.ontology_ValidationError;
  assert.ok(errors, 'the envelope error type is generated');
  const decoded = fixtures.save.decodeError.errors.map(error => errors.decode(error));
  assert.deepEqual(decoded[0].path, [{ tag: 'key', value: 'title' }]);
  assert.equal(decoded[0].code, 'title.empty');
  assert.equal(canonical(decoded.map(error => errors.encode(error))), canonical(fixtures.save.decodeError.errors));
});

test('the client refuses a stale bundle before the first request and forwards signals', async () => {
  const served = JSON.parse(JSON.stringify(manifest));
  served.operations[0].version = '2';
  const requests = [];
  const fetchImpl = async (url, init) => {
    requests.push(url);
    if (url === manifestPath) return { json: async () => served };
    return { status: 200, json: async () => ({ operation: operations.list.identity, tag: 'success', value: [] }) };
  };
  const stale = createClient({ fetch: fetchImpl, verify: true });
  await assert.rejects(stale.call(operations.list.identity, null), error => error instanceof CallFailure && error.kind === 'incompatible' && error.code === 'contract.stale_manifest');
  assert.deepEqual(requests, [manifestPath]);
  served.operations[0].version = '1';
  const fresh = createClient({ fetch: fetchImpl, verify: true });
  assert.deepEqual((await fresh.call(operations.list.identity, null)).value, []);
  assert.deepEqual((await fresh.call(operations.list.identity, null)).value, []);
  assert.deepEqual(requests.slice(1), [manifestPath, '/api/tickets/list', '/api/tickets/list']);
  const unverified = createClient({ fetch: fetchImpl });
  await unverified.call(operations.list.identity, null);
  assert.equal(requests.at(-1), '/api/tickets/list');
  assert.equal(requests.filter(url => url === manifestPath).length, 2);
  const controller = new AbortController();
  controller.abort();
  await assert.rejects(unverified.call(operations.list.identity, null, { signal: controller.signal }), error => error.kind === 'cancelled');
});

test('generated operations reject malformed inputs before any request is sent', async () => {
  let sent = 0;
  const client = createClient({ fetch: async () => { sent++; return { status: 200, json: async () => ({}) }; } });
  for (const input of [null, {}, { id: 'x' }, { ...operations.save.input.decode(JSON.parse(lean('tests/integration/ClientFixtures.lean')).save.input), expectedRevision: 1 }])
    await assert.rejects(client.call(operations.save.identity, input), error => error.kind === 'decode');
  assert.equal(sent, 0);
});
