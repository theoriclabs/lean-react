// LeanJS ABI v0: exact numbers, immutable data and callable closures.
const $ctor = (tag, fields = []) => ({tag, fields});
const $bool = b => $ctor(b ? 'Bool.true' : 'Bool.false');
const $dec = b => $ctor(b ? 'Decidable.isTrue' : 'Decidable.isFalse', [null]);
const $fn = (arity, body, bound = []) => {
  const f = (...args) => {
    const all = bound.concat(args);
    if (all.length < arity) return $fn(arity, body, all);
    const value = body(...all.slice(0, arity));
    return all.length === arity ? value : $app(value, all.slice(arity));
  };
  Object.defineProperty(f, 'leanArity', {value: arity - bound.length});
  return f;
};
const $app = (f, args) => {
  if (!args.length) return f;
  if (typeof f !== 'function') throw new TypeError('LeanJS: application of a non-function');
  // Foreign callbacks use their declared JS parameter count as the Lean arity.
  return f.leanArity === undefined ? $fn(f.length, f)(...args) : f(...args);
};
const $lazy = body => {
  let state = 0, value;
  return () => {
    if (state === 2) return value;
    if (state === 1) throw new Error('LeanJS: cyclic constant initialization');
    state = 1;
    try { value = body(); state = 2; return value; }
    catch (e) { state = 0; throw e; }
  };
};
const $list = xs => {
  let out = $ctor('List.nil');
  for (let i = xs.length - 1; i >= 0; i--) out = $ctor('List.cons', [xs[i], out]);
  return out;
};
const $array = xs => {
  const out = [];
  while (xs.tag === 'List.cons') { out.push(xs.fields[0]); xs = xs.fields[1]; }
  if (xs.tag !== 'List.nil') throw new TypeError('LeanJS: malformed list');
  return out;
};
const $natSub = (a, b) => a > b ? a - b : 0n;
const $natDiv = (a, b) => b === 0n ? 0n : a / b;
const $natMod = (a, b) => b === 0n ? a : a % b;
const $ediv = (a, b) => {
  if (b === 0n) return 0n;
  const q = a / b, r = a % b;
  return r < 0n ? q + (b > 0n ? -1n : 1n) : q;
};
const $emod = (a, b) => b === 0n ? a : a - b * $ediv(a, b);
const $get = (xs, i) => {
  if (i < 0n || i >= BigInt(xs.length)) throw new RangeError('LeanJS: array index out of bounds');
  return xs[Number(i)];
};
const $set = (xs, i, x) => {
  if (i < 0n || i >= BigInt(xs.length)) throw new RangeError('LeanJS: array index out of bounds');
  const out = xs.slice(); out[Number(i)] = x; return out;
};
const $char = c => $ctor('Char.mk', [$ctor('UInt32.ofBitVec', [$ctor('Fin.mk', [BigInt(c.codePointAt(0)), null])]), null]);
const $codepoint = c => c.fields[0].fields[0].fields[0];
const $stringCompare = (a, b) => {
  const x = Array.from(a, c => c.codePointAt(0)), y = Array.from(b, c => c.codePointAt(0));
  for (let i = 0; i < Math.min(x.length, y.length); i++) if (x[i] !== y[i]) return x[i] < y[i];
  return x.length < y.length;
};

// Compare bigint bounds before converting: a huge start must not lose precision.
const $foldl = (f, initial, xs, start, stop) => {
  const end = stop < BigInt(xs.length) ? stop : BigInt(xs.length);
  let result = initial;
  for (let i = start; i < end; i++) result = $app(f, [result, xs[Number(i)]]);
  return result;
};
const $filter = (predicate, xs, start, stop) =>
  $foldl((out, x) => {
    const decision = $app(predicate, [x]);
    if (decision.tag === 'Bool.true') out.push(x);
    else if (decision.tag !== 'Bool.false') throw new TypeError('LeanJS: filter predicate must return an ABI Bool');
    return out;
  }, [], xs, start, stop);
