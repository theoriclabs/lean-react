import test from 'node:test';
import assert from 'node:assert/strict';
import * as domain from '../../examples/generated/domain.mjs';
import { encodeSummary, decodeSummary, encodeNat, decodeNat, decodeReply, createTicketsClient, CallFailure } from '../../examples/adapters/tickets-wire.mjs';

const seed = domain['Examples.Tickets.seed'].fields[0];
const identity = name => ({ namespace: 'leanreact.tickets', name, version: '1' });

test('wire adapter preserves large revisions, nominal IDs, and domain validation', () => {
  const big = 10n ** 200n;
  assert.equal(decodeNat(JSON.parse(JSON.stringify(encodeNat(big)))), big);
  for (const value of ['00', '+1', '1.0', '-1', ' 1']) assert.throws(() => decodeNat({ tag: 'nat', value }), CallFailure);
  const wire = encodeSummary(seed[0]);
  wire.revision = encodeNat(big);
  assert.deepEqual(encodeSummary(decodeSummary(wire)), wire);
  assert.throws(() => decodeSummary({ ...wire, extra: true }), /decode.object/);
  assert.throws(() => decodeSummary({ ...wire, id: { ...wire.id, type: { package: 'leanreact.tickets', name: 'User' } } }), /identity.type_mismatch/);
  assert.throws(() => decodeSummary({ ...wire, value: { ...wire.value, title: '' } }), /title.invalid/);
  assert.throws(() => decodeSummary({ ...wire, value: { ...wire.value, status: 'unknown' } }), /status.unknown/);
});

test('non-2xx domain errors are decoded with their current revision and version mismatches stay distinct', () => {
  const body = { operation: identity('save'), tag: 'domainError', value: { tag: 'conflict', value: encodeSummary(seed[0]) } };
  const conflict = decodeReply('save', 409, body);
  assert.equal(conflict.tag, 'Except.error');
  assert.equal(conflict.fields[0].tag, 'Examples.Tickets.SaveError.conflict');
  assert.deepEqual(conflict.fields[0].fields[0], seed[0]);
  assert.throws(() => decodeReply('save', 200, body), /response.invalid_domain_error/);
  assert.throws(() => decodeReply('save', 409, { tag: 'incompatible', expected: { ...identity('save'), version: '2' }, received: identity('save') }),
    error => error.kind === 'incompatible');
  assert.throws(() => decodeReply('list', 200, { operation: identity('save'), tag: 'success', value: [] }), /response.operation_mismatch/);
});

test('transport receives explicit public operations and keeps transport/decode errors distinct', async () => {
  const calls = [];
  const client = createTicketsClient({ fetch: async (url, init) => {
    calls.push({ url, body: JSON.parse(init.body) });
    return { status: 200, json: async () => ({ operation: identity('list'), tag: 'success', value: seed.map(encodeSummary) }) };
  } });
  assert.equal((await client.list()).length, 3);
  assert.deepEqual(calls[0], { url: '/api/tickets/list', body: { operation: identity('list'), kind: 'query', input: null } });
  await assert.rejects(createTicketsClient({ fetch: async () => { throw Error('offline'); } }).list(), error => error.kind === 'transport');
  await assert.rejects(createTicketsClient({ fetch: async () => ({ status: 200, json: async () => { throw Error('invalid'); } }) }).list(), error => error.kind === 'decode');
});
