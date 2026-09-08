import test from 'node:test';
import assert from 'node:assert/strict';
import { createHttpClient, defineHttpOperation, decodeHttpReply, encodeNat, decodeNat, CallFailure } from '../../engine/LeanContract/Fetch.mjs';

const identity = { namespace: 'independent.inventory', name: 'reserve', version: '7' };
const operation = defineHttpOperation({
  identity, kind: 'command', path: '/commands/reserve', encodeInput: encodeNat, decodeOutput: decodeNat,
  decodeError(value) {
    if (value !== 'capacity') throw new CallFailure('decode', 'inventory.invalid_error');
    return value;
  },
  errorStatus: () => 422,
});

test('generic fetch executes a third independently registered operation with exact inputs', async () => {
  const amount = 10n ** 100n, calls = [];
  const spec = { ...operation, identity: { ...identity } };
  const client = createHttpClient({ operations: [spec], baseURL: 'https://fixture.invalid/', fetch: async (url, init) => {
    calls.push({ url, init });
    return { status: 200, json: async () => ({ operation: identity, tag: 'success', value: encodeNat(amount) }) };
  } });
  spec.path = '/changed'; spec.identity.name = 'changed';
  assert.deepEqual(await client.call(identity, amount), { ok: true, value: amount });
  assert.equal(calls[0].url, 'https://fixture.invalid/commands/reserve');
  assert.deepEqual(JSON.parse(calls[0].init.body), { operation: identity, kind: 'command', input: encodeNat(amount) });
  assert.equal(calls[0].init.redirect, 'error');
  assert.equal(calls[0].init.credentials, 'same-origin');
  await assert.rejects(client.call({ ...identity, version: 'old' }, amount), error => error.kind === 'incompatible');
  await assert.rejects(client.call({ ...identity, name: 'unregistered' }, amount), /operation.not_found/);
  assert.equal(calls.length, 1, 'unknown version never performs fetch');
});

test('generic response handling validates domain errors, identity, status and authority', () => {
  const body = { operation: identity, tag: 'domainError', value: 'capacity' };
  assert.deepEqual(decodeHttpReply(operation, 422, body), { ok: false, error: 'capacity' });
  assert.throws(() => decodeHttpReply(operation, 200, body), /response.invalid_domain_error/);
  assert.throws(() => decodeHttpReply(operation, 422, { ...body, value: 'unknown' }), /inventory.invalid_error/);
  assert.throws(() => decodeHttpReply(operation, 422, { ...body, operation: { ...identity, version: '8' } }), /response.operation_mismatch/);
  for (const [tag, status] of [['unauthenticated', 401], ['forbidden', 403]]) {
    assert.throws(() => decodeHttpReply(operation, status, { tag }), error => error.kind === tag);
    assert.throws(() => decodeHttpReply(operation, 200, { tag }), error => error.kind === 'protocol');
  }
  assert.throws(() => decodeHttpReply(operation, 409, { tag: 'incompatible', expected: { ...identity, version: '8' }, received: identity }), error => error.kind === 'incompatible');
  assert.throws(() => decodeHttpReply(operation, 201, { operation: identity, tag: 'success', value: encodeNat(1n) }), /response.status_mismatch/);
});

test('client assembly rejects duplicate exports, route aliases and incomplete codecs', () => {
  const fetch = () => { throw Error('must not fetch'); };
  assert.throws(() => createHttpClient({ operations: [operation, operation], fetch }), /operation.duplicate_identity/);
  assert.throws(() => createHttpClient({ operations: [operation, { ...operation, identity: { ...identity, version: '8' } }], fetch }), /http.ambiguous_path/);
  for (const path of ['reserve', '//reserve', '/x/../reserve', '/x//reserve', '/%72eserve', '/reserve/'])
    assert.throws(() => defineHttpOperation({ ...operation, path }), /http.invalid_literal_path/);
  assert.throws(() => defineHttpOperation({ ...operation, errorStatus: undefined }), /incomplete_error_policy/);
  for (const baseURL of ['https://u:p@fixture.invalid', 'https://fixture.invalid/base', 'file:///data', 'https://fixture.invalid/?token=not-a-secret'])
    assert.throws(() => createHttpClient({ operations: [operation], baseURL, fetch }), /must be an origin/);
});

test('cancellation during response decoding remains cancellation and delivers no value', async () => {
  const controller = new AbortController();
  const client = createHttpClient({ operations: [operation], fetch: async () => ({
    status: 200, json: async () => {
      controller.abort();
      return { operation: identity, tag: 'success', value: encodeNat(1n) };
    },
  }) });
  await assert.rejects(client.call(identity, 1n, { signal: controller.signal }), error => error.kind === 'cancelled');
});
