// Commands and subscriptions of declarative components (P3), under mocked timers.
import test, { mock } from 'node:test';
import assert from 'node:assert/strict';
import { JSDOM } from 'jsdom';

const { window } = new JSDOM('<!doctype html><html><body></body></html>', { url: 'http://localhost/start' });
Object.assign(globalThis, { window, document: window.document, HTMLElement: window.HTMLElement,
  localStorage: window.localStorage, IS_REACT_ACT_ENVIRONMENT: true });
const React = await import('react');
const { createRoot } = await import('react-dom/client');
const { unit } = await import('../../engine/adapters/leanjs-react.mjs');
const { action, runAction } = await import('../../engine/runtime/actions.mjs');
const program = await import('../../examples/generated/smoke.mjs');

async function mount(element) {
  const container = document.createElement('div');
  document.body.append(container);
  const root = createRoot(container);
  await React.act(() => root.render(element));
  return {
    container,
    click: async label => React.act(() => [...container.querySelectorAll('button')].find(b => b.textContent === label).click()),
    text: selector => container.querySelector(selector).textContent,
    close: async () => { await React.act(() => root.unmount()); container.remove(); },
  };
}
const flush = () => React.act(async () => { for (let i = 0; i < 5; i++) await Promise.resolve(); });

test('a timer subscription starts and stops with the model; a key subscription stops it', async () => {
  mock.timers.enable({ apis: ['setInterval', 'setTimeout'] });
  const view = await mount(program['Examples.Program.clockElement']);
  try {
    await React.act(() => mock.timers.tick(5000));
    assert.equal(view.text('[role=status]'), 'Ticks 0', 'not running: no timer');
    await view.click('Start');
    await React.act(() => mock.timers.tick(3000));
    assert.equal(view.text('[role=status]'), 'Ticks 3');
    await React.act(() => document.dispatchEvent(new window.KeyboardEvent('keydown', { key: 'x' })));
    await React.act(() => mock.timers.tick(1000));
    assert.equal(view.text('[role=status]'), 'Ticks 4', 'other keys are ignored');
    await React.act(() => document.dispatchEvent(new window.KeyboardEvent('keydown', { key: 'Escape' })));
    await React.act(() => mock.timers.tick(5000));
    assert.equal(view.text('[role=status]'), 'Ticks 4', 'stopped: the interval was cleared');
    await view.click('Start');
    await React.act(() => mock.timers.tick(2000));
    assert.equal(view.text('[role=status]'), 'Ticks 6');
  } finally { await view.close(); mock.timers.reset(); }
});

test('a host source keyed by game id: switching games stops the old feed; unmount stops all', async () => {
  localStorage.clear();
  const active = new Map();
  const watch = (game, emit) => action(() => { active.set(game, emit); return action(() => { active.delete(game); return unit; }); });
  const signIn = name => action(() => Promise.resolve(`signed in as ${name}`));
  const emit = async (game, move) => React.act(() => runAction(active.get(game)(move)));
  const view = await mount(program['Examples.Program.watcherElement'](watch, signIn));
  try {
    assert.deepEqual([...active.keys()], ['g1']);
    await emit('g1', 'e4');
    assert.equal(view.text('[role=status]'), 'Game g1: e4');
    await view.click('Game 2');
    assert.deepEqual([...active.keys()], ['g2'], 'g1 stopped, g2 started');
    assert.equal(localStorage.getItem('watcher.game'), 'g2', 'Cmd.store');
    assert.equal(document.activeElement?.id, 'moves', 'Cmd.focus');
    await emit('g2', 'd4');
    assert.equal(view.text('[role=status]'), 'Game g2: d4');
    await view.click('Game 2');
    assert.deepEqual([...active.keys()], ['g2'], 'an unchanged key keeps its source');
  } finally { await view.close(); }
  assert.equal(active.size, 0, 'unmount stopped every source');
  // A new watcher reads the stored game (Cmd.load) and watches it.
  const again = await mount(program['Examples.Program.watcherElement'](watch, signIn));
  try {
    await flush();
    assert.match(again.text('[role=status]'), /^Game g2/);
    assert.deepEqual([...active.keys()], ['g2']);
  } finally { await again.close(); }
});

test('Cmd.perform resolves asynchronously; success navigates through the router history; failure is a message', async () => {
  const watch = (_game, _emit) => action(() => action(() => unit));
  const ok = await mount(program['Examples.Program.watcherElement'](watch, name => action(() => Promise.resolve(`hi ${name}`))));
  try {
    await ok.click('Sign in');
    await flush();
    assert.equal(ok.text('[data-testid=user]'), 'hi ada');
    assert.equal(window.location.pathname, '/games/g2', 'Cmd.navigate pushed the path');
  } finally { await ok.close(); }
  const failing = await mount(program['Examples.Program.watcherElement'](watch, _name => action(() => Promise.reject(new Error('locked out')))));
  try {
    await failing.click('Sign in');
    await flush();
    assert.match(failing.text('[data-testid=user]'), /^error: /);
  } finally { await failing.close(); }
});

test('Cmd.after delivers later without holding up the next command; Cmd.random stays in range', async () => {
  mock.timers.enable({ apis: ['setTimeout'] });
  const view = await mount(program['Examples.Program.watcherElement']((_game, _emit) => action(() => action(() => unit)), _name => action(() => 'x')));
  try {
    await view.click('Later');
    await view.click('Roll');
    await flush();
    assert.match(view.text('[role=status]'), /: rolled [0-5]$/, 'the roll did not wait for the timer');
    await React.act(async () => { mock.timers.tick(500); for (let i = 0; i < 5; i++) await Promise.resolve(); });
    assert.match(view.text('[role=status]'), /rolled [0-5], late$/);
  } finally { await view.close(); mock.timers.reset(); }
});
