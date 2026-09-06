# LeanReact

Compose your frontend. Share the rest.

Write React components, reusable behavior, and shared application models in Lean. Ordinary functions, callbacks, and ontologies are the building blocks. LeanReact compiles real Lean declarations to JavaScript and renders them through React.

![LeanReact showcase with a live Lean counter beside its source code](docs/images/showcase.png)

[Run locally](#run-locally) · [How-to guide](docs/HOW_TO.md) · [Agent skill](SKILL.md) · [Read the vision](VISION.md) · [Current scope](docs/IMPLEMENTED.md)

LeanReact is experimental. Components, collection forms, shared contexts, and domain logic work in the demonstrated subset. APIs and the generated ABI can change; [the composition guide](docs/COMPOSABILITY.md) explains what works and the remaining boundaries.

## A component is a Lean value

```lean
import LeanReact
open LeanReact

structure CounterProps where
  label : String

def Counter : Component CounterProps := component fun props => do
  let count ← useState 0 "count"
  pure <| DOM.button { onPress := some (count.modify (· + 1)) } #[
    text (props.label ++ ": " ++ toString count.value)
  ]
```

The example's domain rules, event closures, custom hooks, and component render functions come from Lean source. Swap a layout by passing another component. Share a rule by importing the same domain module. Independently compiled libraries can import one shared context through an explicit ESM dependency.

## The playground

`npm run dev` serves the showcase at `http://localhost:4173`. It includes a live counter, syntax-highlighted excerpts from the actual Lean files, and three interactive examples:

| Example | Try it | Lean source |
| --- | --- | --- |
| Composable workspace | Switch board/inbox layouts, swap field editors, and save a ticket | [Tickets components](examples/lean/Examples/Tickets/Components.lean) |
| Collection forms | Add, edit, reorder, and remove keyed rows; inspect nested validation errors | [Collections](examples/lean/Examples/Collections.lean) |
| Shared contexts | Change a provider value and watch a consumer from another compiled library update | [Library example](examples/lean/Examples/Libraries/App.lean) |

The workspace reuses the same editor behavior across layouts:

![Working Tickets workspace with a saved edit, reusable counters, and composition controls](docs/images/workspace.png)

Collection validation follows the current row order while each row retains its own state:

![Collection form after reordering, showing retained row state, nested validation errors, and its actual Lean source](docs/images/collections.png)

These are real browser captures. Run `npm run screenshots` to regenerate them with Playwright Chromium, or set `PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH` to an installed Chrome executable. Screenshot capture also checks the mobile page for horizontal overflow.

## Engine and examples

The reusable [engine](engine/README.md) and [example applications](examples/README.md) have separate source roots:

```text
engine/                  Lean libraries, compiler, runtime, and React bridge
examples/lean/           Lean example components, domains, and generators
examples/web/            Showcase website, browser entry point, and CSS
examples/consumer/       Independent JavaScript/TypeScript consumers
examples/adapters/       Example-specific foreign and service bindings
examples/native/         Optional Tickets server using LeanDB and LeanHttp
examples/generated/      Generated example modules (ignored)
examples/dist/           Bundled browser example (ignored)
```

Run `npm run build:engine` (or `lake build`) to build only the engine. `npm run build` builds the browser example and its engine dependencies. Tests and workspace orchestration remain in root `tests/` and `scripts/`. Lean import names such as `LeanReact` and `Examples.Tickets.Domain` are preserved by the Lake source-root configuration.

## Run locally

Install the pinned Lean toolchain with [elan](https://github.com/leanprover/elan) and use Node 22.13 or newer (tested on Node 24). From this directory:

```sh
npm ci
npm run build
npm run dev
```

Open `http://localhost:4173`. The development command watches sources and rebuilds; refresh the browser after a successful build. `npm test` runs Lean checks, compiler parity tests, mounted React tests, and generated-component integration tests. The compiler, native backend, and compiler/protocol test harnesses are Lean; browser/build tooling uses JavaScript/TypeScript. No Python installation is required. Native SQLite/HTTP integration has its own optional dependencies and commands.

The showcase is a static site: `npm run build` writes its HTML, CSS, favicon, and bundled JavaScript to `examples/dist/`. Assets use relative URLs so the site can be served under a subdirectory. The default examples run locally in browser memory. The native service below is optional.

The same compiled workspace can use the native service. Build the optional adapter with `bash examples/native/build-cached.sh`, then run these in two terminals:

```sh
examples/native/.lake/cached/bin/tickets_server 8081 /tmp/leanreact-tickets.sqlite
```

```sh
LEANREACT_API=http://127.0.0.1:8081 npm run dev
```

Open `http://localhost:4173/?service=native`. This uses the sibling LeanDB and LeanHttp checkouts; see [native setup and tests](docs/NATIVE.md). `npm run example:consumer` exercises the generated domain module from Node, and `npx tsc --noEmit` checks the TypeScript consumer.

Real-browser checks are `npm run test:browser` and `npm run test:native:browser` (build the optional native adapter first). Install a Playwright Chromium browser or set `PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH` to an installed Chromium/Chrome executable. On this Mac, the verified value is `/Applications/Google Chrome.app/Contents/MacOS/Google Chrome`.

## Build your own frontend

The [how-to guide](docs/HOW_TO.md) walks through a complete Lean form, from a shared domain parser to a mounted React page. It also covers replaceable editors, focused fields, keyed collections, shared library contexts, services, CSS, and JavaScript/TypeScript interop.

For coding agents, [SKILL.md](SKILL.md) maps the implementation, composition patterns, compiler boundaries, and validation commands. Ask your agent to read it from this checkout before starting; it does not require a particular agent client.

```text
Read SKILL.md and docs/HOW_TO.md. Build a collection editor for our domain
with replaceable row and layout components. Retain invalid drafts, verify
add/edit/reorder/remove in the browser, and keep application code outside engine/.
```

## Library boundaries

| Library | Purpose | Imports |
| --- | --- | --- |
| `LeanOntology` | Typed paths, lenses, identities, validation, descriptors, and codecs | Lean/Std |
| `LeanContract` | Typed public operations, handlers, and transport interpreters | LeanOntology |
| `LeanReact` | Components, elements, hooks, actions, and typed DOM constructors | Lean/Std; optional ontology helpers |
| `LeanJS` | Compile portable Lean declarations to ESM | Lean compiler APIs |
| `engine/adapters/` | Reusable LeanJS/React host representation bridge | LeanJS ABI and React runtime |
| `examples/adapters/`, `examples/native/` | Tickets-specific host bindings and backend integration | Engine and optional sibling libraries |

The neutral ontology and contract libraries do not import React, SQLite, or HTTP. The [Tickets domain](examples/lean/Examples/Tickets/Domain.lean) is shared source. The [components](examples/lean/Examples/Tickets/Components.lean) demonstrate a generic list, callback props, replaceable card footers, and one editor hook used in two layouts.

Styling currently uses ordinary CSS and Lean `className` props. Foreign React components use explicit adapters; a typed Lean CSS API and shadcn integration are not implemented. See [styling and ecosystem boundaries](docs/IMPLEMENTED.md#styling-and-the-javascripttypescript-ecosystem).

Read [the implemented scope and limits](docs/IMPLEMENTED.md), [qualification results](docs/QUALIFICATION.md), [implementation plan](IMPLEMENTATION_PLAN.md), [compiler ABI](engine/LeanJS/ABI.md), [ontology API](engine/LeanOntology/API.md), and [React API](engine/LeanReact/API.md). This repository is an experimental library workspace; APIs and the generated value ABI can change.
