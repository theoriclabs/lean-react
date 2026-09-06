# LeanReact

Write React components, reusable behavior, and shared application models in Lean. LeanReact is an experimental implementation of the [vision](VISION.md): ordinary functions, callbacks, generic components, and reusable ontologies are its main building blocks.

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

The browser build compiles Lean declarations into JavaScript modules and renders them through React. The example's domain rules, event closures, custom hooks, and component render functions come from Lean source.

The reusable [engine](engine/README.md) and [example applications](examples/README.md) have separate source roots:

```text
engine/                  Lean libraries, compiler, runtime, and React bridge
examples/lean/           Lean example components, domains, and generators
examples/web/            Browser demo entry point and CSS
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

The same compiled workspace can use the native service. Build the optional adapter with `bash examples/native/build-cached.sh`, then run these in two terminals:

```sh
examples/native/.lake/cached/bin/tickets_server 8081 /tmp/leanreact-tickets.sqlite
```

```sh
LEANREACT_API=http://127.0.0.1:8081 npm run dev
```

Open `http://localhost:4173/?service=native`. This uses the sibling LeanDB and LeanHttp checkouts; see [native setup and tests](docs/NATIVE.md). `npm run example:consumer` exercises the generated domain module from Node, and `npx tsc --noEmit` checks the TypeScript consumer.

Real-browser checks are `npm run test:browser` and `npm run test:native:browser` (build the optional native adapter first). Install a Playwright Chromium browser or set `PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH` to an installed Chromium/Chrome executable. On this Mac, the verified value is `/Applications/Google Chrome.app/Contents/MacOS/Google Chrome`.

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
