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

test('native Lean / generated Node parity across composed functions', () => {
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
