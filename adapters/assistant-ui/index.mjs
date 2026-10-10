// assistant-ui for Lean: the host side of `AssistantUI.thread` and `AssistantUI.threadWithHandle`.
// Importing this module registers the foreign component "assistant-ui-thread" with the LeanReact
// React adapter; the React side renders assistant-ui's primitives over an external-store runtime
// fed by the Lean props. Lean owns the messages, the running flag and what the composer may do;
// this file only converts shapes and forwards actions.
import * as React from 'react';
import {
  AssistantRuntimeProvider, useExternalStoreRuntime, useAuiState,
  ThreadPrimitive, MessagePrimitive, ComposerPrimitive,
} from '@assistant-ui/react';
import { registerForeign, ctor, fromBool, runAction } from '../../engine/adapters/leanjs-react.mjs';

/** `AssistantUI.foreignName` in Lean. */
export const foreignName = 'assistant-ui-thread';

const option = value => value?.tag === 'Option.some' ? value.fields[0] : null;
const identity = value => value;

/** `AssistantUI.MessageStatus` → assistant-ui `MessageStatus`. */
export function toStatus(status) {
  switch (status.tag) {
    case 'AssistantUI.MessageStatus.complete': return { type: 'complete', reason: 'stop' };
    case 'AssistantUI.MessageStatus.running': return { type: 'running' };
    case 'AssistantUI.MessageStatus.cancelled': return { type: 'incomplete', reason: 'cancelled' };
    case 'AssistantUI.MessageStatus.failed': return { type: 'incomplete', reason: 'error', error: status.fields[0] };
    case 'AssistantUI.MessageStatus.requiresAction': return { type: 'requires-action', reason: 'tool-calls' };
    default: throw new TypeError(`Unknown AssistantUI.MessageStatus ${status?.tag}`);
  }
}

// assistant-ui wants `args` as a JSON object; the text stays available as `argsText` either way.
function parseArguments(text) {
  try {
    const value = JSON.parse(text);
    return value !== null && typeof value === 'object' && !Array.isArray(value) ? value : {};
  } catch { return {}; }
}

/** `AssistantUI.ToolArguments` → assistant-ui's `args` object and `argsText`. Named fields keep
 * their order (the first one summarizes the call); raw text is parsed when it happens to be JSON. */
export function toArguments(value) {
  if (value.tag === 'AssistantUI.ToolArguments.raw') return { argsText: value.fields[0], args: parseArguments(value.fields[0]) };
  const args = {};
  for (const pair of value.fields[0]) args[pair.fields[0]] = pair.fields[1];
  return { args, argsText: JSON.stringify(args) };
}

/** `AssistantUI.Part` → an assistant-ui message part. */
export function toPart(part) {
  switch (part.tag) {
    case 'AssistantUI.Part.text': return { type: 'text', text: part.fields[0] };
    case 'AssistantUI.Part.reasoning': return { type: 'reasoning', text: part.fields[0] };
    case 'AssistantUI.Part.image': return { type: 'image', image: part.fields[0] };
    case 'AssistantUI.Part.toolCall': {
      const [toolCallId, toolName, arguments_, result] = part.fields;
      const answered = option(result);
      return {
        type: 'tool-call', toolCallId, toolName, ...toArguments(arguments_),
        ...(answered ? { result: answered.fields[0], isError: fromBool(answered.fields[1]) } : {}),
      };
    }
    default: throw new TypeError(`Unknown AssistantUI.Part ${part?.tag}`);
  }
}

// Lean values are immutable, so one conversion per message value keeps assistant-ui's message
// identities stable across renders.
const converted = new WeakMap();
/** `AssistantUI.Message` → assistant-ui `ThreadMessageLike`. */
export function toThreadMessage(message) {
  let like = converted.get(message);
  if (!like) {
    const [id, role, parts, createdAtMs, status] = message.fields;
    const at = option(createdAtMs);
    const roleName = role.tag.slice('AssistantUI.Role.'.length);
    like = {
      id, role: roleName, content: parts.map(toPart),
      ...(at == null ? {} : { createdAt: new Date(Number(at)) }),
      ...(roleName === 'assistant' ? { status: toStatus(status) } : {}),
    };
    converted.set(message, like);
  }
  return like;
}

/** `AssistantUI.ThreadProps` → the React props of the thread. */
export function toThreadProps(value) {
  const [messages, running, composer, placeholder, emptyText, hasEarlier, loadEarlier] = value.fields;
  const composerRecord = option(composer);
  return {
    messages: messages.map(toThreadMessage),
    running: fromBool(running),
    composer: composerRecord ? { send: composerRecord.fields[0], cancel: option(composerRecord.fields[1]) } : null,
    placeholder, emptyText,
    hasEarlier: fromBool(hasEarlier),
    loadEarlier: option(loadEarlier),
  };
}

const textOf = message => message.content.filter(part => part.type === 'text').map(part => part.text).join('\n');

// Unstyled primitives with `aui-` class names, the same ones the native reference emits; thread.css
// styles them through CSS variables an application can override.
const Text = ({ text }) => React.createElement('p', { className: 'aui-text' }, text);
const Reasoning = ({ text }) => React.createElement('p', { className: 'aui-reasoning' }, text);
const Image = ({ image }) => React.createElement('img', { className: 'aui-image', src: image, alt: 'image' });
// The first line that says something: not blank and not a `//` or `#` comment, as tool inputs often open with one.
const firstLine = (text, width = 100) => {
  const line = String(text ?? '').split('\n').map(part => part.trimStart())
    .find(part => part && !part.startsWith('//') && !part.startsWith('#')) ?? '';
  return line.length <= width ? line : `${line.slice(0, width)}…`;
};
const ToolCall = ({ toolCallId, toolName, args, argsText, result, isError }) => {
  const entries = args && typeof args === 'object' ? Object.entries(args) : [];
  const summary = firstLine(entries.length ? entries[0][1] : argsText);
  return React.createElement('details', { className: 'aui-tool-call', 'data-call-id': toolCallId },
    React.createElement('summary', { className: 'aui-tool-head' },
      React.createElement('span', { className: 'aui-tool-name' }, toolName),
      React.createElement('span', { className: 'aui-tool-summary' }, summary)),
    entries.length
      ? React.createElement('div', { className: 'aui-tool-arguments' }, ...entries.map(([key, value]) =>
        React.createElement('div', { className: 'aui-tool-field', key },
          React.createElement('span', { className: 'aui-tool-key' }, key),
          React.createElement('pre', { className: 'aui-tool-value' }, typeof value === 'string' ? value : JSON.stringify(value)))))
      : React.createElement('pre', { className: 'aui-tool-arguments' }, argsText),
    result === undefined
      ? React.createElement('p', { className: 'aui-tool-pending' }, 'No result yet.')
      : React.createElement('pre', { className: isError ? 'aui-tool-result aui-tool-error' : 'aui-tool-result' },
        typeof result === 'string' ? result : JSON.stringify(result)));
};
const partComponents = { Text, Reasoning, Image, tools: { Fallback: ToolCall } };
function messageComponent(role) {
  function Message() {
    const id = useAuiState(state => state.message.id);
    return React.createElement(MessagePrimitive.Root, { className: 'aui-message', 'data-role': role, 'data-message-id': id },
      React.createElement(MessagePrimitive.Parts, { components: partComponents }));
  }
  Message.displayName = `AssistantUI.${role}`;
  return Message;
}
const messageComponents = {
  UserMessage: messageComponent('user'),
  AssistantMessage: messageComponent('assistant'),
  SystemMessage: messageComponent('system'),
};

/** The React component behind the foreign element. In React 19 `ref` is a prop; the LeanReact
 * runtime supplies it and reads the imperative handle through it. */
export function LeanThread({ messages, running, composer, placeholder, emptyText, hasEarlier, loadEarlier, ref }) {
  const input = React.useRef(null);
  const runtime = useExternalStoreRuntime({
    messages, convertMessage: identity,
    isRunning: running,
    isDisabled: composer === null,
    onNew: async message => {
      if (!composer) throw new Error('AssistantUI: this thread has no composer');
      await runAction(composer.send(textOf(message)));
    },
    ...(composer?.cancel ? { onCancel: async () => { await runAction(composer.cancel); } } : {}),
    ...(loadEarlier ? { hasEarlier, onLoadEarlier: async () => { await runAction(loadEarlier); } } : {}),
  });
  React.useImperativeHandle(ref, () => ({
    setDraft(text) { runtime.thread.composer.setText(text); },
    submit() { runtime.thread.composer.send(); },
    focus() { input.current?.focus(); },
  }), [runtime]);
  return React.createElement(AssistantRuntimeProvider, { runtime },
    React.createElement(ThreadPrimitive.Root, { className: 'aui-thread', 'data-running': String(running) },
      React.createElement(ThreadPrimitive.Viewport, { className: 'aui-thread-viewport' },
        loadEarlier && hasEarlier
          ? React.createElement(ThreadPrimitive.LoadEarlier, { className: 'aui-load-earlier' }, 'Load earlier') : null,
        React.createElement(ThreadPrimitive.Empty, null, React.createElement('p', { className: 'aui-empty' }, emptyText)),
        React.createElement(ThreadPrimitive.Messages, { components: messageComponents })),
      composer
        ? React.createElement(ComposerPrimitive.Root, { className: 'aui-composer' },
          React.createElement(ComposerPrimitive.Input, { ref: input, className: 'aui-composer-input', placeholder, 'aria-label': placeholder }),
          React.createElement(ThreadPrimitive.If, { running: false },
            React.createElement(ComposerPrimitive.Send, { className: 'aui-composer-send' }, 'Send')),
          composer.cancel
            ? React.createElement(ThreadPrimitive.If, { running: true },
              React.createElement(ComposerPrimitive.Cancel, { className: 'aui-composer-cancel' }, 'Stop')) : null)
        : null));
}

registerForeign(foreignName, {
  component: LeanThread,
  props: toThreadProps,
  // Lean: setDraft : String → Action (HandleResult Unit); submit, focus : Action (HandleResult Unit)
  ops: invoke => ctor('AssistantUI.ThreadOps.mk', [text => invoke('setDraft', [text]), invoke('submit'), invoke('focus')]),
});
