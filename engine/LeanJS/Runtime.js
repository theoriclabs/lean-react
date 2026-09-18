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
// A self tail call made inside a join point or match alternative returns this
// request; the enclosing `while (true)` loop rebinds its parameters from `args`.
class $Tail { constructor(args) { this.args = args; } }
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
const $checkLibrary = (manifest, expected) => {
  if (manifest?.abi !== expected.abi || manifest?.lean !== expected.lean ||
      JSON.stringify(manifest.library) !== JSON.stringify(expected)) {
    throw new Error(`LeanJS: library interface mismatch for ${expected.id.packageName}/${expected.id.moduleName}@${expected.id.version}`);
  }
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
const $charOf = n => $ctor('Char.mk', [$ctor('UInt32.ofBitVec', [$ctor('Fin.mk', [n, null])]), null]);
const $char = c => $charOf(BigInt(c.codePointAt(0)));
const $codepoint = c => c.fields[0].fields[0].fields[0];
// `Char.ofNat` maps values outside the scalar range to the null character.
const $charOfNat = n => $charOf(n < 0xD800n || (n > 0xDFFFn && n < 0x110000n) ? n : 0n);
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
const $listLength = xs => BigInt($array(xs).length);
const $listFoldl = (f, init, xs) => {
  let result = init;
  for (const x of $array(xs)) result = $app(f, [result, x]);
  return result;
};
const $listMap = (f, xs) => $list($array(xs).map(x => $app(f, [x])));
const $listFlatMap = (f, xs) => {
  const out = [];
  for (const x of $array(xs)) {
    const inner = $array($app(f, [x]));
    for (let i = 0; i < inner.length; i++) out.push(inner[i]);
  }
  return $list(out);
};
const $listAppend = (xs, ys) => {
  const acc = $array(xs);
  let out = ys;
  for (let i = acc.length - 1; i >= 0; i--) out = $ctor('List.cons', [acc[i], out]);
  return out;
};
const $listFilter = (p, xs) => {
  const out = [];
  for (const x of $array(xs)) {
    const decision = $app(p, [x]);
    if (decision.tag === 'Bool.true') out.push(x);
    else if (decision.tag !== 'Bool.false') throw new TypeError('LeanJS: filter predicate must return an ABI Bool');
  }
  return $list(out);
};
const $listReverse = xs => {
  const acc = $array(xs);
  let out = $ctor('List.nil');
  for (let i = 0; i < acc.length; i++) out = $ctor('List.cons', [acc[i], out]);
  return out;
};
const $listReverseAux = (xs, acc) => {
  const items = $array(xs);
  let out = acc;
  for (let i = 0; i < items.length; i++) out = $ctor('List.cons', [items[i], out]);
  return out;
};
const $listCheck = xs => {
  if (xs.tag !== 'List.nil') throw new TypeError('LeanJS: malformed list');
};
// Scalar-indexed strings: iterate code points, never UTF-16 units. A lone
// surrogate is not a Unicode scalar and violates the string ABI.
const $scalar = ch => {
  const c = ch.codePointAt(0);
  if (c >= 0xD800 && c <= 0xDFFF) throw new TypeError('LeanJS: lone surrogate is not a Unicode scalar');
  return c;
};
// UTF-16 offset of scalar index `n`, clamped to the end of `s`.
const $scalarOffset = (s, n) => {
  let offset = 0, count = 0n;
  for (const ch of s) {
    if (count >= n) break;
    $scalar(ch); offset += ch.length; count++;
  }
  return offset;
};
const $takeScalars = (s, n) => s.slice(0, $scalarOffset(s, n));
const $dropScalars = (s, n) => s.slice($scalarOffset(s, n));
const $extractScalars = (s, start, len) => $takeScalars($dropScalars(s, start), len);
const $scalarLength = s => {
  let count = 0n;
  for (const ch of s) { $scalar(ch); count++; }
  return count;
};
const $foldlScalars = (f, initial, s) => {
  let result = initial;
  for (const ch of s) { $scalar(ch); result = $app(f, [result, $char(ch)]); }
  return result;
};
const $ofScalars = cs => cs.map(c => String.fromCodePoint(Number($codepoint(c)))).join('');
const $prod = (a, b) => $ctor('Prod.mk', [a, b]);
const $listTake = (n, xs) => {
  const out = [];
  while (n > 0n && xs.tag === 'List.cons') { out.push(xs.fields[0]); xs = xs.fields[1]; n--; }
  if (n > 0n) $listCheck(xs);
  return $list(out);
};
// `List.takeTR.go l xs n acc` returns `l` itself once `xs` is exhausted.
const $listTakeGo = (l, xs, n, acc) => {
  const out = acc.slice();
  while (true) {
    if (xs.tag !== 'List.cons') { $listCheck(xs); return l; }
    if (n === 0n) return $list(out);
    out.push(xs.fields[0]); xs = xs.fields[1]; n--;
  }
};
const $listDrop = (n, xs) => {
  while (n > 0n && xs.tag === 'List.cons') { xs = xs.fields[1]; n--; }
  if (n > 0n) $listCheck(xs);
  return xs;
};
const $listSplitAt = (n, xs) => {
  const out = [];
  let rest = xs;
  while (n > 0n && rest.tag === 'List.cons') { out.push(rest.fields[0]); rest = rest.fields[1]; n--; }
  if (rest.tag !== 'List.cons') { $listCheck(rest); return $prod(xs, rest); }
  return $prod($list(out), rest);
};
// `List.splitAt.go l xs n acc`: `(l, [])` once `xs` is exhausted, else `(acc.reverse ++ taken, rest)`.
const $listSplitAtGo = (l, xs, n, acc) => {
  const out = $array(acc).reverse();
  while (true) {
    if (xs.tag !== 'List.cons') { $listCheck(xs); return $prod(l, $ctor('List.nil')); }
    if (n === 0n) return $prod($list(out), xs);
    out.push(xs.fields[0]); xs = xs.fields[1]; n--;
  }
};
const $listZipWith = (f, xs, ys) => {
  const out = [];
  while (xs.tag === 'List.cons' && ys.tag === 'List.cons') {
    out.push($app(f, [xs.fields[0], ys.fields[0]]));
    xs = xs.fields[1]; ys = ys.fields[1];
  }
  if (xs.tag !== 'List.cons') $listCheck(xs); else $listCheck(ys);
  return $list(out);
};
const $listZipIdx = (xs, n) => $list($array(xs).map((x, i) => $prod(x, n + BigInt(i))));
const $listReplicate = (n, x, acc = $ctor('List.nil')) => {
  let out = acc;
  for (; n > 0n; n--) out = $ctor('List.cons', [x, out]);
  return out;
};
const $listRange = (n, acc = $ctor('List.nil')) => {
  let out = acc;
  for (let i = n; i > 0n; i--) out = $ctor('List.cons', [i - 1n, out]);
  return out;
};
// `List.range'TR.go step n e acc = [e - n*step, ..., e - step] ++ acc`.
const $listRangeGo = (step, n, e, acc) => {
  let out = acc;
  for (; n > 0n; n--) { e = $natSub(e, step); out = $ctor('List.cons', [e, out]); }
  return out;
};
const $listRangeFrom = (start, len, step) => $listRangeGo(step, len, start + step * len, $ctor('List.nil'));
const $listFoldr = (f, initial, xs) => {
  const items = $array(xs);
  let result = initial;
  for (let i = items.length - 1; i >= 0; i--) result = $app(f, [items[i], result]);
  return result;
};
const $listLast = xs => {
  const items = $array(xs);
  if (!items.length) throw new RangeError('LeanJS: List.getLast of an empty list');
  return items[items.length - 1];
};
const $listLastOpt = xs => {
  const items = $array(xs);
  return items.length ? $ctor('Option.some', [items[items.length - 1]]) : $ctor('Option.none');
};
const $decision = (value, name) => {
  if (value.tag === 'Bool.true') return true;
  if (value.tag === 'Bool.false') return false;
  throw new TypeError(`LeanJS: ${name} predicate must return an ABI Bool`);
};
const $listAll = (xs, p) => {
  for (const x of $array(xs)) if (!$decision($app(p, [x]), 'all')) return $bool(false);
  return $bool(true);
};
const $listAny = (xs, p) => {
  for (const x of $array(xs)) if ($decision($app(p, [x]), 'any')) return $bool(true);
  return $bool(false);
};
// Array ranges stay bigint until an in-range index is selected, as in $foldl.
const $extract = (xs, start, stop) => {
  const size = BigInt(xs.length);
  const end = stop < size ? stop : size;
  return start < end ? xs.slice(Number(start), Number(end)) : [];
};
const $zipWith = (f, xs, ys) => {
  const out = [];
  for (let i = 0; i < Math.min(xs.length, ys.length); i++) out.push($app(f, [xs[i], ys[i]]));
  return out;
};
// `Array.foldr f init as start stop` visits `min(start, size) - 1` down to `stop`.
const $foldr = (f, initial, xs, start, stop) => {
  const size = BigInt(xs.length);
  let i = start < size ? start : size;
  let result = initial;
  while (i > stop) { i--; result = $app(f, [xs[Number(i)], result]); }
  return result;
};
const $findIdx = (p, xs) => {
  for (let i = 0; i < xs.length; i++) if ($decision($app(p, [xs[i]]), 'findIdx?')) return $ctor('Option.some', [BigInt(i)]);
  return $ctor('Option.none');
};
const $insertIdx = (xs, i, x) => {
  if (i < 0n || i > BigInt(xs.length)) throw new RangeError('LeanJS: array index out of bounds');
  const out = xs.slice(); out.splice(Number(i), 0, x); return out;
};
const $eraseIdx = (xs, i) => {
  if (i < 0n || i >= BigInt(xs.length)) throw new RangeError('LeanJS: array index out of bounds');
  const out = xs.slice(); out.splice(Number(i), 1); return out;
};
