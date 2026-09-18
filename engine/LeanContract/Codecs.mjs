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
export const str = scalar(value => typeof value === 'string', 'encode.string', 'decode.expected_string');

// Wire integers are canonical decimal strings; JavaScript values are bigint, never Number.
const integer = (tag, pattern, encodeCode, decodeCode, admits) => Object.freeze({
  encode(value, path = []) {
    if (typeof value !== 'bigint' || !admits(value)) fail(encodeCode, value, path);
    return { tag, value: value.toString() };
  },
  decode(value, path = []) {
    exactKeys(value, ['tag', 'value'], path);
    if (value.tag !== tag) fail('decode.unknown_tag', value, [...path, 'tag']);
    if (typeof value.value !== 'string' || !pattern.test(value.value)) fail(decodeCode, value, [...path, 'value']);
    return BigInt(value.value);
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

export const variant = cases => {
  const table = new Map(cases);
  return Object.freeze({
    encode(value, path = []) {
      if (!isObject(value) || !table.has(value.tag)) fail('encode.variant', value, path);
      return { tag: value.tag, value: table.get(value.tag).encode(value.value, [...path, 'value']) };
    },
    decode(value, path = []) {
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
  return JSON.stringify(value);
}
