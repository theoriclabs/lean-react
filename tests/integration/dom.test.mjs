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

async function mounted() {
  const container = document.createElement('div');
  document.body.append(container);
  const root = createRoot(container);
  await React.act(() => root.render(React.createElement(React.StrictMode, null, mountElement(program['Examples.Feedback.App']))));
  const byTestId = id => container.querySelector(`[data-testid="${id}"]`);
  const dispatch = (target, event) => { let prevented; React.act(() => { target.dispatchEvent(event); prevented = event.defaultPrevented; }); return prevented; };
  const setValue = (target, value) => React.act(() => {
    const setter = Object.getOwnPropertyDescriptor(Object.getPrototypeOf(target), 'value').set;
    setter.call(target, value);
    target.dispatchEvent(new window.Event(target.tagName === 'SELECT' ? 'change' : 'input', { bubbles: true }));
  });
  return { container, byTestId, dispatch, setValue, close: async () => { await React.act(() => root.unmount()); container.remove(); } };
}

test('a compiled form renders typed textarea/select/data-*/style props and validates on blur', async () => {
  const f = await mounted();
  try {
    const form = f.container.querySelector('form');
    assert.equal(form.getAttribute('aria-label'), 'Feedback');
    const message = f.byTestId('feedback-message');
    assert.equal(message.tagName, 'TEXTAREA');
    assert.equal(message.getAttribute('rows'), '4');
    assert.equal(message.getAttribute('spellcheck'), 'true');
    assert.equal(message.style.resize, 'vertical');
    assert.equal(message.style.minHeight, '6rem');
    const topic = f.byTestId('feedback-topic');
    assert.equal(topic.tagName, 'SELECT');
    assert.deepEqual([...topic.options].map(option => option.value), ['idea', 'bug', 'question']);
    assert.equal(topic.value, 'idea');
    const name = f.byTestId('feedback-name');
    assert.equal(name.getAttribute('aria-describedby'), 'feedback-name-error');
    assert.equal(name.getAttribute('autocomplete'), 'name');
    await React.act(() => { name.focus(); name.blur(); });
    assert.equal(f.container.querySelector('[role="alert"]').textContent, 'Name is required.');
    await f.setValue(name, 'Ada');
    await React.act(() => { name.focus(); name.blur(); });
    assert.equal(f.container.querySelector('[role="alert"]').textContent, '');
    await f.setValue(topic, 'bug');
    assert.equal(topic.value, 'bug');
  } finally { await f.close(); }
});

test('submit is always default-prevented and Enter-to-submit reads the committed draft', async () => {
  const f = await mounted();
  try {
    const form = f.container.querySelector('form');
    const status = f.byTestId('feedback-status');
    assert.equal(f.dispatch(form, new window.Event('submit', { bubbles: true, cancelable: true })), true);
    assert.equal(status.textContent, 'Add your name before sending.');
    await f.setValue(f.byTestId('feedback-name'), 'Ada');
    await f.setValue(f.byTestId('feedback-topic'), 'question');
    await f.setValue(f.byTestId('feedback-message'), 'Hello there');
    assert.equal(f.dispatch(form, new window.Event('submit', { bubbles: true, cancelable: true })), true);
    assert.equal(status.textContent, 'Sent A question from Ada (11 characters).');
  } finally { await f.close(); }
});

test('KeyOutcome.preventDefault stops the browser default synchronously and continue leaves it alone', async () => {
  const f = await mounted();
  try {
    const message = f.byTestId('feedback-message');
    const status = f.byTestId('feedback-status');
    const key = init => new window.KeyboardEvent('keydown', { bubbles: true, cancelable: true, ...init });
    assert.equal(f.dispatch(message, key({ key: 's', ctrlKey: true })), true);
    assert.equal(status.textContent, 'Draft kept locally.');
    assert.equal(f.dispatch(message, key({ key: 's', metaKey: true })), true);
    assert.equal(f.dispatch(message, key({ key: 's' })), false);
    assert.equal(f.dispatch(message, key({ key: 'Enter', shiftKey: true })), false);
    assert.equal(f.dispatch(message, key({ key: 'Enter' })), true);
    assert.equal(status.textContent, 'Add your name before sending.');
  } finally { await f.close(); }
});

test('paste payloads are snapshotted from clipboardData before the Lean action runs', async () => {
  const f = await mounted();
  try {
    const message = f.byTestId('feedback-message');
    const paste = new window.Event('paste', { bubbles: true, cancelable: true });
    const data = { 'text/plain': 'pasted text', 'text/html': '<b>pasted</b> text' };
    Object.defineProperty(paste, 'clipboardData', { value: { getData: type => data[type] ?? '' } });
    f.dispatch(message, paste);
    data['text/plain'] = 'mutated after dispatch';
    assert.equal(f.byTestId('feedback-pasted').textContent, 'Pasted 11 characters.');
    await React.act(() => [...f.container.querySelectorAll('button')].find(button => button.textContent === 'Clear').click());
    assert.equal(f.byTestId('feedback-pasted').textContent, '');
  } finally { await f.close(); }
});
