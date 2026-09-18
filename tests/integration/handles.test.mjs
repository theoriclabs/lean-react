import test from 'node:test';
import assert from 'node:assert/strict';
import { JSDOM, VirtualConsole } from 'jsdom';

// jsdom has no canvas 2D context; keep its "not implemented" notes out of the React warning capture below.
const virtualConsole = new VirtualConsole().forwardTo(console, { jsdomErrors: 'none' });
const { window } = new JSDOM('<!doctype html><html><body></body></html>', { virtualConsole });
Object.assign(globalThis, { window, document: window.document, HTMLElement: window.HTMLElement,
  IS_REACT_ACT_ENVIRONMENT: true });
const React = await import('react');
const { createRoot } = await import('react-dom/client');
const { mountElement, ctor, runAction } = await import('../../engine/adapters/leanjs-react.mjs');
await import('../../examples/adapters/example-sparkline.mjs');
const program = await import('../../examples/generated/smoke.mjs');
const Demo = program['Examples.Sparkline.Demo'];
const demoProps = () => ctor('Examples.Sparkline.DemoProps.mk', [program['Examples.Sparkline.SparklineOps.silent']]);

async function mounted(element) {
  const warnings = [];
  const originalError = console.error;
  console.error = (...args) => warnings.push(args.map(String).join(' '));
  const container = document.createElement('div');
  document.body.append(container);
  const root = createRoot(container);
  await React.act(() => root.render(element));
  const click = text => React.act(() => [...container.querySelectorAll('button')].find(button => button.textContent === text).click());
  return {
    container, warnings, click,
    status: () => container.querySelector('[role="status"]').textContent,
    events: () => container.querySelector('[data-testid="sparkline-events"]').textContent,
    close: async () => { try { await React.act(() => root.unmount()); container.remove(); } finally { console.error = originalError; } },
  };
}

test('onReady fires once per mount, ops resolve to .unmounted after unmount, and a keyed remount fires onGone then onReady', async () => {
  const f = await mounted(mountElement(Demo, demoProps()));
  try {
    assert.equal(f.events(), 'ready');
    assert.equal(f.status(), 'Canvas ready.');
    const canvas = f.container.querySelector('canvas');
    assert.equal(canvas.getAttribute('aria-label'), 'Sparkline');
    await f.click('Draw next series');
    assert.equal(f.status(), 'Drew 8 points.');
    assert.equal(canvas.dataset.points, '8');
    await f.click('Clear');
    assert.equal(f.status(), 'Cleared.');
    assert.equal(canvas.dataset.points, undefined);

    await f.click('Unmount canvas');
    assert.equal(f.events(), 'ready → gone');
    assert.equal(f.container.querySelector('canvas'), null);
    await f.click('Draw next series');
    assert.equal(f.status(), 'The canvas was unmounted; nothing drawn.');
    await f.click('Clear');
    assert.equal(f.status(), 'The canvas was unmounted; nothing cleared.');

    await f.click('Mount canvas');
    assert.equal(f.events(), 'ready → gone → ready');
    const remounted = f.container.querySelector('canvas');
    assert.notEqual(remounted, canvas);
    await f.click('Draw next series');
    assert.equal(f.status(), 'Drew 9 points.');
    assert.equal(remounted.dataset.points, '9');

    await f.click('Recreate canvas');
    assert.equal(f.events(), 'ready → gone → ready → gone → ready');
    assert.notEqual(f.container.querySelector('canvas'), remounted);
    await f.click('Draw next series');
    assert.equal(f.status(), 'Drew 7 points.');
    assert.deepEqual(f.warnings, []);
  } finally { await f.close(); }
});

test('Strict Mode double-invoked effects stay balanced and the retained handle follows the live instance', async () => {
  const f = await mounted(React.createElement(React.StrictMode, null, mountElement(Demo, demoProps())));
  try {
    const events = f.events().split(' → ');
    assert.equal(events.at(-1), 'ready');
    assert.equal(events.filter(event => event === 'ready').length, events.filter(event => event === 'gone').length + 1);
    await f.click('Draw next series');
    assert.equal(f.status(), 'Drew 8 points.');
    assert.deepEqual(f.warnings, []);
  } finally { await f.close(); }
});

test('a handle built by the adapter reports alive and typed HandleResult values, including .unmounted', async () => {
  let handle;
  const { runtime, foreign, unit, fromBool } = await import('../../engine/adapters/leanjs-react.mjs');
  const { action, pureAction } = await import('../../engine/runtime/actions.mjs');
  const props = ctor('Examples.Sparkline.SparklineProps.mk', [100n, 20n, 'red']);
  const Direct = runtime.component(() => runtime.mapHook(() => foreign(null, null, 'sparkline', ctor('LeanReact.ForeignProps.mk', [
    props, received => action(() => { handle = received; }), pureAction(unit), null,
  ])), runtime.useState(0, 'probe')));
  const container = document.createElement('div'); document.body.append(container);
  const root = createRoot(container);
  try {
    await React.act(() => root.render(runtime.element(Direct, null)));
    assert.equal(handle.tag, 'LeanReact.Handle.mk');
    const [ops, alive] = handle.fields;
    assert.equal(fromBool(runAction(alive)), true);
    const drawn = runAction(ops.fields[0]([1n, 2n, 3n]));
    assert.deepEqual(drawn, ctor('LeanReact.HandleResult.ok', [3n]));
    assert.deepEqual(runAction(ops.fields[1]), ctor('LeanReact.HandleResult.ok', [unit]));
    await React.act(() => root.unmount());
    assert.equal(fromBool(runAction(alive)), false);
    assert.deepEqual(runAction(ops.fields[0]([1n])), ctor('LeanReact.HandleResult.unmounted'));
  } finally { container.remove(); }
});
