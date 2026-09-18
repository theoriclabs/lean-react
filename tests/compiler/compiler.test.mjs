import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import * as p from './generated.mjs';
import * as intrinsic from './intrinsic-generated.mjs';
import * as iteration from './iteration.mjs';
const iter = name => iteration[`Corpus.${name}`];
const f = name => p[`Corpus.${name}`];
const ctor = (tag, fields = []) => ({tag, fields});
const list = xs => xs.reduceRight((tail, x) => ctor('List.cons', [x, tail]), ctor('List.nil'));
const array = xs => { const out = []; while (xs.tag === 'List.cons') { out.push(xs.fields[0]); xs = xs.fields[1]; } return out; };
const ticket = title => ctor('Corpus.Ticket.mk', [title, 9007199254740993n, null]);
const ns = [0n, 1n, 2n, 17n, 9007199254740993n, 123456789012345678901234567890n];
const zs = [-123456789012345678901234567890n, -17n, -1n, 0n, 1n, 17n, 123456789012345678901234567890n];
const strings = ['', 'ASCII', 'A😀é中', 'é', '𐀀\uE000', 'quote"slash\\\nline', 'x\0y'];
const arrays = [[], [1n,2n,3n], [9007199254740993n,5n]];
const str = x => String(x);
const natArray = xs => xs.map(str);

// The generator, palette and digests mirror tests/compiler/Native.lean exactly.
const next = (seed, bound) => {
  seed = (seed * 1103515245n + 12345n) % 2147483648n;
  return [seed / 65536n % bound, seed];
};
const palette = [0x41, 0x62, 0x7A, 0x20, 0xE9, 0x4E2D, 0x1F600, 0x200D, 0x1F468,
  0x1F469, 0x1F467, 0xFE0F, 0x1F3FD, 0x10000, 0x10FFFF, 0xE000, 0xD7FF, 0x0];
const digestNat = (h, x) => (h * 1000003n + x + 1n) % 1000000007n;
const digestNats = (h, xs) => xs.reduce(digestNat, h);
const digestString = (h, s) => digestNats(h, Array.from(s, c => BigInt(c.codePointAt(0))));
const random = () => {
  let seed = 20250918n;
  const out = {strings: 7n, lists: 7n, arrays: 7n, loops: 7n, stringSamples: [], listSamples: [], arraySamples: []};
  for (let round = 0; round < 10000; round++) {
    let len; [len, seed] = next(seed, 25n);
    let scalars = '';
    for (let j = 0n; j < len; j++) { let i; [i, seed] = next(seed, BigInt(palette.length)); scalars += String.fromCodePoint(palette[i]); }
    let n, k; [n, seed] = next(seed, len + 3n); [k, seed] = next(seed, len + 3n);
    const text = f('scalarOps')(scalars, n, k);
    out.strings = digestString(out.strings, text);
    if (out.stringSamples.length < 64) out.stringSamples.push(text);
    let count; [count, seed] = next(seed, 13n);
    const xs = [];
    for (let j = 0n; j < count; j++) { let x; [x, seed] = next(seed, 100n); xs.push(x); }
    let i, m; [i, seed] = next(seed, count + 2n); [m, seed] = next(seed, count + 3n);
    const listed = array(f('listOps')(list(xs), m)), arrayed = f('arrayOps')(xs, i, n);
    out.lists = digestNats(out.lists, listed); out.arrays = digestNats(out.arrays, arrayed);
    out.loops = digestNats(out.loops, [f('sumAcc')(list(xs), n), f('countLoop')(n, m), f('sumEven')(list(xs), m), f('sumWhere')(list(xs))]);
    if (out.listSamples.length < 32) out.listSamples.push(natArray(listed));
    if (out.arraySamples.length < 32) out.arraySamples.push(natArray(arrayed));
  }
  return out;
};

test('native Lean / generated Node parity across composed functions', () => {
  const sampled = random();
  const actual = {
    iteration: [[], [1n], [2n,3n,0n,9n], [9n,0n], [1n,2n,3n]].map(xs => {
      const result = iter('scanExcept')(xs);
      return result.tag === 'Except.ok' ? {value: str(result.fields[0])} : {error: result.fields[0]};
    }),
    monadicRanges: [[], [1n,0n,3n], [2n,3n,4n]].flatMap(xs =>
      [0n,1n,3n,5n,9007199254740993n].flatMap(start =>
        [0n,1n,3n,5n,9007199254740993n].map(stop => {
          const result = iter('arrayFoldM')(xs,start,stop);
          return result.tag === 'Option.none' ? null : str(result.fields[0]);
        }))),
    arrayRanges: arrays.flatMap(xs => [0n,1n,3n,5n,9007199254740993n].flatMap(start =>
      [0n,1n,3n,5n,9007199254740993n].map(stop => ({
        fold:str(f('arrayFold')(xs,start,stop)), filter:natArray(f('arrayFilter')(xs,2n,start,stop))
      })))),
    observation: f('observation'),
    monadId: ns.map(n => str(f('programId')(n))),
    monadOption: ns.map(n => { const x = f('programOption')(n); return x.tag === 'Option.none' ? null : str(x.fields[0]); }),
    textOrder: strings.flatMap(a => strings.map(b => str(f('classifyText')(a,b)))),
    integerParts: zs.map(n => str(f('integerParts')(n))),
    nestedOption: [ctor('Option.none'),ctor('Option.some',[ctor('Option.none')]),ctor('Option.some',[ctor('Option.some',[5n])])].map(x => str(f('nestedOption')(x))),
    arithmetic: ns.flatMap(a => ns.map(b => str(f('natural')(a,b)))),
    integers: zs.flatMap(a => zs.map(b => str(f('signed')(a,b)))),
    texts: strings.map(x => f('text')(x)), chars: strings.map(x => f('chars')(x)),
    records: strings.map(s => {
      const t = ticket(s), u = f('updateTicket')(t,9n), c = f('titleCheck')(t);
      return {updated: {title:u.fields[0], priority:str(u.fields[1])}, check:c.tag === 'Option.none' ? null : c.fields[0]};
    }),
    statuses: [ctor('Corpus.Status.waiting'), ctor('Corpus.Status.active', ['😀a',8n]), ctor('Corpus.Status.done',[9007199254740993n])].map(x => str(f('statusScore')(x))),
    closures: ns.map(n => str(f('useCapture')(n,7n))),
    services: ns.map(n => str(f('services')(n))),
    typeclass: ns.map(n => str(f('ticketScore')(n))),
    recursive: Array.from({length:16}, (_,n) => str(f('fibonacci')(BigInt(n)))),
    wellFounded: str(f('countdown')(150n)),
    mappedList: natArray(array(f('mapCaptured')(9n,list(ns)))),
    listSmall: str(f('listLarge')([1n,2n,3n])),
    listLarge: str(f('listLarge')(Array.from({length:12000}, (_,i) => BigInt(i)))),
    listSlices: [[], [1n,2n,3n], Array.from({length:12000}, (_,i) => BigInt(i))].flatMap(xs =>
      [0n, 1n, 6000n, 12000n, 9007199254740993n].map(n => str(f('listSlices')(xs, n)))),
    randomStrings: str(sampled.strings), randomStringSamples: sampled.stringSamples,
    randomLists: str(sampled.lists), randomListSamples: sampled.listSamples,
    randomArrays: str(sampled.arrays), randomArraySamples: sampled.arraySamples,
    randomLoops: str(sampled.loops),
    loops: (xs => natArray([f('sumAcc')(xs, 5n), f('countLoop')(12000n, 0n), f('sumEven')(xs, 0n), f('sumWhere')(xs)]))
      (list(Array.from({length: 12000}, (_, i) => BigInt(i)))),
    arrayWork: arrays.map(xs => natArray(f('arrayWork')(xs,4n))),
    arrayRead: arrays.map(xs => [0n,1n,50n].map(i => str(f('arrayRead')(xs,i)))),
    arraySet: natArray(f('arraySet')([1n,2n,3n],1n,99n))
  };
  assert.deepEqual(actual, JSON.parse(readFileSync(new URL('./native.json', import.meta.url), 'utf8')));
});

test('generic closures accept live JS functions, partial and over-application', () => {
  assert.equal(f('bindFirst')((x,y) => x * 2n + y, 10n)(3n),23n);
  assert.equal(f('twice')(null, x => x + 3n, 5n), 11n);
  assert.equal(f('useCapture')(7n)(4n), 37n);
  assert.equal(f('capture')(7n,4n), 15n);
  assert.equal(f('capture')(7n)(4n), 15n);
  const service = ctor('Corpus.Service.mk', [key => key + 5n, x => x * 3n, x => x - 1n]);
  assert.equal(f('runService')(null, service, 10n), 44n);
});

test('records and arrays preserve prior snapshots and proof slots', () => {
  const t = ticket('immutable'), before = structuredClone(t);
  const u = f('updateTicket')(t,10n);
  assert.deepEqual(t,before); assert.notStrictEqual(u,t); assert.equal(u.fields[2],null);
  const xs = Object.freeze([1n,2n,3n]);
  assert.deepEqual(f('arraySet')(xs,1n,9n),[1n,9n,3n]);
  assert.deepEqual(f('arrayWork')(xs,2n),[3n,4n,5n,2n]);
  assert.deepEqual(xs,[1n,2n,3n]);
  assert.throws(() => f('arraySet')(xs,100n,9n), RangeError);
});

test('named intrinsic overrides its native reference and retains closure capture', () => {
  assert.equal(intrinsic['Corpus.viaIntrinsic'](9n,5n),1019n);
});

test('export and constructor metadata describe the adapter boundary', () => {
  assert.equal(p.__leanjs.abi,'leanjs-v0');
  assert.equal(p.__leanjs.declarations.find(d => d.name === 'Corpus.twice').arity,3);
  const ticket = p.__leanjs.constructors.find(d => d.name === 'Corpus.Ticket.mk');
  assert.equal(ticket.fields,3);
  assert.deepEqual(ticket.fieldInfo.map(f => f.name), ['title','priority','approved']);
  assert.equal(ticket.fieldInfo[2].erased,true);
  assert.equal(p.__leanjs.constructors.find(d => d.name === 'Corpus.Status.active').fields,2);
});

test('iterative List builtins do not overflow the JS stack at 12k elements', () => {
  const xs = Array.from({length: 12000}, (_, i) => BigInt(i));
  assert.equal(f('listLarge')(xs), 144066000n);
  // take/drop/splitAt/zip/zipIdx/foldr/getLast?/all over the same 12,000 elements.
  assert.equal(f('listSlices')(xs, 12000n), 12000n + 12000n * 3n + 12000n + 71994000n + 11999n + 1n);
});

test('scalar string and List builtins iterate at 100k elements without stack growth', () => {
  const text = '😀'.repeat(50000) + 'a'.repeat(50000);
  const dropped = f('scalarDrop')(text, 50000n);
  assert.equal(dropped, 'a'.repeat(50000));
  assert.equal(f('scalarDrop')(text, 99999n), 'a');
  assert.equal(f('scalarDrop')(text, 100000n), '');
  assert.equal(f('scalarDrop')(text, 9007199254740993n), '');
  const xs = Array.from({length: 100000}, (_, i) => BigInt(i));
  assert.doesNotThrow(() => f('listSlices')(xs, 50000n));
  assert.equal(array(f('listOps')(list(xs.slice(0, 20)), 3n)).length, 20 + 2 + 19 + 20 + 20 + 3 + 3 + 0 + 4);
});

test('self tail calls compile to loops that run on one million elements', () => {
  const million = Array.from({length: 1000000}, (_, i) => BigInt(i));
  const xs = list(million);
  assert.equal(f('sumAcc')(xs, 0n), 499999500000n);
  assert.equal(f('countLoop')(1000000n, 0n), 499999500000n);
  assert.equal(f('sumEven')(xs, 0n), 249999500000n);
  assert.equal(f('sumWhere')(xs), 499999500000n);
  // The non-tail original still uses the JavaScript stack, as its compile-time note says.
  assert.throws(() => f('sum')(xs), RangeError);
  const source = readFileSync(new URL('./generated.mjs', import.meta.url), 'utf8');
  assert.match(source, /class \$Tail/);
});

test('scalar string builtins index code points and reject lone surrogates', () => {
  const family = '👨\u200D👩\u200D👧';
  assert.equal(f('scalarOps')(family, 1n, 2n), '👨|\u200D👩\u200D👧|\u200D👩|5|400722|' + family);
  assert.equal(f('scalarOps')('𐀀\uE000', 1n, 5n), '𐀀|\uE000|\uE000|2|122880|𐀀\uE000');
  assert.equal(f('scalarOps')('A😀é中', 2n, 1n), 'A😀|é中|é|4|148823|A😀é中');
  assert.equal(f('scalarOps')('', 3n, 3n), '|||0|0|');
  assert.throws(() => f('scalarDrop')('a\uD800b', 2n), TypeError);
  assert.throws(() => f('scalarOps')('\uDC00', 0n, 0n), TypeError);
});

test('array contracts preserve range, callback order, and immutable inputs', () => {
  const xs = Object.freeze([1n,2n,3n]);
  assert.equal(f('arrayFold')(xs,1n,999999999999999999999999n),723n);
  assert.equal(f('arrayFold')(xs,999999999999999999999999n,1000000000000000000000000n),7n);
  assert.deepEqual(f('arrayFilter')(xs,0n,1n,2n),[2n]);
  assert.deepEqual(xs,[1n,2n,3n]);
});

test('generic array iteration preserves break, continue, and first-match evaluation', () => {
  const visited = [];
  const xs = Object.freeze([1n,2n,3n,0n,99n]);
  assert.equal(iter('scanId')(x => { visited.push(x); return x * 10n; }, xs), 50n);
  assert.deepEqual(visited, [2n,3n]);
  visited.length = 0;
  const found = iter('arrayFind')(x => {
    visited.push(x); return ctor(x === 3n ? 'Bool.true' : 'Bool.false');
  }, xs);
  assert.deepEqual(found, ctor('Option.some', [3n]));
  assert.deepEqual(visited, [1n,2n,3n]);
});

test('LR-10 proof fields, subtypes, Fin, and identity casts', async () => {
  const pf = await import('./proof-fields.mjs');
  const score = pf['ProofFields.score'];
  const identityCast = pf['ProofFields.identityCast'];
  const countMake = pf['ProofFields.Count.make'];
  const textMake = pf['ProofFields.Text.make'];
  const indent = pf['ProofFields.Indent.ofNat?'];
  const ofOps = pf['ProofFields.Delta.ofOps'];
  const normalize = pf['ProofFields.Delta.normalize'];
  const check = pf['ProofFields.Normal.check'];
  const chainMake = pf['ProofFields.Chain.make'];
  assert.equal(score('hi', 'ab', 3n), 13n);
  assert.equal(score('', 'x', 0n), 4n);
  assert.equal(score('hi', '', 3n), 0n);
  assert.equal(identityCast(7n), 7n);
  assert.equal(countMake(0n).tag, 'Option.none');
  assert.equal(countMake(2n).tag, 'Option.some');
  assert.equal(textMake('').tag, 'Option.none');
  assert.equal(indent(9n).tag, 'Option.none');
  const delta = pf.__leanjs.constructors.find(d => d.name === 'ProofFields.Delta.mk');
  assert.equal(delta.fieldInfo.find(f => f.name === 'normal').erased, true);
  const text = pf.__leanjs.constructors.find(d => d.name === 'ProofFields.Text.mk');
  assert.equal(text.fieldInfo.find(f => f.name === 'nonempty').erased, true);
  assert.equal(text.fieldInfo.find(f => f.name === 'noBreak').erased, true);
  const range = pf.__leanjs.constructors.find(d => d.name === 'ProofFields.Range.mk');
  assert.equal(range.fieldInfo.find(f => f.name === 'inBounds').erased, true);
  const chain = pf.__leanjs.constructors.find(d => d.name === 'ProofFields.Chain.mk');
  assert.deepEqual(chain.fieldInfo.filter(f => f.erased).map(f => f.name), ['dense', 'first', 'linked']);
  const doc = pf.__leanjs.constructors.find(d => d.name === 'ProofFields.Doc.mk');
  assert.equal(doc.fieldInfo[0].name, 'paragraphs');
  const t = textMake('ab').fields[0];
  const c = countMake(2n).fields[0];
  const insert = { tag: 'ProofFields.Op.insert', fields: [t] };
  const retain = { tag: 'ProofFields.Op.retain', fields: [c] };
  const del = { tag: 'ProofFields.Op.delete', fields: [c] };
  assert.equal(ofOps([]).tag, 'Option.some');
  assert.equal(ofOps([insert]).tag, 'Option.none');
  const ok = ofOps([insert, retain]);
  assert.equal(ok.tag, 'Option.some');
  assert.equal(ok.fields[0].fields[1], null);
  const swapped = ofOps([insert, del, retain]);
  assert.equal(swapped.tag, 'Option.some');
  assert.equal(swapped.fields[0].fields[0][0].tag, 'ProofFields.Op.delete');
  assert.equal(chainMake([0n, 1n, 2n]).tag, 'Option.some');
  assert.deepEqual(chainMake([0n, 1n, 2n]).fields[0].fields.slice(1), [null, null, null]);
  assert.equal(chainMake([1n, 2n]).tag, 'Option.none');
  const next = (seed, bound) => {
    seed = (seed * 1103515245n + 12345n) % 2147483648n;
    return [seed / 65536n % bound, seed];
  };
  let seed = 20260918n;
  for (let round = 0; round < 10000; round++) {
    let n; [n, seed] = next(seed, 8n);
    const ops = [];
    for (let j = 0n; j < n; j++) {
      let kind, mag; [kind, seed] = next(seed, 3n); [mag, seed] = next(seed, 4n);
      const count = countMake(mag + 1n).fields[0];
      const letter = String.fromCharCode(97 + Number(j % 26n));
      ops.push(kind === 0n ? { tag: 'ProofFields.Op.insert', fields: [textMake(letter).fields[0]] }
        : kind === 1n ? { tag: 'ProofFields.Op.retain', fields: [count] }
        : { tag: 'ProofFields.Op.delete', fields: [count] });
    }
    const normalized = normalize(ops);
    const got = ofOps(ops);
    const expectSome = check(normalized).tag === 'Bool.true';
    if (expectSome) {
      assert.equal(got.tag, 'Option.some');
      assert.deepEqual(got.fields[0].fields[0], normalized);
      assert.equal(got.fields[0].fields[1], null);
    } else {
      assert.equal(got.tag, 'Option.none');
    }
  }
  const big = [];
  const one = countMake(1n).fields[0];
  const ix = textMake('x').fields[0];
  for (let i = 0; i < 100000; i++) {
    big.push(i % 2 === 0
      ? { tag: 'ProofFields.Op.insert', fields: [ix] }
      : { tag: 'ProofFields.Op.retain', fields: [one] });
  }
  assert.doesNotThrow(() => check(big));
  assert.equal(check(big).tag, 'Bool.true');
  assert.doesNotThrow(() => ofOps(big));
});

test('generated TypeScript declarations parse and expose retained ABI slots', async () => {
  const { transform } = await import('esbuild');
  const declarations = readFileSync(new URL('./generated.d.ts', import.meta.url),'utf8');
  await transform(declarations,{loader:'ts',format:'esm'});
  assert.equal(declarations,readFileSync(new URL('./generated.d.mts', import.meta.url),'utf8'));
  assert.match(declarations,/LeanFunction<\[null, \(a0: unknown\) => unknown, unknown\], unknown>/);
  assert.match(declarations,/LeanCtor<"Corpus.Ticket.mk", readonly \[string, bigint, null\]>/);
  assert.match(declarations,/as "Corpus.twice"/);
  const manifest = JSON.parse(readFileSync(new URL('./generated.manifest.json', import.meta.url),'utf8'));
  assert.deepEqual(manifest,p.__leanjs);
});
