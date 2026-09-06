import test from 'node:test';
import assert from 'node:assert/strict';
import { JSDOM } from 'jsdom';

const { window } = new JSDOM('<!doctype html><html><body></body></html>');
Object.assign(globalThis, { window, document: window.document, HTMLElement: window.HTMLElement,
  IS_REACT_ACT_ENVIRONMENT: true });
const React = await import('react');
const { createRoot } = await import('react-dom/client');
const { mountElement, ctor } = await import('../../engine/adapters/leanjs-react.mjs');
const program = await import('../../examples/generated/smoke.mjs');
const Counter = program['Examples.Tickets.Counter'];

test('compiled Lean counter has independent instances, exact integers, and retained closures', async () => {
  const container = document.createElement('div');
  document.body.append(container);
  const root = createRoot(container);
  const start = 90071992547409931234567890n;
  const props = (label, initial) => ctor('Examples.Tickets.CounterProps.mk', [label, initial]);
  const render = label => React.createElement(React.StrictMode, null,
    mountElement(Counter, props(label, start)), mountElement(Counter, props('Second', 10n)));
  try {
    await React.act(() => root.render(render('First')));
    assert.deepEqual([...container.querySelectorAll('strong')].map(x => x.textContent), [String(start), '10']);
    await React.act(() => container.querySelector('button').click());
    assert.equal(container.querySelector('strong').textContent, String(start + 1n));
    await React.act(() => root.render(render('Renamed')));
    await React.act(() => container.querySelector('button').click());
    assert.equal(container.querySelector('button').getAttribute('aria-label'), 'Increment Renamed');
    assert.deepEqual([...container.querySelectorAll('strong')].map(x => x.textContent), [String(start + 2n), '10']);
  } finally {
    await React.act(() => root.unmount());
    container.remove();
  }
});

test('compiled keyed children retain state and DOM identity when reordered', async () => {
  const container = document.createElement('div');
  document.body.append(container);
  const root = createRoot(container);
  const Collection = program['Examples.Composition.Counters'];
  try {
    await React.act(() => root.render(mountElement(Collection, ['Alpha', 'Beta'])));
    const alpha = container.querySelector('button');
    await React.act(() => alpha.click());
    await React.act(() => root.render(mountElement(Collection, ['Beta', 'Alpha'])));
    assert.equal(container.querySelectorAll('button')[1], alpha);
    assert.deepEqual([...container.querySelectorAll('strong')].map(x => x.textContent), ['0', '1']);
  } finally { await React.act(() => root.unmount()); container.remove(); }
});

test('compiled context carries a function-bearing service and follows provider updates', async () => {
  const container = document.createElement('div');
  document.body.append(container);
  const root = createRoot(container);
  const Formatted = program['Examples.Composition.Formatted'];
  try {
    await React.act(() => root.render(mountElement(Formatted, 'First')));
    assert.equal(container.textContent, 'First: Hello, Lean');
    await React.act(() => root.render(mountElement(Formatted, 'Second')));
    assert.equal(container.textContent, 'Second: Hello, Lean');
  } finally { await React.act(() => root.unmount()); container.remove(); }
});

test('a typed foreign React binding receives a live Lean callback and child element', async () => {
  const container = document.createElement('div');
  document.body.append(container);
  const root = createRoot(container);
  try {
    await React.act(() => root.render(mountElement(program['Examples.Foreign.Interop'])));
    assert.equal(container.querySelector('span').textContent, '0');
    await React.act(() => container.querySelector('button').click());
    assert.equal(container.querySelector('span').textContent, '1');
  } finally { await React.act(() => root.unmount()); container.remove(); }
});
