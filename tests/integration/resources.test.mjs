import test from 'node:test';
import assert from 'node:assert/strict';
import { JSDOM } from 'jsdom';
import { action, pureAction } from '../../engine/runtime/actions.mjs';

const { window } = new JSDOM('<!doctype html><html><body></body></html>');
Object.assign(globalThis, { window, document: window.document, HTMLElement: window.HTMLElement,
  IS_REACT_ACT_ENVIRONMENT: true });
const React = await import('react');
const { createRoot } = await import('react-dom/client');
const { mountElement, ctor } = await import('../../engine/adapters/leanjs-react.mjs');
const program = await import('../../examples/generated/tickets.mjs');
const seed = program['Examples.Tickets.initialTickets'];
const deferred = () => { let resolve; const promise = new Promise(done => { resolve = done; }); return { promise, resolve }; };
const titled = title => seed.map((ticket, index) => index ? ticket : ctor(ticket.tag, [
  ticket.fields[0], ticket.fields[1], ctor(ticket.fields[2].tag, [
    ctor('Examples.Tickets.Title.mk', [title]), ...ticket.fields[2].fields.slice(1),
  ]),
]));
// WorkspaceProps.load defaults to `service.list` in Lean; JS constructors must supply the slot explicitly.
const workspaceProps = (key, service) => ctor('Examples.Tickets.WorkspaceProps.mk', [key, service, _request => service.fields[0]]);

test('compiled workspace composes replaceable async services and suppresses obsolete query replies', async () => {
  const first = deferred(), second = deferred(), refresh = deferred();
  let loads = 0;
  const service = load => ctor('Examples.Tickets.TicketService.mk', [
    action(load), _input => pureAction(ctor('Except.error', [ctor('Examples.Tickets.SaveError.notFound')])),
  ]);
  const firstService = service(() => first.promise);
  const secondService = service(() => ++loads === 1 ? second.promise : refresh.promise);
  const view = (key, source) => mountElement(program['Examples.Tickets.Workspace'], workspaceProps(key, source));
  const container = document.createElement('div');
  document.body.append(container);
  const root = createRoot(container);
  try {
    await React.act(() => root.render(view('first', firstService)));
    await React.act(() => root.render(view('second', secondService)));
    await React.act(async () => { second.resolve(titled('Current service')); await second.promise; });
    assert.equal(container.querySelector('.card h3').textContent, 'Current service');
    await React.act(async () => { first.resolve(titled('Obsolete service')); await first.promise; });
    assert.equal(container.querySelector('.card h3').textContent, 'Current service');
    const reload = [...container.querySelectorAll('button')].find(button => button.textContent === 'Reload tickets');
    await React.act(() => reload.click());
    assert.equal(container.querySelector('.card h3').textContent, 'Current service');
    await React.act(async () => { refresh.resolve(titled('Refreshed service')); await refresh.promise; });
    assert.equal(container.querySelector('.card h3').textContent, 'Refreshed service');
    assert.equal(loads, 2);
  } finally { await React.act(() => root.unmount()); container.remove(); }
});

test('an old service save cannot update a newly mounted workspace with matching public IDs', async () => {
  const pendingSave = deferred();
  let saves = 0;
  const source = (title, save) => ctor('Examples.Tickets.TicketService.mk', [pureAction(titled(title)), save]);
  const firstService = source('First source', _input => action(() => { saves++; return pendingSave.promise; }));
  const secondService = source('Second source', _input => pureAction(ctor('Except.error', [ctor('Examples.Tickets.SaveError.notFound')])));
  const view = (key, service) => mountElement(program['Examples.Tickets.Workspace'], workspaceProps(key, service));
  const container = document.createElement('div'); document.body.append(container);
  const root = createRoot(container);
  const click = text => React.act(() => [...container.querySelectorAll('button')].find(button => button.textContent === text).click());
  try {
    await React.act(() => root.render(view('first', firstService)));
    await click('Edit ticket'); await click('Save changes');
    assert.equal(saves, 1);
    await React.act(() => root.render(view('second', secondService)));
    assert.equal(container.querySelector('.card h3').textContent, 'Second source');
    await React.act(async () => { pendingSave.resolve(ctor('Except.ok', [titled('Late old save')[0]])); await pendingSave.promise; });
    assert.equal(container.querySelector('.card h3').textContent, 'Second source');
    assert.equal(container.querySelector('.editor'), null);
  } finally { await React.act(() => root.unmount()); container.remove(); }
});

test('a query started before a completed save cannot replace its newer revision', async () => {
  const pendingQuery = deferred(); let loads = 0;
  const updated = titled('Completed save')[0];
  updated.fields[1] = 2n;
  const service = ctor('Examples.Tickets.TicketService.mk', [
    action(() => ++loads === 1 ? seed : pendingQuery.promise), _input => pureAction(ctor('Except.ok', [updated])),
  ]);
  const container = document.createElement('div'); document.body.append(container);
  const root = createRoot(container);
  const click = text => React.act(() => [...container.querySelectorAll('button')].find(button => button.textContent === text).click());
  try {
    await React.act(() => root.render(mountElement(program['Examples.Tickets.Workspace'], workspaceProps('one', service))));
    await click('Edit ticket'); await click('Reload tickets'); await click('Save changes');
    assert.equal(container.querySelector('.card h3').textContent, 'Completed save');
    await React.act(async () => { pendingQuery.resolve(seed); await pendingQuery.promise; });
    assert.equal(container.querySelector('.card h3').textContent, 'Completed save');
    assert.equal(container.querySelector('.card .note').textContent, 'Revision 2');
  } finally { await React.act(() => root.unmount()); container.remove(); }
});
