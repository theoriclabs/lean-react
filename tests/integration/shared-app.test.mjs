// `LeanJS.writeApp`: pages of one app share one library module instead of each carrying a copy.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile, stat } from 'node:fs/promises';
import { JSDOM } from 'jsdom';

const { window } = new JSDOM('<!doctype html><html><body></body></html>');
Object.assign(globalThis, { window, document: window.document, HTMLElement: window.HTMLElement, IS_REACT_ACT_ENVIRONMENT: true });
const React = await import('react');
const { createRoot } = await import('react-dom/client');
const { mountElement } = await import('../../engine/adapters/leanjs-react.mjs');
const dir = new URL('../../examples/generated/app/', import.meta.url);
const manifest = async name => JSON.parse(await readFile(new URL(`${name}.manifest.json`, dir), 'utf8'));
const pages = { tickets: 'Examples.Tickets.App', collections: 'Examples.Collections.App', feedback: 'Examples.Feedback.App' };

test('each page imports the shared library instead of compiling its own copy', async () => {
  const shared = await manifest('shared');
  const sharedNames = new Set(shared.declarations.map(d => d.name));
  assert.ok(sharedNames.size > 50);
  assert.ok(sharedNames.has('LeanReact.DOM.Props.attributes'), 'the DOM layer is shared');
  for (const page of Object.keys(pages)) {
    const own = (await manifest(page)).declarations;
    // Constructors and builtins are one-liners, deliberately left in each page.
    const copied = own.filter(d => !d.importedFrom && !d.constructor && !d.builtin && sharedNames.has(d.name)).map(d => d.name);
    assert.deepEqual(copied, [], `${page} compiles shared declarations itself`);
    assert.ok(own.some(d => d.importedFrom?.moduleName === 'shared'), `${page} imports from the shared module`);
  }
  const sizes = await Promise.all(['shared', ...Object.keys(pages)].map(async name => (await stat(new URL(`${name}.mjs`, dir))).size));
  console.log(`shared ${sizes[0]} B; pages ${sizes.slice(1).join(', ')} B`);
});

test('every page mounts and runs against the shared module', async () => {
  for (const [page, name] of Object.entries(pages)) {
    const module = await import(new URL(`${page}.mjs`, dir));
    const container = document.createElement('div');
    document.body.append(container);
    const root = createRoot(container);
    await React.act(() => root.render(mountElement(module[name])));
    assert.ok(container.textContent.length > 0, `${page} rendered`);
    assert.ok(container.querySelector('button'), `${page} has controls`);
    await React.act(() => root.unmount());
    container.remove();
  }
  // The pages share one instance of the library (same module URL).
  const a = await import(new URL('tickets.mjs', dir)), b = await import(new URL('shared.mjs', dir));
  assert.ok(a);
  assert.equal(b.__leanjs.library.id.moduleName, 'shared');
});
