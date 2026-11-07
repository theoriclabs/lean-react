// Large views (examples/lean/Examples/Large.lean): virtual list and grid, and the canvas timeline.
import test from 'node:test';
import assert from 'node:assert/strict';
import { JSDOM, VirtualConsole } from 'jsdom';

// jsdom has no canvas 2D context; keep its "not implemented" note quiet.
const virtualConsole = new VirtualConsole().forwardTo(console, { jsdomErrors: 'none' });
const { window } = new JSDOM('<!doctype html><html><body></body></html>', { virtualConsole });
Object.assign(globalThis, { window, document: window.document, HTMLElement: window.HTMLElement,
  IS_REACT_ACT_ENVIRONMENT: true });
const React = await import('react');
const { createRoot } = await import('react-dom/client');
const { mountElement } = await import('../../engine/adapters/leanjs-react.mjs');
await import('../../examples/adapters/example-timeline.mjs');
const program = await import('../../examples/generated/smoke.mjs');

async function mounted(element) {
  const container = document.createElement('div');
  document.body.append(container);
  const root = createRoot(container);
  await React.act(() => root.render(element));
  return { container, close: async () => { await React.act(() => root.unmount()); container.remove(); } };
}
// jsdom has no layout: scrolling sets the offsets and fires the event.
async function scrollTo(element, top, left = 0) {
  Object.defineProperty(element, 'scrollTop', { configurable: true, value: top });
  Object.defineProperty(element, 'scrollLeft', { configurable: true, value: left });
  await React.act(() => element.dispatchEvent(new window.Event('scroll')));
}
const indices = list => [...list.querySelectorAll('[role=listitem]')].map(row => Number(row.dataset.index));

test('a 100,000-row list renders only the visible window plus overscan, keyed and positioned', async () => {
  const view = await mounted(mountElement(program['Examples.Large.EventList']));
  try {
    const list = view.container.querySelector('[data-virtual=list]');
    assert.equal(list.getAttribute('aria-label'), 'Events');
    assert.equal(list.querySelector('[role=list]').style.height, `${100000 * 28}px`, 'the spacer is as tall as every row');
    // 280 px viewport / 28 px rows: 10 rows, one partial, and 4 rows of overscan below.
    assert.deepEqual(indices(list), Array.from({ length: 15 }, (_, i) => i));
    await scrollTo(list, 28 * 50000 + 10);
    const shown = indices(list);
    assert.deepEqual([shown[0], shown.at(-1)], [49996, 50014]);
    assert.ok(shown.length <= 11 + 2 * 4);
    const row = list.querySelector('[data-index="50000"]');
    assert.equal(row.style.top, `${50000 * 28}px`);
    assert.equal(row.textContent, 'Event 50000 · cycle 800000');
    // Growing the data keeps the scroll position and the rendered window.
    await React.act(() => [...view.container.querySelectorAll('button')].find(b => b.textContent === 'Add 1,000 rows').click());
    assert.equal(view.container.querySelector('[data-testid=event-count]').textContent, '101000 rows');
    assert.equal(list.scrollTop, 28 * 50000 + 10);
    assert.equal(list.querySelector('[data-index="50000"]'), row, 'the row element is kept');
    assert.equal(list.querySelector('[role=list]').style.height, `${101000 * 28}px`);
    await scrollTo(list, 28 * 100999);
    assert.equal(indices(list).at(-1), 100999);
  } finally { await view.close(); }
});

test('a 3,000 × 200 grid renders the visible cells and keeps the label column in view', async () => {
  const view = await mounted(mountElement(program['Examples.Large.EventGrid']));
  try {
    const grid = view.container.querySelector('[role=grid]');
    const cells = () => [...grid.querySelectorAll('[role=gridcell]')];
    // 240/24 = 10 rows + 1 + 2 overscan; 640/72 = 9 columns + 1 + 2 overscan.
    assert.equal(cells().length, 13 * 12);
    await scrollTo(grid, 24 * 1500, 72 * 100);
    const shown = cells();
    // Rows 1498–1512 (11 visible + 2 overscan each side), columns 98–111 (10 + 2 + 2) and the sticky column 0.
    assert.equal(shown.length, 15 * (14 + 1));
    const label = grid.querySelector('[data-row="1500"][data-column="0"]');
    assert.equal(label.textContent, 'Unit 1500');
    assert.equal(label.style.left, `${72 * 100}px`, 'the sticky label column follows the horizontal scroll');
    const cell = grid.querySelector('[data-row="1500"][data-column="100"]');
    assert.equal(cell.textContent, String((1500 * 31 + 100 * 17) % 100));
    assert.equal(cell.style.left, `${72 * 100}px`);
    assert.equal(grid.querySelector('[data-column="50"]'), null, 'columns left of the window are not rendered');
  } finally { await view.close(); }
});

test('a canvas draws a million intervals from Lean and a click maps back to the right interval', async () => {
  const view = await mounted(mountElement(program['Examples.Large.TimelineDemo']));
  const status = () => view.container.querySelector('[data-testid=timeline-pick]').textContent;
  try {
    assert.equal(view.container.querySelector('canvas').dataset.intervals, '1000000');
    assert.equal(status(), 'Drew 1000000 intervals. Click one.');
    const frame = view.container.querySelector('[data-testid=timeline-canvas]');
    frame.getBoundingClientRect = () => ({ left: 20, top: 0, width: 1000, height: 48 });
    const click = async clientX => React.act(() => frame.dispatchEvent(
      new window.MouseEvent('pointerdown', { bubbles: true, clientX, clientY: 10 })));
    // x = 500 of 1000 px: cycle 2,000,000, inside interval 500,000 = [2,000,000, 2,000,003).
    await click(520);
    assert.equal(status(), 'Interval 500000: cycles 2000000–2000003 (clicked cycle 2000000)');
    await click(20);
    assert.equal(status(), 'Interval 0: cycles 0–1 (clicked cycle 0)');
    // x = 999: cycle 3,996,000 = interval 999,000's start.
    await click(1019);
    assert.equal(status(), 'Interval 999000: cycles 3996000–3996001 (clicked cycle 3996000)');
  } finally { await view.close(); }
});
