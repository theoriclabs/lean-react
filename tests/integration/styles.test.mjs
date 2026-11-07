// Typed, scoped styles (examples/lean/Examples/Styles.lean) with the extracted stylesheet applied.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { JSDOM } from 'jsdom';

const css = readFileSync(new URL('../../examples/generated/styles.css', import.meta.url), 'utf8');
const { window } = new JSDOM(`<!doctype html><html><head><style>${css}</style></head><body></body></html>`);
Object.assign(globalThis, { window, document: window.document, HTMLElement: window.HTMLElement,
  IS_REACT_ACT_ENVIRONMENT: true });
const React = await import('react');
const { createRoot } = await import('react-dom/client');
const { mountElement } = await import('../../engine/adapters/leanjs-react.mjs');
const program = await import('../../examples/generated/smoke.mjs');

test('styles with the same name in different places get different classes, so rules do not leak', async () => {
  const container = document.createElement('div');
  document.body.append(container);
  const root = createRoot(container);
  await React.act(() => root.render(mountElement(program['Examples.Styles.Demo'])));
  try {
    const get = id => container.querySelector(`[data-testid="${id}"]`);
    const style = element => window.getComputedStyle(element);
    const bar = get('bar'), text = get('inspector-read');
    const swatch = get('legend').querySelector('span');
    const bands = [...container.querySelectorAll('[data-testid="band"]')];
    // Yellow bug 1: the chart's `use-read` colours bars; the inspector's `use-read` colours text only.
    assert.match(bar.className, /^use-read-\d+$/);
    assert.match(text.className, /^use-read-\d+$/);
    assert.notEqual(bar.className, text.className);
    // (jsdom reports a `var()` background only through the shorthand.)
    assert.equal(style(bar).background, 'var(--read)');
    assert.equal(style(text).background, '', 'the bar colour does not reach the text');
    assert.equal(style(text).color, 'var(--read)');
    // Yellow bug 2: the bands' `held` is absolutely positioned; the legend's `held` is not.
    assert.notEqual(swatch.className, bands[0].className);
    assert.equal(style(bands[0]).position, 'absolute');
    assert.equal(style(swatch).position, 'static', 'the legend swatch stays in the legend');
    assert.equal(style(swatch).display, 'inline-block');
    // Typed inline lengths render as CSS text.
    assert.equal(bands[0].style.left, '10%');
    assert.equal(bands[1].style.width, '20%');
    assert.equal(bar.style.width, '40%');
    // Tokens are custom properties on :root.
    assert.match(css, /^:root\{--accent:#5b7f4b;--gutter:8px;--read:#3a6ea5;\}/);
    // Each class is declared once.
    const classes = [...css.matchAll(/^\.([\w-]+)\{/gm)].map(m => m[1]);
    assert.equal(new Set(classes).size, classes.length);
  } finally {
    await React.act(() => root.unmount());
    container.remove();
  }
});
