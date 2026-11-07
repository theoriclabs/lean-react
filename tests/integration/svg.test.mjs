// LR SVG + pointer events: the generated diagram and timeline (examples/lean/Examples/Diagram.lean).
import test from 'node:test';
import assert from 'node:assert/strict';
import { JSDOM } from 'jsdom';

const { window } = new JSDOM('<!doctype html><html><body></body></html>');
Object.assign(globalThis, { window, document: window.document, HTMLElement: window.HTMLElement,
  IS_REACT_ACT_ENVIRONMENT: true });
const React = await import('react');
const { createRoot } = await import('react-dom/client');
const { mountElement } = await import('../../engine/adapters/leanjs-react.mjs');
const program = await import('../../examples/generated/smoke.mjs');

async function mounted(element) {
  const container = document.createElement('div');
  document.body.append(container);
  const root = createRoot(container);
  await React.act(() => root.render(element));
  return { container, close: async () => { await React.act(() => root.unmount()); container.remove(); } };
}

// jsdom has no layout: give the chart a 500×60 box at (100, 20), and pointer events with coordinates.
function layout(element, box = { left: 100, top: 20, width: 500, height: 60 }) {
  element.getBoundingClientRect = () => ({ ...box, right: box.left + box.width, bottom: box.top + box.height, x: box.left, y: box.top });
  const captured = [];
  element.setPointerCapture = id => captured.push(id);
  return captured;
}
const pointer = (type, clientX, extra = {}) => {
  const event = new window.MouseEvent(type, { bubbles: true, cancelable: true, clientX, clientY: 40, button: 0, ...extra });
  Object.defineProperty(event, 'pointerId', { value: 7 });
  return event;
};
const wheel = (clientX, deltaY) => new window.WheelEvent('wheel', { bubbles: true, cancelable: true, clientX, clientY: 40, deltaY });

test('the architecture diagram is SVG with boxes, labels and arrowheads between them', async () => {
  const view = await mounted(mountElement(program['Examples.Diagram.ArchitectureDiagram']));
  try {
    const svg = view.container.querySelector('svg');
    assert.equal(svg.namespaceURI, 'http://www.w3.org/2000/svg');
    assert.equal(svg.getAttribute('viewBox'), '0 0 700 220');
    assert.equal(svg.getAttribute('aria-label'), 'Data path');
    assert.deepEqual([...svg.querySelectorAll('[data-box] text')].map(t => t.textContent), ['Global memory', 'Registers', 'ALU', 'Shared memory']);
    const marker = svg.querySelector('defs marker#arrow');
    assert.ok(marker, 'an arrowhead marker');
    assert.equal(marker.querySelector('path').getAttribute('d'), 'M0 0 L10 5 L0 10 Z');
    const arrows = [...svg.querySelectorAll('[data-arrow]')];
    assert.deepEqual(arrows.map(a => a.dataset.arrow), ['memory->registers', 'registers->alu', 'alu->shared']);
    const load = arrows[0].querySelector('line');
    assert.equal(load.getAttribute('marker-end'), 'url(#arrow)');
    // From the right edge of "Global memory" (10 + 160) to the left edge of "Registers" (270), mid-height.
    assert.deepEqual(['x1', 'y1', 'x2', 'y2'].map(name => load.getAttribute(name)), ['170', '65', '270', '65']);
    assert.equal(arrows[0].querySelector('text').textContent, 'LOAD4');
    assert.equal(load.getAttribute('stroke-width'), '2');
  } finally { await view.close(); }
});

test('the timeline scrubs while dragged (with pointer capture) and zooms around the pointer with the wheel', async () => {
  const view = await mounted(mountElement(program['Examples.Diagram.Timeline']));
  const text = id => view.container.querySelector(`[data-testid="${id}"]`).textContent;
  try {
    const chart = view.container.querySelector('[data-testid="timeline"]');
    const captured = layout(chart);
    assert.equal(text('timeline-window'), 'Showing cycles 0–4096 of 4096 (256 intervals)');
    assert.equal(chart.querySelectorAll('rect').length, 256);
    // Moves without a press do nothing.
    await React.act(() => chart.dispatchEvent(pointer('pointermove', 350)));
    assert.equal(text('timeline-cursor-text'), 'Cycle 0');
    // Press at x = 250 px of 500: cycle 2048. Drag to 475 px: 3891. The cursor line follows.
    await React.act(() => chart.dispatchEvent(pointer('pointerdown', 350)));
    assert.deepEqual(captured, [7], 'the pointer is captured for the drag');
    assert.equal(text('timeline-cursor-text'), 'Cycle 2048');
    await React.act(() => chart.dispatchEvent(pointer('pointermove', 575)));
    assert.equal(text('timeline-cursor-text'), 'Cycle 3891');
    assert.equal(view.container.querySelector('[data-testid="timeline-cursor"]').getAttribute('x1'), '949');
    // A move past the right edge clamps to the last cycle.
    await React.act(() => chart.dispatchEvent(pointer('pointermove', 900)));
    assert.equal(text('timeline-cursor-text'), 'Cycle 4095');
    await React.act(() => chart.dispatchEvent(pointer('pointerup', 900)));
    await React.act(() => chart.dispatchEvent(pointer('pointermove', 200)));
    assert.equal(text('timeline-cursor-text'), 'Cycle 4095', 'released: moves no longer scrub');
    // Wheel up at x = 125 px (cycle 1024) zooms in by two, keeping cycle 1024 under the pointer.
    const zoomIn = wheel(225, -100);
    await React.act(() => chart.dispatchEvent(zoomIn));
    assert.equal(zoomIn.defaultPrevented, true, 'the page does not scroll');
    assert.equal(text('timeline-window'), 'Showing cycles 512–2560 of 4096 (128 intervals)');
    assert.equal(chart.querySelectorAll('rect').length, 128);
    await React.act(() => chart.dispatchEvent(wheel(225, -100)));
    assert.equal(text('timeline-window'), 'Showing cycles 768–1792 of 4096 (64 intervals)');
    // Zooming out stops at the whole trace.
    for (let i = 0; i < 4; i++) await React.act(() => chart.dispatchEvent(wheel(225, 100)));
    assert.equal(text('timeline-window'), 'Showing cycles 0–4096 of 4096 (256 intervals)');
  } finally { await view.close(); }
});
