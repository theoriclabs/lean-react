# Build frontends with LeanReact

[Documentation](README.md) · [LeanReact overview](LEANREACT.md) · [Full-stack getting started](GETTING_STARTED.md)

LeanReact is the frontend library within LeanApp. This tutorial needs no native server or database; use the full-stack guide when you want the authenticated café and SQLite persistence.

This guide takes you from the working showcase to a small form written in Lean, then shows how to compose editors, share domain definitions, and connect compiled libraries. It describes the implementation in this repository. LeanReact is experimental; nested routing, React Server Components, and automatic JS/TS bindings are still ahead.

All commands run from the repository root unless stated otherwise. You need the toolchain in `lean-toolchain` (currently Lean 4.33.0), Node 22.13 or newer, and npm. Install Lean through [elan](https://github.com/leanprover/elan). React and the JavaScript build tools are already declared in `package.json`.

- [Run the showcase](#run-the-showcase)
- [Build your first form](#build-your-first-form)
- [Compose components and editors](#compose-components-and-editors)
- [Share a context between libraries](#share-a-context-between-libraries)
- [Use services and asynchronous work](#use-services-and-asynchronous-work)
- [Style components and use JavaScript libraries](#style-components-and-use-javascript-libraries)
- [Check and debug your work](#check-and-debug-your-work)
- [Work with a coding agent](#work-with-a-coding-agent)

## Run the showcase

```sh
git clone https://github.com/theoriclabs/lean-react.git
cd lean-react
npm ci
npm run dev
```

Open `http://localhost:4173`. Try the live counter, then the workspace, collection forms, and shared contexts in the playground. `npm run dev` builds the examples and watches their sources. After a rebuild, refresh the page; there is no hot module replacement.

The default examples use browser memory. The optional LeanDB/LeanHttp service is unnecessary for this tutorial. Its setup is in the [native guide](NATIVE.md).

The application has three relevant boundaries:

| Value or module | Responsibility |
| --- | --- |
| `Component Props` | A reusable component definition. Mount it with `element component props`. |
| `Hook α` | Work performed during a component render, such as reading state or context. |
| `Action α` | Deferred event/effect work. Return actions from handlers; do not execute them during render. |
| `LeanOntology` / `LeanContract` | Domain identities, paths, validation, codecs, operations, and interpreters. |
| `LeanJS` / `LeanReact.Compiler` | Compile portable Lean definitions and register the React host bindings. |

Engine code lives in `engine/`. Application examples live in `examples/`. Application types do not belong in the engine merely because several application screens share them.

## Build your first form

This tutorial adds a separate page without replacing the showcase. Stop its development server first if it is using port 4173. The five files below are complete files to create; they are not preinstalled application modules.

### Define the shared domain

Create `examples/lean/Examples/Tutorial/Domain.lean`:

<!-- tutorial-file: examples/lean/Examples/Tutorial/Domain.lean -->
```lean
import LeanOntology

namespace Examples.Tutorial

structure NoteTitle where
  private mk ::
  value : String
  deriving Repr, BEq

def NoteTitle.parse (raw : String) : Ontology.Validation NoteTitle :=
  if raw.isEmpty then
    Ontology.Validation.fail "note.title.required"
  else if raw.length > 80 then
    Ontology.Validation.fail "note.title.too_long"
  else
    .ok ⟨raw⟩

end Examples.Tutorial
```

This module has no React or HTTP dependency. A native Lean backend can import the same `NoteTitle.parse`. The private constructor directs callers through the parser without requiring proof terms in application code. A fuller ontology can add semantic field paths, nominal entity IDs, descriptors, and explicit codecs as it needs them; a record does not require all that machinery on day one.

### Compose a field and a form

Create `examples/lean/Examples/Tutorial/Components.lean`:

<!-- tutorial-file: examples/lean/Examples/Tutorial/Components.lean -->
```lean
import LeanReact
import Examples.Tutorial.Domain

namespace Examples.Tutorial
open LeanReact

def titleParser : DraftParser String NoteTitle :=
  ⟨NoteTitle.parse, NoteTitle.value⟩

def TitleField : Editor String := component fun binding =>
  pure <| DOM.input {
    id := some "note-title"
    value := some binding.value
    onChange := some (fun event => binding.set event.value)
  }

def App : Component Unit := component fun _ => do
  let form ← useForm titleParser "" "note-draft"
  let notice ← useState "Draft not saved" "notice"
  let save : Action Unit := do
    let result ← form.submit fun title =>
      notice.set ("Saved: " ++ title.value)
    match result with
    | .ok _ => pure ()
    | .error errors => notice.set (
        if errors.first.code == "note.title.required" then
          "Give the note a title."
        else "Use at most 80 characters.")
  pure <| DOM.div { className := some "panel" } #[
    DOM.h1 {} #[text "Draft a note"],
    DOM.label { htmlFor := "note-title" } #[text "Note title"],
    element TitleField form.binding,
    DOM.div { className := some "controls" } #[
      DOM.button { className := some "primary", onPress := some save }
        #[text "Save note"]
    ],
    DOM.p { role := some "status" } #[text notice.value]
  ]

end Examples.Tutorial
```

`TitleField` only knows about a `FieldBinding String`; it does not own the form or decide how saving works. `useForm` owns the raw draft. `Form.submit` parses the latest committed draft and only calls its callback for a valid `NoteTitle`. Invalid text remains editable.

Here, “save” changes the local notice. To persist a note, make the valid callback call an injected service, as described [below](#use-services-and-asynchronous-work).

### Compile the Lean definitions

Create `examples/lean/Examples/Tutorial/Generate.lean`:

<!-- tutorial-file: examples/lean/Examples/Tutorial/Generate.lean -->
```lean
import LeanReact.Compiler
import Examples.Tutorial.Components

run_meta do
  IO.FS.createDirAll "examples/generated"
  LeanJS.writeModule "examples/generated/tutorial.mjs"
    #[`Examples.Tutorial.App, `Examples.Tutorial.NoteTitle.parse]
    (LeanReact.Compiler.options "../../engine/adapters/leanjs-react.mjs")
```

The adapter path is relative to the generated `tutorial.mjs`, not to this Lean file. Use `LeanReact.Compiler.options` for the standard React bindings rather than copying the intrinsic registry into the application.

`writeModule` produces ESM, `.d.ts`, `.d.mts`, and a JSON manifest. The declarations describe the encoded Lean ABI. They are not ordinary React props-object types. Generated files belong in `examples/generated/` and are ignored by Git; edit the Lean source and regenerate them.

### Mount the component

Create `examples/web/tutorial.mjs`:

<!-- tutorial-file: examples/web/tutorial.mjs -->
```javascript
import { createRoot } from 'react-dom/client';
import * as tutorial from '../generated/tutorial.mjs';
import { mountElement } from '../../engine/adapters/leanjs-react.mjs';

const root = createRoot(document.getElementById('tutorial-root'));
root.render(mountElement(tutorial['Examples.Tutorial.App']));
```

`mountElement` supplies Lean's `Unit` value when no props are given. For components with structured props, export their Lean constructor and use it to construct the encoded value. The [TypeScript consumer](../examples/consumer/typescript.tsx) demonstrates that pattern.

Create `examples/web/tutorial.html`:

<!-- tutorial-file: examples/web/tutorial.html -->
```html
<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <title>LeanReact tutorial</title>
    <link rel="stylesheet" href="./style.css" />
  </head>
  <body>
    <main class="page">
      <div id="tutorial-root" class="example-surface"></div>
    </main>
    <script type="module" src="./tutorial.js"></script>
  </body>
</html>
```

### Build and try it

```sh
npm run build
lake build Examples.Tutorial.Components
lake env lean -R examples/lean examples/lean/Examples/Tutorial/Generate.lean
npx esbuild examples/web/tutorial.mjs --bundle --format=esm --platform=browser --target=es2022 --outfile=examples/dist/tutorial.js
cp examples/web/tutorial.html examples/dist/tutorial.html
node scripts/dev.mjs --no-build
```

Open `http://localhost:4173/tutorial.html`. Save the empty field: it should show “Give the note a title.” Enter a title and save again: it should show “Saved: …”. Try a title longer than 80 Unicode scalar values; the text should remain in the input and the form should reject it.

The default build only knows about its registered example generators and entry points. After editing this tutorial, rerun the Lean build/generator and esbuild commands above, then refresh. For an ongoing application, add its generator and browser entry to `scripts/build.mjs` or give it a dedicated build script. If you want `lake build Examples` to include it, add `import Examples.Tutorial.Components` to `examples/lean/Examples.lean`. Add generated integration tests when incorporating it into the main test workflow.

You can also call the same domain parser from JavaScript after generating the module:

```sh
node --input-type=module -e 'import * as app from "./examples/generated/tutorial.mjs"; console.log(app["Examples.Tutorial.NoteTitle.parse"]("Shared rule"));'
```

The result is a tagged Lean `Except` value. Use explicit codecs for a public wire format; do not send the private runtime representation as an application protocol.

## Compose components and editors

### Pass values instead of adding special cases

A component can take callbacks, child elements, and other components in its props. The existing [Tickets components](../examples/lean/Examples/Tickets/Components.lean) show these combinations:

| Requirement | Composition |
| --- | --- |
| Change a card footer | Pass `TicketSummary → Element` as `CardProps.footer`. |
| Change a text input to a textarea | Pass another `Editor String` as `EditorProps.titleEditor`. |
| Show one editor in two layouts | Call `useTicketEditor` from both `Editor` and `PageEditor`. |
| Render another entity type | Specialize `ListView α` and supply its key and row functions. |

Hoist component definitions and specializations: `TicketList := ListView TicketSummary` is a top-level value. Construct child elements with `element TicketList props` during render. Creating a fresh component definition on every render gives it a fresh React identity and can reset its state.

Named custom hooks can return ordinary records containing values and actions. Keep their primitive hook sequence fixed. Put conditional or repeated state in child components and conditionally render those elements; do not call `useState` inside a data-dependent loop or just one branch.

### Focus a nested field

A `FieldBinding` exposes a render snapshot plus `set` and functional `modify`. Use `binding.focus lens` to edit one field while preserving its siblings. A lens is a typed path paired with an explicit setter; lens-law proofs are optional.

The following definition can be added in the tutorial's `Examples.Tutorial` namespace, where `LeanReact` is open:

<!-- recipe: focused-field -->
```lean
structure DraftFields where
  title : String
  description : String

def draftFieldsType : Ontology.TypeId := ⟨"tutorial", "DraftFields"⟩

def titleLens : Ontology.Lens DraftFields String :=
  Ontology.Lens.field draftFieldsType "title" DraftFields.title
    (fun previous value => { previous with title := value })

def FocusedTitle : Editor DraftFields :=
  Editor.map TitleField (fun binding => binding.focus titleLens)
```

`binding.map` converts a whole field representation; `binding.focus` updates part of a larger value. Replacing an entire record from an old render snapshot can overwrite a sibling edit. Focused bindings use the owner's latest state when applying the setter.

### Compose collection forms

Use `DraftParser.product` for independent fields, `DraftParser.optional` for optional values, and `DraftParser.list` for arrays. Product and list parsing accumulate errors. An array error path starts with the current `.index`, followed by the row field's path.

`Editor.list keyOf row layout` supplies a keyed row binding and remove action to your row renderer, then supplies the rendered children and an add action to your layout. Both renderers are ordinary functions. The [collection example](../examples/lean/Examples/Collections.lean) is a complete implementation, including an ID allocator, stateful row components, focused fields, and submission.

Use stable unique IDs as keys. Editable titles and array positions are poor identities for rows that can change or move. `FieldBinding.item` follows a key after reorder, and a retained binding becomes a no-op after that row is removed. Keep the key itself stable when changing row fields.

To implement reorder, transform the owner's array through `binding.modify`; do not recreate the editor component. The example reverses the array with a pure fold. Its browser test verifies both row state and DOM identity after reorder.

## Share a context between libraries

Put the context and its value type in a shared Lean module. The existing `Formatter` example carries both a heading and a formatting function. Its provider and consumer are in separate source modules and are emitted into separate JavaScript libraries.

A top-level context initializes automatically before render, including when stored inside a top-level record. You do not need to export it solely for initialization or put it before components in an export list. Creating a fresh context inside a render function still violates its lifetime requirements.

Lean imports make declarations available to the compiler. `Options.libraries` determines which declarations become shared JavaScript imports. These are separate responsibilities. The working generator follows this sequence:

1. Emit `shared.mjs` with `Options.library := some ⟨packageName, version, moduleName⟩`, exporting the shared contexts.
2. Read `shared.manifest.json` with `LeanJS.readLibrary manifestPath "./shared.mjs"`.
3. Pass that import in `Options.libraries` when compiling both the provider and consumer.
4. Compile the application with imports for those two libraries.

See the complete [library generator](../examples/lean/Examples/GenerateComposability.lean) and [linking contract](COMPOSABILITY.md#linking-libraries). One declaration has one configured owner, and all consumers must resolve its shared dependency to the same ESM instance. Independently compiled standalone bundles do not automatically deduplicate contexts. Matching context display names do not establish JavaScript identity.

The native `Context` reference implementation uses `TypeName`. For a value type declared with `deriving TypeName`, the current browser build still needs an erased intrinsic for that instance. This is the actual registration used by the example:

<!-- recipe: context-options -->
```lean
import Examples.ReactCompiler
import Examples.Libraries.App

private def contextOptions : LeanJS.Options := { Examples.reactOptions with
  intrinsics := Examples.reactIntrinsics.push {
    leanName := `Examples.Libraries.instTypeNameFormatter
    module := Examples.reactModule
    exportName := "erased"
    arity := 0
  }
}
```

This erases the native dictionary at the host boundary. The context value itself is still created and shared normally. A new value type needs its own actual instance name; inspect it in Lean rather than guessing a generated name.

## Use services and asynchronous work

Keep a service interface as an ordinary Lean record. For example, `TicketService m` contains typed `list` and `save` functions. Application props supply a `TicketService Action`, so a component can use either a browser-memory implementation or an HTTP-backed one.

The [Tickets domain](../examples/lean/Examples/Tickets/Domain.lean) contains the service type and shared save rule. The [components](../examples/lean/Examples/Tickets/Components.lean) provide the local implementation and the consuming `Workspace`. Public operation definitions and codecs live in [Contracts.lean](../examples/lean/Examples/Tickets/Contracts.lean); the host transport lives in the [example adapter](../examples/adapters/tickets-service.mjs).

| Need | API and behavior |
| --- | --- |
| State that changes the rendered UI | `useState`; use `state.modify` for updates based on the previous value. |
| Latest committed state in an action | `state.read`; it does not flush queued React updates. |
| Immediate local state without a rerender | `useCell`; `modifyGet` returns `(result, nextValue)` from one pure transition. |
| Load data after mounting | `useResource key loader dependencies enabled site`; its loader returns an `Action (Except Error Value)`. |
| Refresh a resource | Execute `resource.refresh` in an event action. |
| Register effect cleanup | `useEffect` setup returns an `Action Unit` cleanup. Cleanup itself remains deferred. |

Use literal, stable hook site labels. Dependencies are typed `Dependency` values; keep the dependency array's shape fixed. Resource generations suppress obsolete responses after refresh, key changes, or unmount. A host loader must explicitly forward the request's abort signal to its I/O if it should also cancel that work: build it with `resourceLoader(client, identity, encodeArgs)` from `engine/LeanContract/Service.mjs`, which passes the resource's `AbortSignal` to `createHttpClient.call`, so leaving the screen or refreshing aborts the `fetch`. The Tickets browser adapter does this for its list query (`createTicketsLoader` behind `WorkspaceProps.load`).

Keep domain failures as typed `Except` values. Transport failures arrive as `ResourceFailure.call` carrying the portable `Contract.CallFailure` (`unauthenticated`, `forbidden`, `incompatible`, `decode`, `protocol`, `transport`, `cancelled`); `Resource.failureAs` collapses a failure into `Except CallFailure ε`, so a component matches on a closed type instead of strings (see `loadFailureMessage` in the Tickets components). Register `configureRuntime({ onCallFailure })` once to react to `unauthenticated` globally, for example by redirecting to a login route. `Action.catchError` is for host exceptions; its current bridge supplies `IO.Error.userError`. Raw file, socket, and browser operations do not become portable merely because a function returns `Action`: give native operations explicit host adapters.

### Route between screens

Define a route type and a `RouteCodec`, mount one `routerProvider`, and read the route where a screen needs it:

<!-- recipe: typed-routes -->
```lean
import LeanReact
open LeanReact

inductive Screen where
  | home | ticket (id : Nat) | notFound

def screens : RouteCodec Screen := {
  parse := fun location =>
    match (Route.segments (Route.split location).1).toList with
    | [] => some .home
    | ["tickets", id] => (Route.nat? id).map Screen.ticket
    | _ => none
  print := fun | .home => "/" | .ticket id => s!"/tickets/{id}" | .notFound => "/not-found" }

def Detail : Component Nat := component fun id => do
  let router ← useRoute screens .notFound "route"
  pure <| DOM.section {} #[
    DOM.h2 {} #[text s!"Ticket {id}"],
    router.link .home {} #[text "All tickets"],
    DOM.button { onPress := some router.back } #[text "Back"]]
```

`router.current` is the decoded route, `router.location` the raw `pathname + search`. `navigate` pushes, `replace` rewrites, `back` pops; `router.link` renders an anchor whose plain clicks navigate in place while modified clicks and external URLs keep the browser default. Deep links and reloads need the server to serve the page for every application path; `scripts/dev.mjs` does this for `/router/*`. The reference renderer has an in-memory `History`, so screens can be tested natively (`tests/runtime/Router.lean`). The complete example is [Routing.lean](../examples/lean/Examples/Routing.lean), served at `/router/`.

## Style components and use JavaScript libraries

### CSS

Use an ordinary stylesheet and `className`:

<!-- recipe: styled-element -->
```lean
import LeanReact
open LeanReact

def successMessage (message : String) : Element :=
  DOM.p { className := some "notice notice-success" } #[text message]
```

```css
.notice { padding: 0.75rem 1rem; border-radius: 0.5rem; }
.notice-success { color: #24583e; background: #edf1e4; }
```

Put application styles in its web directory; the showcase uses `examples/web/style.css`. Class strings can be produced by ordinary Lean functions. There is no typed Lean CSS DSL, style-object conversion, CSS extraction, or configured Tailwind pipeline yet.

### Existing React components, including shadcn

Wrap a foreign component with a typed Lean function and a named intrinsic. The maintained small example consists of:

- [Foreign.lean](../examples/lean/Examples/Foreign.lean): typed props, a native reference function, a live callback, and a child element.
- [example-foreign.mjs](../examples/adapters/example-foreign.mjs): imports or defines an ordinary React component, decodes its Lean props, and returns `runtime.foreignElement(...)`.
- [Smoke.lean](../examples/lean/Examples/Smoke.lean): registers the Lean function name, module specifier, JavaScript export name, and retained arity.

Use `runtime.onPress(action)` to adapt a deferred action to an event handler. Do not execute the action while creating the element. The foreign component's own React hooks stay inside its React component boundary.

#### Imperative components: typed handles

Props and callbacks are enough when the component is a function of its inputs. Editors, maps, charts, players, and virtualized lists are **imperative**: the host object must be told to `focus`, `flyTo`, `scrollToIndex`, or `draw`. For those, use `foreign` with a `Handle`:

- Declare the operations as a Lean record of Actions whose results are `HandleResult α` (`.ok value` or `.unmounted`), and pass `ForeignProps { props, onReady, onGone, reference }` to `foreign "name"`. `onReady` runs once per mount with a `Handle`; `onGone` runs on unmount and before a keyed remount's `onReady`.
- Register the host side once with `registerForeign("name", { component, props, ops })` from `engine/adapters/leanjs-react.mjs`. `component` is an ordinary React component exposing its API through `useImperativeHandle`; `ops(invoke)` builds the Lean record from `invoke(method, args, encode)` Actions.
- Every operation checks the mount flag before touching the ref and resolves to `.unmounted` afterwards, so a retained handle never reaches a dead node and React logs no warning. Match on the result instead of guessing whether the component is still there.
- Keep the handle in a `useCell`, not `useState`: it is a capability, not render data, and storing it in state would rerender on every `onReady`. Handle operations are Actions, so calling one during render is a type error.
- The native reference renders `reference.render` and backs the handle with `reference.ops` stubs, so component logic that depends on a handle can be unit-tested in Lean.

The maintained example is a `<canvas>` sparkline with `draw(points)` and `clear`: [Sparkline.lean](../examples/lean/Examples/Sparkline.lean), [example-sparkline.mjs](../examples/adapters/example-sparkline.mjs), tested in `tests/integration/handles.test.mjs`, `tests/runtime/Reference.lean`, and `tests/browser/handles.spec.mjs`.

A shadcn component would use the same binding pattern, plus its actual CSS/theme setup. shadcn is not installed or qualified here. A simple Button needs a much smaller contract than a Dialog with refs, portals, focus management, or `asChild`. Implement and test those capabilities explicitly for the component you choose. The Lean DOM API supplies typed click/change/input/paste/focus/blur/key/mouse/scroll/submit snapshots and typed handles for foreign components; it does not provide refs on ordinary DOM elements or arbitrary browser events.

### JavaScript and TypeScript consumers

The [typed consumer](../examples/consumer/typescript.tsx) wraps a generated component with `asReactComponent`, using its exported Lean constructor to encode React props. It also imports a domain parser independently of the UI.

At the generated boundary, `Nat` and `Int` are `bigint`; constructors are tagged values; type/proof argument slots are retained as `null`. Do not pass a plain JS object just because it resembles a Lean structure. Inspect the generated `.d.mts` and manifest, and prefer exported constructors or explicit codecs. Use the exported `__leanjs_fn(arity, callback)` for callbacks whose JavaScript parameter count does not express their intended arity, such as rest/default-parameter functions.

A separate application can consume this checkout as a local Lake dependency and choose its own ESM adapter paths. General application scaffolding and a published npm runtime package are not part of this workspace. Keep the pinned Lean version and resolve shared libraries, React, and the React adapter consistently so that host/context identities are not duplicated.

## Check and debug your work

A Lean typecheck proves that a source program elaborates. It does not prove that every reachable declaration is in the JavaScript compiler's portable subset or that its browser interactions work.

| Changed area | Useful check |
| --- | --- |
| A Lean application module | `lake build Examples.YourModule`, then its actual generator. |
| The built-in examples or generated declarations | `npm run build`, then the relevant mounted integration or browser test. |
| Compiler lowering or ABI | `npm run test:compiler`; this includes native/generated parity and rejection checks. |
| The actual Tickets generator in isolation | `npm run test:compiler:integration`, after the compiler suite. |
| Shared runtime behavior | `npm run test:runtime`. |
| The full regular suite | `npm test`. |
| Browser interactions | `npm run test:browser`. |
| README captures after visual changes | `npm run screenshots`. |

Playwright needs Chromium installed or `PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH` set to an installed Chromium/Chrome executable. Follow the browser setup available on your machine. Native service checks have additional dependencies and are documented separately in [NATIVE.md](NATIVE.md).

For a custom form, exercise both invalid and valid submission. For collection changes, add/edit/reorder/remove rows and check error paths and retained state. For a shared context, mount a provider and consumer from their separately generated libraries. A native-only check or a hand-written JS stand-in does not exercise those boundaries.

| Symptom | What to inspect |
| --- | --- |
| `unknown module` or missing `.olean` | Lake source roots and whether the imported module was built. `Examples.*` sources live under `examples/lean`, not the repository root. |
| `implemented_by` / native extern rejection | The full compiler dependency path. Use a supported formulation or add a named, tested host contract where needed. `Array.forIn'` and `Array.foldlM` reference bodies are supported; arbitrary native operations are not. |
| Hook placement rejection | Conditional hooks, dynamic labels, or an unsupported higher-order hook path. Preserve a fixed hook sequence and use child components for conditional state. |
| State resets on rerender | A fresh component specialization, changed key, or changed parent identity. Hoist component definitions and use stable keys. |
| A context is created during render | A context factory is being called inside render instead of through a top-level value. |
| A consumer keeps the default context | The provider's placement and the generated library imports. Check shared object identity and canonical ESM resolution. |
| Library interface/signature mismatch | Producer version, manifest, and the consumer's Lean interface. Rebuild matching artifacts rather than editing the manifest to suppress the check. |
| A recent edit is missing in the browser | The generator registration, output path, build result, and page refresh. Failed builds can leave older generated files behind. |

## Work with a coding agent

The repository includes [SKILL.md](../SKILL.md). Give an agent this checkout and explicitly ask it to read that file. If your agent supports skill discovery, register the repository's skill according to that agent's setup; merely storing `SKILL.md` here does not automatically configure every client.

For example:

> Read `SKILL.md` and `docs/HOW_TO.md`. Add a reusable collection editor for our domain. Keep the row editor and layout replaceable, retain invalid raw input, and verify add/edit/reorder/remove and validation in the browser. Keep application code outside the engine.

Include your application's location, desired behavior, and any real JS/TS library or backend it must use. The skill points agents to maintained source examples and the relevant validation commands.
