import test from 'node:test';
import assert from 'node:assert/strict';
import * as domain from '../../examples/generated/domain.mjs';
import { operations, decodeHttpReply, CallFailure } from '../../examples/adapters/tickets-client/operations.mjs';
import { nat } from '../../engine/LeanContract/Codecs.mjs';
import { summaryFromLean, summaryToLean, createTicketsClient } from '../../examples/adapters/tickets-service.mjs';

const seed = domain['Examples.Tickets.seed'].fields[0];
const identity = name => ({ namespace: 'leanreact.tickets', name, version: '1' });
const summary = operations.save.output;
const wireOf = lean => summary.encode(summaryFromLean(lean));

test('generated codecs preserve large revisions, nominal IDs and exact shapes; domain rules stay in Lean', () => {
  const big = 10n ** 200n;
  assert.equal(nat.decode(JSON.parse(JSON.stringify(nat.encode(big)))), big);
  for (const value of ['00', '+1', '1.0', '-1', ' 1']) assert.throws(() => nat.decode({ tag: 'nat', value }), CallFailure);
  assert.throws(() => nat.encode(1), /encode.nat/);
  const wire = summaryFromLean(seed[0]);
  wire.revision = big;
  const encoded = summary.encode(wire);
  assert.equal(encoded.revision.value, big.toString());
  assert.deepEqual(summary.decode(JSON.parse(JSON.stringify(encoded))), wire);
  assert.deepEqual(summaryFromLean(summaryToLean(wire)), wire);
  assert.throws(() => summary.decode({ ...encoded, extra: true }), /decode.unknown_field/);
  assert.throws(() => summary.decode({ ...encoded, id: { ...encoded.id, type: { package: 'leanreact.tickets', name: 'User' } } }), /identity.type_mismatch/);
  assert.throws(() => summary.decode({ ...encoded, revision: { tag: 'nat', value: 7 } }), /decode.invalid_natural/);
  // The generated client is a shape check; the compiled Lean parsers reject invalid domain values.
  const emptyTitle = summary.decode({ ...encoded, value: { ...encoded.value, title: '' } });
  assert.throws(() => summaryToLean(emptyTitle), /title.invalid/);
  assert.throws(() => summaryToLean(summary.decode({ ...encoded, value: { ...encoded.value, status: 'unknown' } })), /status.unknown/);
  assert.equal(operations.save.describePolicy, 'role ≥ editor');
});

test('non-2xx domain errors are decoded with their current revision and version mismatches stay distinct', () => {
  const body = { operation: identity('save'), tag: 'domainError', value: { tag: 'conflict', value: wireOf(seed[0]) } };
  const conflict = decodeHttpReply(operations.save, 409, body);
  assert.equal(conflict.ok, false);
  assert.equal(conflict.error.tag, 'conflict');
  assert.deepEqual(summaryToLean(conflict.error.value), seed[0]);
  assert.throws(() => decodeHttpReply(operations.save, 200, body), /response.invalid_domain_error/);
  assert.throws(() => decodeHttpReply(operations.save, 404, body), /response.invalid_domain_error/);
  assert.equal(decodeHttpReply(operations.save, 404, { ...body, value: { tag: 'notFound', value: null } }).error.tag, 'notFound');
  assert.throws(() => decodeHttpReply(operations.save, 409, { tag: 'incompatible', expected: { ...identity('save'), version: '2' }, received: identity('save') }),
    error => error.kind === 'incompatible');
  assert.throws(() => decodeHttpReply(operations.list, 200, { operation: identity('save'), tag: 'success', value: [] }), /response.operation_mismatch/);
  assert.throws(() => decodeHttpReply(operations.list, 200, { operation: identity('list'), tag: 'domainError', value: null }), /response.unexpected_domain_error/);
});

test('transport receives explicit public operations and keeps transport/decode errors distinct', async () => {
  const calls = [];
  const client = createTicketsClient({ fetch: async (url, init) => {
    calls.push({ url, body: JSON.parse(init.body) });
    return { status: 200, json: async () => ({ operation: identity('list'), tag: 'success', value: seed.map(wireOf) }) };
  } });
  const listed = await client.list();
  assert.equal(listed.length, 3);
  assert.deepEqual(listed, [...seed]);
  assert.deepEqual(calls[0], { url: '/api/tickets/list', body: { operation: identity('list'), kind: 'query', input: null } });
  await assert.rejects(createTicketsClient({ fetch: async () => { throw Error('offline'); } }).list(), error => error.kind === 'transport');
  await assert.rejects(createTicketsClient({ fetch: async () => ({ status: 200, json: async () => { throw Error('invalid'); } }) }).list(), error => error.kind === 'decode');
});
