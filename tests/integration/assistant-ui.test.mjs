import test from 'node:test';
import assert from 'node:assert/strict';
import { JSDOM, VirtualConsole } from 'jsdom';

// assistant-ui's viewport measures and scrolls; jsdom has neither, so the browser-only pieces are stubs.
const virtualConsole = new VirtualConsole().forwardTo(console, { jsdomErrors: 'none' });
const { window } = new JSDOM('<!doctype html><html><body></body></html>', { virtualConsole, url: 'http://localhost' });
Object.assign(globalThis, { window, document: window.document, HTMLElement: window.HTMLElement, IS_REACT_ACT_ENVIRONMENT: true });
window.Element.prototype.scrollTo = function () {};
window.Element.prototype.scrollIntoView = function () {};
globalThis.ResizeObserver = class { observe() {} unobserve() {} disconnect() {} };
globalThis.requestAnimationFrame = callback => setTimeout(() => callback(Date.now()), 0);
globalThis.cancelAnimationFrame = id => clearTimeout(id);
const React = await import('react');
const { createRoot } = await import('react-dom/client');
const { mountElement, ctor, unit, fromBool, runAction } = await import('../../engine/adapters/leanjs-react.mjs');
const { toThreadMessage, toThreadProps, toStatus } = await import('../../adapters/assistant-ui/index.mjs');
const program = await import('../../examples/generated/smoke.mjs');
const Demo = program['Examples.Chat.Demo'];
const demoProps = () => ctor('Examples.Chat.DemoProps.mk', [program['AssistantUI.ThreadOps.silent']]);
const some = value => ctor('Option.some', [value]);
const none = ctor('Option.none');
const bool = value => ctor(value ? 'Bool.true' : 'Bool.false');

async function mounted(element) {
  const warnings = [];
  const originalError = console.error;
  console.error = (...args) => warnings.push(args.map(String).join(' '));
  const container = document.createElement('div');
  document.body.append(container);
  const root = createRoot(container);
  await React.act(() => root.render(element));
  const settle = () => React.act(() => new Promise(resolve => setTimeout(resolve, 0)));
  return {
    container, warnings, settle,
    click: text => React.act(() => [...container.querySelectorAll('button')].find(button => button.textContent === text).click()),
    status: () => container.querySelector('[role="status"]').textContent,
    messages: () => [...container.querySelectorAll('.aui-message')].map(node => [node.dataset.role, node.textContent]),
    type: async text => {
      const input = container.querySelector('.aui-composer-input');
      const setter = Object.getOwnPropertyDescriptor(window.HTMLTextAreaElement.prototype, 'value').set;
      await React.act(() => { setter.call(input, text); input.dispatchEvent(new window.Event('input', { bubbles: true })); });
    },
    close: async () => { try { await React.act(() => root.unmount()); container.remove(); } finally { console.error = originalError; } },
  };
}

test('the Lean transcript fold joins an assistant turn and attaches the tool result to its call', () => {
  const messages = program['AssistantUI.Message.ofTranscript'](program['Examples.Chat.transcript']);
  const like = messages.map(toThreadMessage);
  assert.deepEqual(like.map(message => message.role), ['system', 'user', 'assistant']);
  assert.deepEqual(like.map(message => message.id), ['e1', 'e2', 'e3']);
  assert.equal(like[1].createdAt.getTime(), 1700000000000);
  assert.deepEqual(like[2].content, [
    { type: 'text', text: 'Let me look.' },
    { type: 'tool-call', toolCallId: 'call-1', toolName: 'list_files', argsText: '{"path":"."}', args: { path: '.' },
      result: 'README.md\nlakefile.toml\nengine/', isError: false },
    { type: 'text', text: 'Three entries: README.md, lakefile.toml and engine/.' },
  ]);
  assert.deepEqual(like[2].status, { type: 'complete', reason: 'stop' });
  assert.equal(toThreadMessage(messages[2]), like[2], 'one conversion per Lean message value');
});

test('status and props codecs cover every constructor', () => {
  assert.deepEqual(toStatus(ctor('AssistantUI.MessageStatus.running')), { type: 'running' });
  assert.deepEqual(toStatus(ctor('AssistantUI.MessageStatus.cancelled')), { type: 'incomplete', reason: 'cancelled' });
  assert.deepEqual(toStatus(ctor('AssistantUI.MessageStatus.failed', ['boom'])), { type: 'incomplete', reason: 'error', error: 'boom' });
  assert.deepEqual(toStatus(ctor('AssistantUI.MessageStatus.requiresAction')), { type: 'requires-action', reason: 'tool-calls' });
  const message = ctor('AssistantUI.Message.mk', ['m', ctor('AssistantUI.Role.user'), [ctor('AssistantUI.Part.text', ['hi'])], none,
    ctor('AssistantUI.MessageStatus.complete')]);
  const props = toThreadProps(ctor('AssistantUI.ThreadProps.mk', [[message], bool(false), none, 'Say', 'Nothing', bool(true), none]));
  assert.equal(props.composer, null);
  assert.equal(props.loadEarlier, null);
  assert.equal(props.hasEarlier, true);
  assert.deepEqual(props.messages[0], { id: 'm', role: 'user', content: [{ type: 'text', text: 'hi' }] });
  const pending = toThreadMessage(ctor('AssistantUI.Message.mk', ['a', ctor('AssistantUI.Role.assistant'),
    [ctor('AssistantUI.Part.toolCall', ['c', 'tool', ctor('AssistantUI.ToolArguments.raw', ['not json']), none])], some(5n), ctor('AssistantUI.MessageStatus.running')]));
  assert.deepEqual(pending.content[0], { type: 'tool-call', toolCallId: 'c', toolName: 'tool', argsText: 'not json', args: {} });
  assert.equal(pending.createdAt.getTime(), 5);
});

test('the thread renders Lean messages, sends through the composer, and the running flag gates Stop', async () => {
  const f = await mounted(mountElement(Demo, demoProps()));
  try {
    await f.settle();
    assert.equal(f.status(), 'Thread ready.');
    assert.deepEqual(f.messages().map(([role]) => role), ['system', 'user', 'assistant']);
    const assistant = f.container.querySelector('.aui-message[data-role="assistant"]');
    assert.equal(assistant.dataset.messageId, 'e3');
    assert.equal(assistant.querySelector('.aui-tool-name').textContent, 'list_files');
    assert.equal(assistant.querySelector('.aui-tool-result').textContent, 'README.md\nlakefile.toml\nengine/');
    assert.equal(f.container.querySelector('.aui-composer-cancel'), null);

    await f.type('Thanks!');
    await f.click('Send');
    await f.settle();
    assert.equal(f.status(), 'Sent: Thanks!');
    assert.deepEqual(f.messages().slice(3), [['user', 'Thanks!'], ['assistant', '']]);
    assert.equal(f.container.querySelector('.aui-thread').dataset.running, 'true');
    assert.equal(f.container.querySelector('.aui-composer-send'), null);
    assert.ok(f.container.querySelector('.aui-composer-cancel'));

    await f.click('Stop');
    await f.settle();
    assert.equal(f.status(), 'Cancelled.');
    assert.deepEqual(f.messages().at(-1), ['assistant', 'Stopped.']);
    assert.equal(f.container.querySelector('.aui-thread').dataset.running, 'false');
    assert.deepEqual(f.warnings, []);
  } finally { await f.close(); }
});

test('the typed handle drafts and submits through assistant-ui, and completes the turn from Lean', async () => {
  const f = await mounted(mountElement(Demo, demoProps()));
  try {
    await f.settle();
    await f.click('Draft a reply');
    assert.equal(f.status(), 'Drafted.');
    assert.equal(f.container.querySelector('.aui-composer-input').value, 'Thanks, that is all.');
    await f.click('Submit the draft');
    await f.settle();
    // assistant-ui runs `onNew` inside `composer.send()`, so Lean's `send` ran before the handle's own status line.
    assert.equal(f.status(), 'Submitted.');
    assert.deepEqual(f.messages().slice(3), [['user', 'Thanks, that is all.'], ['assistant', '']]);
    assert.equal(f.container.querySelector('.aui-composer-input').value, '');
    await f.click('Complete the turn');
    await f.settle();
    assert.equal(f.status(), 'Turn complete.');
    assert.deepEqual(f.messages().at(-1), ['assistant', 'Done.']);
    assert.equal(f.container.querySelector('[data-testid="chat-count"]').textContent, '5 messages');
    assert.deepEqual(f.warnings, []);
  } finally { await f.close(); }
});

test('a read-only thread has no composer and a handle built by the adapter reports .unmounted after unmount', async () => {
  const { runtime, foreign } = await import('../../engine/adapters/leanjs-react.mjs');
  const { action, pureAction } = await import('../../engine/runtime/actions.mjs');
  let handle;
  const message = ctor('AssistantUI.Message.mk', ['only', ctor('AssistantUI.Role.user'),
    [ctor('AssistantUI.Part.text', ['read me']), ctor('AssistantUI.Part.image', ['data:image/png;base64,AAAA'])], none,
    ctor('AssistantUI.MessageStatus.complete')]);
  const props = ctor('AssistantUI.ThreadProps.mk', [[message], bool(false), none, 'Say', 'Nothing', bool(false), none]);
  const Direct = runtime.component(() => runtime.mapHook(() => foreign(null, null, 'assistant-ui-thread', ctor('LeanReact.ForeignProps.mk', [
    props, received => action(() => { handle = received; }), pureAction(unit), null,
  ])), runtime.useState(0, 'probe')));
  const container = document.createElement('div'); document.body.append(container);
  const root = createRoot(container);
  try {
    await React.act(() => root.render(runtime.element(Direct, null)));
    assert.equal(container.querySelector('.aui-composer'), null);
    assert.equal(container.querySelector('.aui-message[data-role="user"]').textContent, 'read me');
    assert.equal(container.querySelector('.aui-image').getAttribute('src'), 'data:image/png;base64,AAAA');
    const [ops, alive] = handle.fields;
    assert.equal(fromBool(runAction(alive)), true);
    assert.deepEqual(runAction(ops.fields[2]), ctor('LeanReact.HandleResult.ok', [unit]));
    await React.act(() => root.unmount());
    assert.equal(fromBool(runAction(alive)), false);
    assert.deepEqual(runAction(ops.fields[0]('late')), ctor('LeanReact.HandleResult.unmounted'));
  } finally { container.remove(); }
});
