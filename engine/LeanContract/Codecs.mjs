// Schema-derived wire codecs used by generated clients (LeanContract.Generate). Every codec is a
// shape check mirroring Ontology.WireSchema; domain validation stays in compiled Lean on the server.
import { CallFailure } from './Fetch.mjs';

const fail = (code, value, path) => { throw new CallFailure('decode', code, { path, value }); };
const isObject = value => value !== null && typeof value === 'object' && !Array.isArray(value);
function exactKeys(value, keys, path) {
  if (!isObject(value)) fail('decode.expected_object', value, path);
  for (const key of Object.keys(value)) if (!keys.includes(key)) fail('decode.unknown_field', value, [...path, key]);
  for (const key of keys) if (!Object.hasOwn(value, key)) fail('decode.missing_field', value, [...path, key]);
  return value;
}
const scalar = (predicate, encodeCode, decodeCode) => Object.freeze({
  encode: (value, path = []) => predicate(value) ? value : fail(encodeCode, value, path),
  decode: (value, path = []) => predicate(value) ? value : fail(decodeCode, value, path),
});

export const unit = scalar(value => value === null, 'encode.unit', 'decode.expected_null');
export const bool = scalar(value => typeof value === 'boolean', 'encode.boolean', 'decode.expected_boolean');
// Lean strings hold Unicode scalar values only: a lone surrogate would come back as U+FFFD,
// so it is refused here instead of being silently rewritten by the server.
export const str = scalar(value => typeof value === 'string' && value.isWellFormed(), 'encode.string', 'decode.expected_string');

// Decision 15: wire integers are bare JSON numbers; JavaScript values are bigint, never Number.
// Beyond 2^53 a value stays a bigint, which the transport writes as exact JSON text (and the
// reader revives exactly). The milestone-1 tagged decimal form `{tag, value}` still decodes.
const integer = (tag, pattern, encodeCode, decodeCode, admits) => Object.freeze({
  encode(value, path = []) {
    if (typeof value !== 'bigint' || !admits(value)) fail(encodeCode, value, path);
    return value >= BigInt(Number.MIN_SAFE_INTEGER) && value <= BigInt(Number.MAX_SAFE_INTEGER) ? Number(value) : value;
  },
  decode(value, path = []) {
    let result;
    if (typeof value === 'number' && Number.isSafeInteger(value)) result = BigInt(value);
    else if (typeof value === 'bigint') result = value;
    else if (isObject(value)) {
      exactKeys(value, ['tag', 'value'], path);
      if (value.tag !== tag) fail('decode.unknown_tag', value, [...path, 'tag']);
      if (typeof value.value !== 'string' || !pattern.test(value.value)) fail(decodeCode, value, [...path, 'value']);
      result = BigInt(value.value);
    } else fail(decodeCode, value, path);
    if (!admits(result)) fail(decodeCode, value, path);
    return result;
  },
});
export const nat = integer('nat', /^(0|[1-9][0-9]*)$/, 'encode.nat', 'decode.invalid_natural', value => value >= 0n);
export const int = integer('int', /^(0|-?[1-9][0-9]*)$/, 'encode.int', 'decode.invalid_integer', () => true);

export const option = inner => Object.freeze({
  encode(value, path = []) {
    if (isObject(value) && value.tag === 'none') return { tag: 'none' };
    if (isObject(value) && value.tag === 'some') return { tag: 'some', value: inner.encode(value.value, [...path, 'value']) };
    return fail('encode.option', value, path);
  },
  decode(value, path = []) {
    if (!isObject(value) || typeof value.tag !== 'string') fail('decode.expected_object', value, path);
    if (value.tag === 'none') { exactKeys(value, ['tag'], path); return { tag: 'none' }; }
    if (value.tag === 'some') { exactKeys(value, ['tag', 'value'], path); return { tag: 'some', value: inner.decode(value.value, [...path, 'value']) }; }
    return fail('decode.unknown_tag', value, [...path, 'tag']);
  },
});

export const array = inner => Object.freeze({
  encode: (value, path = []) => Array.isArray(value) ? value.map((item, index) => inner.encode(item, [...path, index])) : fail('encode.array', value, path),
  decode: (value, path = []) => Array.isArray(value) ? value.map((item, index) => inner.decode(item, [...path, index])) : fail('decode.expected_array', value, path),
});

export const product = (left, right) => Object.freeze({
  encode: (value, path = []) => Array.isArray(value) && value.length === 2
    ? [left.encode(value[0], [...path, 0]), right.encode(value[1], [...path, 1])] : fail('encode.pair', value, path),
  decode: (value, path = []) => Array.isArray(value) && value.length === 2
    ? [left.decode(value[0], [...path, 0]), right.decode(value[1], [...path, 1])] : fail('decode.expected_pair', value, path),
});

// Maps are arrays of pairs; duplicate decoded keys are rejected like Codec.map.
export const entries = (key, value) => {
  const pairs = array(product(key, value));
  return Object.freeze({
    encode: pairs.encode,
    decode(wire, path = []) {
      const decoded = pairs.decode(wire, path), seen = new Set();
      decoded.forEach(([item], index) => {
        const identity = canonical(key.encode(item, []));
        if (seen.has(identity)) fail('decode.duplicate_key', wire, [...path, index, 0]);
        seen.add(identity);
      });
      return decoded;
    },
  });
};

export const record = fields => {
  const keys = fields.map(([key]) => key);
  const map = (method, value, path) => {
    exactKeys(value, keys, path);
    return Object.fromEntries(fields.map(([key, codec]) => [key, codec[method](value[key], [...path, key])]));
  };
  return Object.freeze({ encode: (value, path = []) => map('encode', value, path), decode: (value, path = []) => map('decode', value, path) });
};

// Decision 15: a payload-free case is the bare string "tag" on the wire; the value stays
// `{tag, value: null}` in JavaScript. The milestone-1 `{tag, value: null}` wire form still decodes.
export const variant = cases => {
  const table = new Map(cases);
  return Object.freeze({
    encode(value, path = []) {
      if (!isObject(value) || !table.has(value.tag)) fail('encode.variant', value, path);
      const payload = table.get(value.tag);
      if (payload === unit) { unit.encode(value.value, [...path, 'value']); return value.tag; }
      return { tag: value.tag, value: payload.encode(value.value, [...path, 'value']) };
    },
    decode(value, path = []) {
      if (typeof value === 'string') {
        if (table.get(value) !== unit) fail('decode.unknown_tag', value, path);
        return { tag: value, value: null };
      }
      exactKeys(value, ['tag', 'value'], path);
      if (typeof value.tag !== 'string' || !table.has(value.tag)) fail('decode.unknown_tag', value, [...path, 'tag']);
      return { tag: value.tag, value: table.get(value.tag).decode(value.value, [...path, 'value']) };
    },
  });
};

// Codec.entityId: the nominal type is checked, scope and key are nonempty.
export const entityId = (packageName, name) => {
  const shape = record([['type', record([['package', str], ['name', str]])], ['scope', str], ['key', str]]);
  const check = (value, path) => {
    if (value.type.package !== packageName || value.type.name !== name) fail('identity.type_mismatch', value, [...path, 'type']);
    if (value.scope === '') fail('identity.empty_scope', value, [...path, 'scope']);
    if (value.key === '') fail('identity.empty_key', value, [...path, 'key']);
    return value;
  };
  return Object.freeze({ encode: (value, path = []) => check(shape.encode(value, path), path), decode: (value, path = []) => check(shape.decode(value, path), path) });
};

// Decision 15: a reference is a bare JSON integer; the endpoint contract fixes its type.
// JavaScript values are bigint. The milestone-1 structured form is accepted on decode
// (default scope only) during the transition. A value beyond 2^53 is sent as a bigint, which
// the transport writes as exact JSON text.
const INT64_MAX = 9223372036854775807n;
export const refKey = (packageName, name) => {
  const legacy = entityId(packageName, name);
  return Object.freeze({
    encode(value, path = []) {
      if (typeof value !== 'bigint' || value <= 0n || value > INT64_MAX) fail('encode.ref', value, path);
      return value <= BigInt(Number.MAX_SAFE_INTEGER) ? Number(value) : value;
    },
    decode(value, path = []) {
      if (typeof value === 'number' && Number.isSafeInteger(value) && value > 0) return BigInt(value);
      if (typeof value === 'bigint' && value > 0n && value <= INT64_MAX) return value;
      if (isObject(value)) {
        const old = legacy.decode(value, path);
        if (old.scope !== 'default') fail('identity.non_default_scope', value, [...path, 'scope']);
        if (!/^[1-9][0-9]*$/.test(old.key) || BigInt(old.key) > INT64_MAX) fail('identity.invalid_key', value, [...path, 'key']);
        return BigInt(old.key);
      }
      return fail('decode.expected_integer', value, path);
    },
  });
};

// Proleptic Gregorian UTC, exact over the signed-64-bit second range (bigint arithmetic).
const fdiv = (a, b) => (a >= 0n ? a / b : -((-a + b - 1n) / b));
const pad = (value, width) => value.toString().padStart(width, '0');
export function formatRfc3339(seconds) {
  const days = fdiv(seconds, 86400n), second = seconds - days * 86400n;
  const z = days + 719468n, era = fdiv(z, 146097n), doe = z - era * 146097n;
  const yoe = (doe - doe / 1460n + doe / 36524n - doe / 146096n) / 365n;
  const doy = doe - (365n * yoe + yoe / 4n - yoe / 100n), mp = (5n * doy + 2n) / 153n;
  const day = doy - (153n * mp + 2n) / 5n + 1n, month = mp < 10n ? mp + 3n : mp - 9n;
  const year = yoe + era * 400n + (month <= 2n ? 1n : 0n);
  const yearText = year >= 0n && year <= 9999n ? pad(year, 4) : (year < 0n ? '-' : '+') + pad(year < 0n ? -year : year, 6);
  return `${yearText}-${pad(month, 2)}-${pad(day, 2)}T${pad(second / 3600n, 2)}:${pad(second % 3600n / 60n, 2)}:${pad(second % 60n, 2)}Z`;
}
const RFC3339 = /^([+-][0-9]{6,}|[0-9]{4})-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$/;

// Decision 15: Time is an RFC 3339 UTC string at second precision (the server checks the
// calendar); the milestone-1 `{tag:"int"}` epoch form is accepted on decode and normalized.
export const time = Object.freeze({
  encode: (value, path = []) => typeof value === 'string' && RFC3339.test(value) ? value : fail('encode.time', value, path),
  decode(value, path = []) {
    if (typeof value === 'string' && RFC3339.test(value)) return value;
    if (isObject(value)) return formatRfc3339(int.decode(value, path));
    return fail('decode.expected_time', value, path);
  },
});

// Named schemas carry no validation descriptors yet; the name is kept for diagnostics only.
export const named = (_name, inner) => inner;

// References resolve lazily through the module's table, so recursive schemas terminate.
export const ref = (table, key) => Object.freeze({
  encode: (value, path = []) => table[key].encode(value, path),
  decode: (value, path = []) => table[key].decode(value, path),
});

export const statusByTag = table => error => table[error?.tag];

// JSON text with recursively sorted object keys, for byte comparisons of wire values.
export function canonical(value) {
  if (Array.isArray(value)) return `[${value.map(canonical).join(',')}]`;
  if (isObject(value)) return `{${Object.keys(value).sort().map(key => `${JSON.stringify(key)}:${canonical(value[key])}`).join(',')}}`;
  // An exact integer beyond 2^53 is a bigint; it prints as the same JSON number text.
  return typeof value === 'bigint' ? value.toString() : JSON.stringify(value);
}
