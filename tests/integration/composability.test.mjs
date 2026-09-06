import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { JSDOM } from 'jsdom';

const { window } = new JSDOM('<!doctype html><html><body></body></html>');
Object.assign(globalThis, { window, document: window.document, HTMLElement: window.HTMLElement,
  IS_REACT_ACT_ENVIRONMENT: true });
const React = await import('react');
const { createRoot } = await import('react-dom/client');
const { renderToString } = await import('react-dom/server');
const { mountElement, ctor, provide } = await import('../../engine/adapters/leanjs-react.mjs');
const shared = await import('../../examples/generated/shared.mjs');
const provider = await import('../../examples/generated/provider.mjs');
const consumer = await import('../../examples/generated/consumer.mjs');
const automatic = await import('../../examples/generated/automatic-context.mjs');
const collection = await import('../../examples/generated/collections.mjs');
const name = short => `Examples.Libraries.${short}`;

async function mounted(body) {
  const container = document.createElement('div');
  document.body.append(container);
  const root = createRoot(container);
  try { await body(container, element => React.act(() => root.render(element))); }
  finally { await React.act(() => root.unmount()); container.remove(); }
}

test('top-level contexts initialize without context exports, even through factory/record composition', async () => {
  assert.deepEqual(automatic.__leanjs.exports, [name('Automatic')]);
  assert.ok(automatic.__leanjs.initialized.includes(name('hiddenServices')));
  const render = text => mountElement(automatic[name('Automatic')], text);
  assert.equal(renderToString(render('SSR')), 'Hidden default: SSR');
  await mounted(async (container, update) => {
    await update(React.createElement(React.StrictMode, null, render('Browser')));
    assert.equal(container.textContent, 'Hidden default: Browser');
    await update(render('Again'));
    assert.equal(container.textContent, 'Hidden default: Again');
  });
});

test('linked contexts have object identity, default isolation, nested providers, and live updates', async () => {
  const context = shared[name('formatter')];
  assert.strictEqual(provider[name('providerContext')], context);
  assert.strictEqual(consumer[name('consumerContext')], context);
  assert.notStrictEqual(shared[name('otherFormatter')], context);
  assert.equal(provider.__leanjs.declarations.find(d => d.name === name('formatter')).importedFrom.packageName,
    'example-services');
  assert.ok(!provider.__leanjs.declarations.some(d => d.name === 'LeanReact.createContext'));
  const greeting = text => mountElement(consumer[name('Greeting')], text);
  const wrap = (heading, child) => mountElement(provider[name('Provider')],
    ctor(name('ProviderProps.mk'), [heading, child]));
  const tree = heading => wrap(heading, React.createElement(React.Fragment, null,
    greeting('Outer'), wrap('Nested', greeting('Inner')), greeting('Sibling')));
  assert.match(renderToString(tree('SSR')), /SSR: Hello, Outer/);
  assert.match(renderToString(greeting('Outside')), /Default: Outside/);
  const other = provide(null, shared[name('otherFormatter')],
    ctor(name('Formatter.mk'), ['Unrelated', text => `Other ${text}`]), greeting('Separate'));
  assert.match(renderToString(other), /Default: Separate/);
  await mounted(async (container, update) => {
    await update(tree('First'));
    await React.act(() => container.querySelector('button').click());
    await update(tree('Second'));
    assert.deepEqual([...container.querySelectorAll('.greeting')].map(x => x.textContent),
      ['Second: Hello, Outer', 'Nested: Hello, Inner', 'Second: Hello, Sibling']);
    assert.equal(container.querySelector('button').textContent, 'Count 1');
  });
});

test('ESM dependency checks reject the wrong library version before mounting', async () => {
  let source = await readFile(new URL('../../examples/generated/consumer.mjs', import.meta.url), 'utf8');
  // Resolve normal imports for an in-memory copy, then make its expected interface stale.
  source = source.replaceAll('"./shared.mjs"', JSON.stringify(new URL('../../examples/generated/shared.mjs', import.meta.url).href));
  source = source.replaceAll('"../../engine/adapters/leanjs-react.mjs"', JSON.stringify(new URL('../../engine/adapters/leanjs-react.mjs', import.meta.url).href));
  const wrong = structuredClone(shared.__leanjs.library);
  wrong.id.version = '0.0.0';
  const expected = JSON.stringify(shared.__leanjs.library);
  assert.ok(source.includes(expected));
  source = source.replace(expected, JSON.stringify(wrong));
  await assert.rejects(import(`data:text/javascript;base64,${Buffer.from(source).toString('base64')}`),
    /library interface mismatch/);
});

test('compiled collection parsing preserves raw rows and accumulates ordered nested paths', () => {
  const parse = collection['Examples.Collections.parseRows'];
  const rows = Object.freeze([
    Object.freeze(ctor('Examples.Collections.Row.mk', [1n, '', ''])),
    Object.freeze(ctor('Examples.Collections.Row.mk', [2n, 'Valid', ''])),
  ]);
  const before = structuredClone(rows);
  const result = parse(rows);
  assert.equal(result.tag, 'Except.error');
  const errors = result.fields[0];
  const all = [errors.fields[0]];
  for (let rest = errors.fields[1]; rest.tag === 'List.cons'; rest = rest.fields[1]) all.push(rest.fields[0]);
  assert.deepEqual(all.map(error => {
    const path = error.fields[1];
    return [path.fields[0].fields[0], path.fields[1].fields[0].fields[1]];
  }), [[0n, 'title'], [0n, 'detail'], [1n, 'detail']]);
  assert.deepEqual(rows, before);
  assert.deepEqual(parse([]), ctor('Except.ok', [[]]));
  const valid = [ctor('Examples.Collections.Row.mk', [5n, 'Title', 'Detail'])];
  assert.deepEqual(parse(valid), ctor('Except.ok', [valid]));
});
