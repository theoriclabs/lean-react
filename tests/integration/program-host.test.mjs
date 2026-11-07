// The declarative component host (LeanReact.Program.Host) in jsdom.
import test from 'node:test';
import assert from 'node:assert/strict';
import { JSDOM } from 'jsdom';

const { window } = new JSDOM('<!doctype html><html><body></body></html>');
Object.assign(globalThis, { window, document: window.document, HTMLElement: window.HTMLElement, IS_REACT_ACT_ENVIRONMENT: true });
const React = await import('react');
const { createRoot } = await import('react-dom/client');
const { mountElement, ctor, unit } = await import('../../engine/adapters/leanjs-react.mjs');
const { action } = await import('../../engine/runtime/actions.mjs');
const program = await import('../../examples/generated/smoke.mjs');

async function mount(element, { strict = false } = {}) {
  const container = document.createElement('div');
  document.body.append(container);
  const root = createRoot(container);
  const errors = [];
  const original = console.error;
  console.error = (...args) => errors.push(args.map(String).join(' '));
  await React.act(() => root.render(strict ? React.createElement(React.StrictMode, null, element) : element));
  const button = label => [...container.querySelectorAll('button')].find(b => b.textContent === label);
  return {
    container, errors, button,
    click: async label => React.act(() => button(label).click()),
    text: selector => container.querySelector(selector).textContent,
    close: async () => { try { await React.act(() => root.unmount()); container.remove(); } finally { console.error = original; } },
  };
}
const setValue = async (input, value) => React.act(() => {
  Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value').set.call(input, value);
  input.dispatchEvent(new window.Event('input', { bubbles: true }));
});

test('a counter runs from update/view alone: independent instances and exact bigint arithmetic', async () => {
  const a = await mount(program['Examples.Program.counterElement'](3n));
  const b = await mount(program['Examples.Program.counterElement'](0n));
  try {
    await a.click('Add one');
    await a.click('Add 2^53 + 1');
    assert.equal(a.text('[role=status]'), 'Count: 9007199254740997');
    assert.equal(b.text('[role=status]'), 'Count: 0');
    assert.equal(b.button('Reset').disabled, true);
    await a.click('Reset');
    assert.equal(a.text('[role=status]'), 'Count: 0');
    assert.deepEqual([...a.errors, ...b.errors], []);
  } finally { await a.close(); await b.close(); }
});

test('two dispatches in one event see each other (a click bubbles to its row)', async () => {
  const view = await mount(program['Examples.Program.nestedElement']);
  try {
    await view.click('Inner');
    assert.equal(view.text('[role=status]'), 'Total 11');
    await view.click('Inner');
    assert.equal(view.text('[role=status]'), 'Total 22');
  } finally { await view.close(); }
});

test('commands run once, after the commit, in order; StrictMode never repeats update', async () => {
  const log = [];
  let view;
  const record = text => action(() => { log.push(`${text} | ${view.text('[role=status]')}`); return unit; });
  view = await mount(program['Examples.Program.logged'](record, action(() => 1n), ctor('Bool.false')), { strict: true });
  try {
    await view.click('Ping');
    assert.equal(view.text('[role=status]'), 'Pings 1');
    // The command saw the committed DOM; its follow-up message ran its own command next.
    assert.deepEqual(log, ['after 1 | Pings 1', 'pinged | Pings 1']);
    await view.click('Ping');
    assert.deepEqual(log.slice(2), ['after 2 | Pings 2', 'pinged | Pings 2']);
    assert.deepEqual(view.errors, []);
  } finally { await view.close(); }
});

test('a failing task arrives as a message instead of escaping', async () => {
  const log = [];
  const fail = action(() => { throw new Error('backend down'); });
  const view = await mount(program['Examples.Program.logged'](text => action(() => { log.push(text); return unit; }), fail, ctor('Bool.true')));
  try {
    await view.click('Ping');
    await React.act(async () => { await new Promise(r => setTimeout(r, 0)); });
    assert.equal(log.length, 1);
    assert.match(log[0], /^failed: /);
  } finally { await view.close(); }
});

test('keyed rows keep their DOM nodes and embedded children keep their models when reordered', async () => {
  const view = await mount(program['Examples.Program.boardElement']);
  try {
    const rows = () => [...view.container.querySelectorAll('li')];
    const row = id => view.container.querySelector(`li[data-row="${id}"]`);
    const addIn = async id => React.act(() => [...row(id).querySelectorAll('button')].find(b => b.textContent === 'Add one').click());
    await addIn(1); await addIn(1); await addIn(3);
    const first = row(1);
    await view.click('Reverse rows');
    assert.deepEqual(rows().map(li => li.dataset.row), ['3', '2', '1']);
    assert.equal(row(1), first, 'the same DOM node moved');
    assert.equal(row(1).querySelector('[role=status]').textContent, 'Count: 3', 'child 1 kept 1 + 1 + 1');
    assert.equal(row(3).querySelector('[role=status]').textContent, 'Count: 4');
    // A child's message mapped to the parent.
    await React.act(() => [...row(3).querySelectorAll('button')].find(b => b.textContent === 'Reset').click());
    assert.equal(view.text('[data-testid=resets]'), 'Resets 1');
    assert.equal(row(3).querySelector('[role=status]').textContent, 'Count: 0');
  } finally { await view.close(); }
});

test('event payloads: input, keydown with a synchronous preventDefault, and submit without navigation', async () => {
  const view = await mount(program['Examples.Program.todosElement']);
  try {
    const input = view.container.querySelector('input[aria-label="New todo"]');
    await setValue(input, 'Third');
    assert.equal(input.value, 'Third');
    const escape = new window.KeyboardEvent('keydown', { key: 'Escape', bubbles: true, cancelable: true });
    await React.act(() => input.dispatchEvent(escape));
    assert.equal(escape.defaultPrevented, true);
    assert.equal(input.value, '');
    await setValue(input, 'Third');
    const submit = new window.Event('submit', { bubbles: true, cancelable: true });
    await React.act(() => view.container.querySelector('form').dispatchEvent(submit));
    assert.equal(submit.defaultPrevented, true);
    assert.deepEqual([...view.container.querySelectorAll('li')].map(li => li.textContent), ['Write the plan', 'Ship P1', 'Third']);
    assert.equal(input.value, '');
    await React.act(() => view.container.querySelector('li[data-id="2"] input').click());
    assert.equal(view.container.querySelector('li[data-id="2"] input').checked, true);
    assert.deepEqual(view.errors, []);
  } finally { await view.close(); }
});

test('interop: a program inside a hook component, and a hook element inside a program view', async () => {
  const view = await mount(mountElement(program['Examples.Program.Interop']));
  try {
    assert.equal(view.text('[data-testid=hook-in-program]'), 'hook element');
    await view.click('Program +1');
    assert.match(view.text('[data-testid=program]'), /^Program 101/);
    assert.equal(view.text('[data-testid=outer]'), 'Outer 1', 'onMsg reached the hook state');
  } finally { await view.close(); }
});
