import test from 'node:test';
import assert from 'node:assert/strict';
import { JSDOM } from 'jsdom';

const { window } = new JSDOM('<!doctype html><html><body></body></html>');
Object.assign(globalThis, { window, document: window.document, HTMLElement: window.HTMLElement,
  IS_REACT_ACT_ENVIRONMENT: true });
const React = await import('react');
const { createRoot } = await import('react-dom/client');
const { runtime, useCell, ctor, runAction } = await import('../../engine/adapters/leanjs-react.mjs');
const program = await import('../../examples/generated/tickets.mjs');

test('the compiled local service atomically rejects two same-revision saves in one React batch', async () => {
  let service;
  const seed = program['Examples.Tickets.initialTickets'];
  const Probe = runtime.component(() => runtime.mapHook(cell => {
    service = program['Examples.Tickets.memoryService'](cell);
    return runtime.empty;
  }, useCell(null, seed, 'local-store')));
  const container = document.createElement('div'); document.body.append(container);
  const root = createRoot(container);
  try {
    await React.act(() => root.render(runtime.element(Probe, null)));
    const input = title => ctor('Examples.Tickets.SaveTicket.mk', [seed[0].fields[0], 1n,
      ctor('Examples.Tickets.Title.mk', [title]), seed[0].fields[2].fields[1]]);
    let first, second;
    await React.act(() => {
      first = runAction(service.fields[1](input('First')));
      second = runAction(service.fields[1](input('Second')));
    });
    assert.equal(first.tag, 'Except.ok');
    assert.equal(first.fields[0].fields[1], 2n);
    assert.equal(second.tag, 'Except.error');
    assert.equal(second.fields[0].tag, 'Examples.Tickets.SaveError.conflict');
    const current = runAction(service.fields[0])[0];
    assert.equal(current.fields[2].fields[0].fields[0], 'First');
    assert.equal(current.fields[1], 2n);
  } finally { await React.act(() => root.unmount()); container.remove(); }
});
