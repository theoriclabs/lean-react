// Browser transport for explicitly registered operation codecs, independent of LeanJS ABI.
export class CallFailure extends Error {
  constructor(kind, code, detail = null) {
    super(code); this.name = 'CallFailure'; this.kind = kind; this.code = code; this.detail = detail;
  }
}

export function wireObject(value, keys) {
  if (!value || typeof value !== 'object' || Array.isArray(value) ||
      Object.keys(value).length !== keys.length || keys.some(key => !Object.hasOwn(value, key)))
    throw new CallFailure('decode', 'decode.object', value);
  return value;
}

function checkedIdentity(value) {
  wireObject(value, ['namespace', 'name', 'version']);
  if (['namespace', 'name', 'version'].some(key => typeof value[key] !== 'string' || value[key].length === 0))
    throw new CallFailure('decode', 'operation.invalid_identity', value);
  return value;
}

export function equalIdentity(left, right) {
  checkedIdentity(left); checkedIdentity(right);
  return left.namespace === right.namespace && left.name === right.name && left.version === right.version;
}

export function encodeNat(value) {
  if (typeof value !== 'bigint' || value < 0n) throw new CallFailure('decode', 'encode.nat', value);
  return { tag: 'nat', value: value.toString() };
}

export function decodeNat(value) {
  wireObject(value, ['tag', 'value']);
  if (value.tag !== 'nat' || typeof value.value !== 'string' || !/^(0|[1-9][0-9]*)$/.test(value.value))
    throw new CallFailure('decode', 'decode.nat', value);
  return BigInt(value.value);
}

const identityKey = value => JSON.stringify([value.namespace, value.name, value.version]);

export function defineHttpOperation(spec) {
  const identity = Object.freeze({ ...checkedIdentity(spec.identity) });
  if (!['query', 'command'].includes(spec.kind)) throw new TypeError('operation.invalid_kind');
  if (typeof spec.path !== 'string' || !/^\/[A-Za-z0-9/_.-]*$/.test(spec.path) ||
      (spec.path !== '/' && spec.path.endsWith('/')) || spec.path.includes('//') ||
      spec.path.split('/').some(part => part === '.' || part === '..')) throw new TypeError('http.invalid_literal_path');
  for (const codec of ['encodeInput', 'decodeOutput']) {
    if (typeof spec[codec] !== 'function') throw new TypeError(`operation.missing_${codec}`);
  }
  if ((typeof spec.decodeError === 'function') !== (typeof spec.errorStatus === 'function'))
    throw new TypeError('operation.incomplete_error_policy');
  return Object.freeze({ ...spec, identity });
}

// Domain results remain values. Transport/authority/protocol failures are CallFailure.
export function decodeHttpReply(operation, status, body) {
  const expected = operation.identity;
  const protocol = code => { throw new CallFailure('protocol', code, body); };
  if (body?.tag === 'success' || body?.tag === 'domainError') {
    wireObject(body, ['operation', 'tag', 'value']);
    if (!equalIdentity(body.operation, expected)) protocol('response.operation_mismatch');
    if (body.tag === 'success') {
      if (status !== 200) protocol('response.status_mismatch');
      return { ok: true, value: operation.decodeOutput(body.value) };
    }
    if (!operation.decodeError) protocol('response.unexpected_domain_error');
    const error = operation.decodeError(body.value);
    const expectedStatus = operation.errorStatus(error);
    if (!Number.isInteger(expectedStatus) || expectedStatus < 400 || expectedStatus > 599 || status !== expectedStatus)
      protocol('response.invalid_domain_error');
    return { ok: false, error };
  }
  if (body?.tag === 'incompatible' && status === 409) {
    wireObject(body, ['tag', 'expected', 'received']);
    if (!equalIdentity(body.received, expected)) protocol('response.operation_mismatch');
    checkedIdentity(body.expected);
    throw new CallFailure('incompatible', 'contract.incompatible', body);
  }
  if (body?.tag === 'unauthenticated' && status === 401) throw new CallFailure('unauthenticated', 'auth.required');
  if (body?.tag === 'forbidden' && status === 403) throw new CallFailure('forbidden', 'auth.forbidden');
  if (body?.tag === 'decode' && status === 400) throw new CallFailure('decode', 'server.decode', body.errors);
  if (body?.tag === 'protocol' && status >= 400 && status <= 599) {
    if (typeof body.code !== 'string') throw new CallFailure('decode', 'decode.string', body.code);
    protocol(body.code);
  }
  protocol('response.unknown_envelope');
}

export function createHttpClient({ operations, baseURL = '', fetch: fetchImpl = globalThis.fetch } = {}) {
  if (typeof fetchImpl !== 'function') throw new TypeError('fetch implementation required');
  if (baseURL !== '') {
    const url = new URL(baseURL);
    if (!['http:', 'https:'].includes(url.protocol) || url.username || url.password ||
        url.search || url.hash || url.pathname !== '/') throw new TypeError('HTTP baseURL must be an origin');
    baseURL = url.origin;
  }
  const registry = new Map(), paths = new Set();
  for (const spec of operations) {
    const operation = defineHttpOperation(spec), key = identityKey(operation.identity);
    if (registry.has(key)) throw new TypeError('operation.duplicate_identity');
    if (paths.has(operation.path)) throw new TypeError('http.ambiguous_path');
    registry.set(key, operation); paths.add(operation.path);
  }
  return Object.freeze({
    async call(identity, input, { signal } = {}) {
      checkedIdentity(identity);
      const operation = registry.get(identityKey(identity));
      if (!operation) {
        const named = [...registry.values()].find(candidate =>
          candidate.identity.namespace === identity.namespace && candidate.identity.name === identity.name);
        if (named) throw new CallFailure('incompatible', 'contract.incompatible', {
          expected: named.identity, received: identity,
        });
        throw new CallFailure('protocol', 'operation.not_found');
      }
      const request = { operation: operation.identity, kind: operation.kind, input: operation.encodeInput(input) };
      let response;
      try {
        response = await fetchImpl(`${baseURL}${operation.path}`, {
          method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(request),
          signal, credentials: 'same-origin', redirect: 'error',
        });
      } catch (cause) {
        throw new CallFailure(signal?.aborted ? 'cancelled' : 'transport',
          signal?.aborted ? 'request.cancelled' : 'request.failed', cause);
      }
      let body;
      try { body = await response.json(); }
      catch (cause) {
        throw new CallFailure(signal?.aborted ? 'cancelled' : 'decode',
          signal?.aborted ? 'request.cancelled' : 'response.invalid_json', cause);
      }
      if (signal?.aborted) throw new CallFailure('cancelled', 'request.cancelled');
      return decodeHttpReply(operation, response.status, body);
    },
  });
}
