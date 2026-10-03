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

// A route is either the milestone-1 RPC form (POST, literal path, Contract request envelope)
// or an explicit route (DDD-LAPI-05): GET/POST, a `/x/:name` template whose parameters are
// input fields, and a plain body holding the remaining input fields.
function checkRoute(spec) {
  const method = spec.method ?? 'POST', body = spec.body ?? 'envelope', params = spec.params ?? [];
  if (!['GET', 'POST'].includes(method)) throw new TypeError('http.invalid_method');
  if (!['envelope', 'plain'].includes(body)) throw new TypeError('http.invalid_body');
  if (!Array.isArray(params) || params.some(name => typeof name !== 'string' || name === '')) throw new TypeError('http.invalid_params');
  const segments = spec.path.split('/').slice(1).filter(part => part.startsWith(':')).map(part => part.slice(1));
  if (segments.length !== params.length || segments.some((name, index) => name !== params[index])) throw new TypeError('http.params_mismatch');
  if ((method === 'GET' || params.length > 0) && body === 'envelope') throw new TypeError('http.envelope_requires_literal_post');
  return { method, body, params };
}

export function defineHttpOperation(spec) {
  const identity = Object.freeze({ ...checkedIdentity(spec.identity) });
  if (!['query', 'command'].includes(spec.kind)) throw new TypeError('operation.invalid_kind');
  if (typeof spec.path !== 'string' || !/^\/[A-Za-z0-9/_.:-]*$/.test(spec.path) ||
      (spec.path !== '/' && spec.path.endsWith('/')) || spec.path.includes('//') ||
      spec.path.split('/').some(part => part === '.' || part === '..' || (part.includes(':') && !/^:[A-Za-z_][A-Za-z0-9_]*$/.test(part))))
    throw new TypeError('http.invalid_literal_path');
  const route = checkRoute(spec);
  if (route.method === 'GET' && spec.kind !== 'query') throw new TypeError('http.get_requires_query');
  for (const codec of ['encodeInput', 'decodeOutput']) {
    if (typeof spec[codec] !== 'function') throw new TypeError(`operation.missing_${codec}`);
  }
  if ((typeof spec.decodeError === 'function') !== (typeof spec.errorStatus === 'function'))
    throw new TypeError('operation.incomplete_error_policy');
  return Object.freeze({ ...spec, ...route, identity });
}

// Decision 5 framework codes, with the status a server sends them under.
const FRAMEWORK = Object.freeze({
  unauthorized: { status: 401, kind: 'unauthenticated', code: 'auth.required' },
  forbidden: { status: 403, kind: 'forbidden', code: 'auth.forbidden' },
  badRequest: { status: 400, kind: 'protocol', code: 'request.bad_request' },
  notFound: { status: 404, kind: 'protocol', code: 'operation.not_found' },
  conflict: { status: 409, kind: 'protocol', code: 'request.conflict' },
  tooManyRequests: { status: 429, kind: 'protocol', code: 'request.rate_limited' },
  unavailable: { status: 503, kind: 'transport', code: 'server.unavailable' },
  internal: { status: 500, kind: 'protocol', code: 'server.internal' },
});

// `{"error": "ctor"}` / `{"error": {"tag": ctor, …fields}}` back to the codec's tagged form.
function taggedError(payload) {
  if (typeof payload === 'string') return { tag: payload, value: null };
  if (payload && typeof payload === 'object' && !Array.isArray(payload) && typeof payload.tag === 'string') {
    const { tag, ...rest } = payload;
    const keys = Object.keys(rest);
    return keys.length === 1 && keys[0] === 'value' ? { tag, value: rest.value } : { tag, value: rest };
  }
  return null;
}

// Decision 5 envelope: `{"ok": v}` or `{"error": …}`, no operation metadata in the body.
function decodeEnvelope(operation, status, body) {
  const protocol = code => { throw new CallFailure('protocol', code, body); };
  if (Object.hasOwn(body, 'ok')) {
    wireObject(body, ['ok']);
    if (status < 200 || status > 299) protocol('response.status_mismatch');
    return { ok: true, value: operation.decodeOutput(body.ok) };
  }
  wireObject(body, ['error']);
  const tagged = taggedError(body.error);
  if (tagged === null) protocol('response.invalid_error');
  const framework = typeof body.error === 'string' && Object.hasOwn(FRAMEWORK, body.error) ? FRAMEWORK[body.error] : null;
  // A domain constructor may share a framework code's name; the status tells them apart.
  if (operation.decodeError && !(framework && framework.status === status)) {
    let error = null;
    try { error = operation.decodeError(tagged); } catch (cause) { if (!(cause instanceof CallFailure)) throw cause; }
    if (error !== null) {
      const expected = operation.errorStatus(error);
      if (!Number.isInteger(expected) || expected < 400 || expected > 599 || status !== expected)
        protocol('response.invalid_domain_error');
      return { ok: false, error };
    }
  }
  if (framework && framework.status === status) throw new CallFailure(framework.kind, framework.code, body);
  protocol('response.unknown_error');
}

// Integers stay exact: beyond 2^53 they are bigint in JavaScript and raw JSON text on the wire.
export function stringify(value) {
  return JSON.stringify(value, (_key, item) => {
    if (typeof item !== 'bigint') return item;
    if (typeof JSON.rawJSON !== 'function') throw new CallFailure('decode', 'json.unsafe_number', item.toString());
    return JSON.rawJSON(item.toString());
  });
}
export function parseJson(text) {
  return JSON.parse(text, (_key, value, context) => {
    if (typeof value === 'number' && !Number.isSafeInteger(value) && typeof context?.source === 'string' &&
        /^-?(0|[1-9][0-9]*)$/.test(context.source)) return BigInt(context.source);
    return value;
  });
}
const segment = value => {
  if (typeof value === 'string') return value;
  if (typeof value === 'number' && Number.isSafeInteger(value)) return String(value);
  if (typeof value === 'bigint') return value.toString();
  throw new CallFailure('decode', 'encode.path_segment', value);
};

// Domain results remain values. Transport/authority/protocol failures are CallFailure.
export function decodeHttpReply(operation, status, body) {
  const expected = operation.identity;
  const protocol = code => { throw new CallFailure('protocol', code, body); };
  // Both envelopes are decoded during the transition, so the server can switch on its own.
  if (body && typeof body === 'object' && !Array.isArray(body) && (Object.hasOwn(body, 'ok') || Object.hasOwn(body, 'error')))
    return decodeEnvelope(operation, status, body);
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
    const route = `${operation.method} ${operation.path}`;
    if (paths.has(route)) throw new TypeError('http.ambiguous_path');
    registry.set(key, operation); paths.add(route);
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
      const wire = operation.encodeInput(input);
      let url = `${baseURL}${operation.path}`, init;
      if (operation.body === 'envelope') {
        init = { method: 'POST', headers: { 'content-type': 'application/json' },
          body: stringify({ operation: operation.identity, kind: operation.kind, input: wire }) };
      } else {
        // Path parameters are input fields; the rest of the input record is the plain body.
        const fields = wire && typeof wire === 'object' && !Array.isArray(wire) ? { ...wire } : null;
        if (operation.params.length > 0 && fields === null) throw new CallFailure('decode', 'encode.path_fields', wire);
        url = `${baseURL}${operation.path.split('/').map(part => {
          if (!part.startsWith(':')) return part;
          const value = fields[part.slice(1)];
          delete fields[part.slice(1)];
          return encodeURIComponent(segment(value));
        }).join('/')}`;
        init = operation.method === 'GET' ? { method: 'GET' }
          : { method: 'POST', headers: { 'content-type': 'application/json' }, body: stringify(fields ?? wire) };
      }
      let response;
      try {
        response = await fetchImpl(url, { ...init, signal, credentials: 'same-origin', redirect: 'error' });
      } catch (cause) {
        throw new CallFailure(signal?.aborted ? 'cancelled' : 'transport',
          signal?.aborted ? 'request.cancelled' : 'request.failed', cause);
      }
      let body;
      try { body = typeof response.text === 'function' ? parseJson(await response.text()) : await response.json(); }
      catch (cause) {
        throw new CallFailure(signal?.aborted ? 'cancelled' : 'decode',
          signal?.aborted ? 'request.cancelled' : 'response.invalid_json', cause);
      }
      if (signal?.aborted) throw new CallFailure('cancelled', 'request.cancelled');
      return decodeHttpReply(operation, response.status, body);
    },
  });
}
