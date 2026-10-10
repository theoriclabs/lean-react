# assistant-ui for Lean

A typed chat thread for LeanReact, rendered by [assistant-ui](https://github.com/assistant-ui/assistant-ui). Lean owns the conversation: which messages exist, whether a turn is running, and what the person at the keyboard may do. assistant-ui owns the pixels: the viewport, auto-scroll, the composer, the message parts. The two meet through LeanReact's foreign-component protocol, so no compiler change was needed and no React code is written per application.

The package is three files that ship with the `leanreact` checkout:

| File | Side | Content |
| --- | --- | --- |
| `AssistantUI/Thread.lean`, `AssistantUI/Transcript.lean` | Lean (`lean_lib AssistantUI`) | The vocabulary, the `thread` element, the native reference, the transcript fold |
| `index.mjs` | Browser | Registers `"assistant-ui-thread"` with the LeanReact React adapter and renders the assistant-ui primitives over an external-store runtime |
| `thread.css` | Browser | A small default look, all CSS variables |

## Attribution

The chat primitives, the external-store runtime and the composer behaviour come from [assistant-ui](https://github.com/assistant-ui/assistant-ui) by AgentbaseAI Inc. assistant-ui is MIT licensed. This package uses it unmodified, as the npm dependency `@assistant-ui/react` 0.15.26. The upstream license text is copied in [LICENSES/assistant-ui.LICENSE](LICENSES/assistant-ui.LICENSE). This package only adapts assistant-ui to Lean.

## The Lean side

```lean
import AssistantUI
open LeanReact AssistantUI
```

- `Role` is `user`, `assistant` or `system`. `Part` is `text`, `reasoning`, `image url` (a URL the browser can load, a `data:` URL for a pasted picture) or `toolCall callId name arguments result`. `arguments : ToolArguments` is `raw text` or `fields` (named, in display order; the first field summarizes the call in the collapsed header), and `result : Option ToolResult` carries the answer and its `isError` flag once known.
- `Message` is an `id`, a `role`, its `parts`, an optional `createdAtMs` and a `MessageStatus` (`complete`, `running`, `cancelled`, `failed error`, `requiresAction`). `Message.text role id value` builds a plain one; `Message.plainText` reads the text parts back.
- `Composer` is what the person may do: `send : String → Action Unit`, and `cancel : Option (Action Unit)` for the Stop button. A thread with `composer := none` is a read-only transcript.
- `ThreadProps` is `messages`, `running`, `composer`, `placeholder`, `emptyText`, and `hasEarlier` with `loadEarlier` for paged history.
- `thread props : Element` renders it. `threadWithHandle props onReady onGone stubs` additionally hands Lean a `Handle ThreadOps` once per mount: `setDraft`, `submit` and `focus`, each an `Action (HandleResult Unit)` that answers `.unmounted` once the thread is gone.
- `Entry` is one row of a flat transcript (`id`, `role`, `Content`, `atMs`), and `Message.ofTranscript : Array Entry → Array Message` folds a transcript into messages: an assistant turn is one message whose text, reasoning and tool-call rows join, a `toolResult` row attaches to the pending call with its id, user and system rows are one message each, and an orphan result becomes an assistant message named `unknown` rather than vanishing.

The fold is pure Lean. It runs natively in tests and is compiled by LeanJS for the browser, so a transcript is grouped the same way everywhere, and an application adapts its own transcript type to `Entry` once.

Natively (`LeanReact.Reference`) a thread renders one `article` per message with `data-role` and `data-message-id`, `details` per tool call, and a composer form whose draft lives in state, so a component over a thread is testable in Lean without a browser. `tests/runtime/AssistantUI.lean` does exactly that.

## The browser side

Import the adapter before anything renders a thread. In this workspace the npm workspace name resolves:

```js
import 'assistant-ui-lean';            // registers "assistant-ui-thread"
```

and the page links the stylesheet:

```html
<link rel="stylesheet" href="./thread.css" />
```

Props cross as Lean values and are converted once per message value (a `WeakMap` keyed on the Lean object), so assistant-ui sees stable message identities across renders. `onNew` runs `composer.send` with the composer text, `onCancel` runs `composer.cancel`, `onLoadEarlier` runs `loadEarlier`; `isRunning` and `isDisabled` follow `running` and the presence of a composer. The imperative handle maps `setDraft` and `submit` onto assistant-ui's composer runtime and `focus` onto the input.

`npm ci` at the repository root installs `@assistant-ui/react` through the `adapters/assistant-ui` workspace, so a Lake target that bundles with `NODE_PATH` set to the checkout's `node_modules` (the pattern in `engine/browser/App.mjs` consumers) resolves it without further setup.

### In a full-stack `app%` application

An application served by `app% Name where app := X` stages LeanReact's browser entry and runtime next to its generated `domain.mjs` and bundles them with esbuild. Add two steps to that staging target:

1. Copy `adapters/assistant-ui/index.mjs` into the staged `runtime/` directory, rewriting its import of `../../engine/adapters/leanjs-react.mjs` to `./leanjs-react.mjs`, the same rewrite the target already applies to `Fetch.mjs`. One copy of `leanjs-react.mjs` in the bundle is essential: `registerForeign` and `foreign` must share a module instance.
2. Bundle an entry that imports the adapter before the app entry, so registration precedes the mount:

```js
import './runtime/index.mjs';
import './entry.mjs';
```

Then any page may render `thread` or `threadWithHandle`. A transcript endpoint feeds `load`; a live run feeds `useStream` into the message state, which is what `running` and the last message's `status` describe.

## Styling

`thread.css` styles the `aui-` class names through variables with fallbacks: `--aui-gap`, `--aui-radius`, `--aui-ink`, `--aui-muted`, `--aui-line`, `--aui-paper`, `--aui-user`, `--aui-accent`, `--aui-error`, `--aui-mono`. Set them on an ancestor to retheme; replace the file to restyle. Nothing depends on Tailwind or shadcn.

## Tests

- `lean --run tests/runtime/AssistantUI.lean` (part of `tests/runtime/check-lean.sh`): the fold, the reference render, the native composer, the handle over stubs.
- `node --test tests/integration/assistant-ui.test.mjs` (part of `npm test`, after `Smoke.lean` emits `examples/generated/smoke.mjs`): the compiled `Examples.Chat.Demo` mounted under jsdom with assistant-ui, sending, Stop while running, the handle, and a read-only thread. jsdom lacks `ResizeObserver`, `requestAnimationFrame` and element scrolling, which the test stubs.

The playground example is [Chat.lean](../../examples/lean/Examples/Chat.lean) (`npm run dev`, then `/?example=chat#playground`).

## Not covered yet

Editing or regenerating a message, branches, attachments, suggestions and a thread list are assistant-ui features without a Lean counterpart here; each is a field on `Composer` or `ThreadProps` plus an adapter callback (`onEdit`, `onReload`, `adapters.attachments`) when needed. Text renders as plain pre-wrapped paragraphs; Markdown is `@assistant-ui/react-markdown`, a separate package, and would replace the `Text` part component in `index.mjs`.
