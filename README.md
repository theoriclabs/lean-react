# LeanReact

Write React components in Lean. They compile to JavaScript and render with React. Props, state, hooks, and components you pass into other components stay the familiar building blocks.

[v0.2.0-rc.1 pre-release](https://github.com/theoriclabs/lean-react/releases/tag/v0.2.0-rc.1) · [v0.1 release](https://github.com/theoriclabs/lean-react/releases/tag/v0.1) · [How-to guide](docs/HOW_TO.md) · [Frontend docs](docs/LEANREACT.md) · [MIT license](LICENSE)

![LeanReact playground with a live counter beside its Lean source](docs/images/showcase.png)

LeanReact is experimental. The [v0.1 release](https://github.com/theoriclabs/lean-react/releases/tag/v0.1) is the frontend foundation; the [v0.2.0-rc.1 pre-release](https://github.com/theoriclabs/lean-react/releases/tag/v0.2.0-rc.1) adds the LeanApp full stack ([release evidence](docs/RELEASE.md)). APIs can change.

## A counter in Lean

Start with a typed props record, a hook, and a DOM node. This is an ordinary React function component, written in Lean:

<!-- lean-check: readme-counter -->
```lean
import LeanReact
open LeanReact

structure CounterProps where
  label : String

def Counter : Component CounterProps := component fun props => do
  let count ← useState 0 "count"
  pure <| DOM.button {
    onPress := some (count.modify (fun value => value + 1))
  } #[
    text (props.label ++ ": " ++ toString count.value)
  ]
```

Read it the way you would read React:

- `structure CounterProps` is the props type, like a TypeScript interface.
- `useState` gives you `count.value`, `count.set`, and `count.modify`. The last one is `setCount(previous => previous + 1)`. `"count"` is a stable hook label.
- `DOM.button` creates a button; `#[...]` is its children. `onPress` runs the update when clicked.

A few syntax hints: `fun value => ...` is an arrow function, `some` supplies an optional prop, and `++` joins strings. `←` reads a hook; `pure <|` returns the rendered element.

The [first-form tutorial](docs/HOW_TO.md#build-your-first-form) walks through complete files, including compiling and mounting a component.

## Compose by passing pieces

Pass an editor into a form. Pass a row component into a list. Share a custom hook between two layouts. These are ordinary values and functions, so you can change one piece without rewriting the screen.

![Ticket workspace with a saved edit and replaceable layouts and editors](docs/images/workspace.png)

The playground includes:

- A ticket workspace with interchangeable layouts and field editors.
- Collection forms that keep each row’s state when you reorder them, and keep invalid input while you edit.
- A context provider and consumer built in separate libraries that share live updates.

![Collection form with keyed rows, validation errors, and the Lean source that composes the editor](docs/images/collections.png)

Shared domain definitions describe application data and its rules. The same title validator can run in your form and on a Lean backend. Start with a type and a parsing function; add richer descriptions when the application needs them.

## Bugs that don't compile

Some common React bugs are type errors or build failures here, not runtime surprises.

**Forgetting a loading, empty, or error state.** `useResource` returns one closed type: `idle`, `loading`, `success`, or `failure`. The data only exists inside `success`, so the only way to read it is a `match`, and the match must be exhaustive.

<!-- lean-check: readme-states -->
```lean
import LeanReact
open LeanReact

def loadTickets (_ : ResourceRequest) : Action (Except String (Array String)) :=
  pure (.ok #["Fix the login page"])

def TicketList : Component Unit := component fun _ => do
  let tickets ← useResource (Key.string "tickets") loadTickets #[] true "tickets"
  pure <| match tickets.state with
    | .idle => empty
    | .loading _ => DOM.p {} #[text "Loading…"]
    | .failure _ (.loader message) => DOM.p { role := some "alert" } #[text message]
    | .failure _ (.call .unauthenticated) => DOM.p { role := some "alert" } #[text "Sign in first."]
    | .failure _ (.call failure) => DOM.p { role := some "alert" } #[text ("Request failed: " ++ failure.code)]
    | .failure _ (.exception message) => DOM.p { role := some "alert" } #[text ("Unexpected: " ++ message)]
    | .success _ items => DOM.ul {} (items.map fun item => DOM.li {} #[text item])
```

Delete the `.idle` and `.loading` arms and the compiler answers `Missing cases`. A typed loader error, a transport failure (`.call`, a closed `CallFailure` type), and an unexpected exception are separate constructors, so they cannot be conflated by accident. "Loading and failed at once" has no constructor at all.

**Setting state during render.** Render runs in `Hook`; state updates are `Action` values. There is no way to run one inside the other, so this is a type error:

<!-- lean-reject: readme-set-during-render | Type mismatch -->
```lean
import LeanReact
open LeanReact

def Broken : Component Unit := component fun _ => do
  let count ← useState 0 "count"
  count.set 0   -- error: Action Unit, expected Hook Unit
  pure <| text (toString count.value)
```

Updates go in event handlers (`onPress := some (count.set 0)`) or in `useEffect`.

**Conditional hooks.** The compiler inspects every component and custom hook and refuses to emit JavaScript when a hook sits behind a branch, inside a loop, or in a recursive call. It follows your custom hooks with their real arguments, so the check is not based on a `use` prefix. To render state conditionally, render a child component conditionally; each `element` is its own hook boundary.

**Null and typos.** Optional fields are `Option`, so `ticket.assignee` has to be matched before it is used. Statuses are inductives, so `"in-progress"` versus `"inProgress"` is not a value you can write, and adding a status breaks every `match` until it is handled.

**Duplicate keys.** `keyedEach` takes a key function over the item, not an index, and throws on a duplicate sibling key in both the reference interpreter and the browser.

This is not a proof of correctness. Stale closures, wrong effect dependencies, CSS, and business logic that typechecks but does the wrong thing are still yours. The [frontend guide](docs/HOW_TO.md#check-and-debug-your-work) lists what the tests exercise.

For a longer worked example, [checkout state explosion](docs/whatbugs_can_we_prevent/checkout_state_explosion.md) takes a nine-field checkout form from 12,288 representable states down to a type with exactly 888, and has Lean count both.

## CSS and existing React libraries

Use regular CSS files and `className` props. JavaScript and TypeScript can consume the generated components too.

Existing React libraries need an explicit binding between their props and Lean. There is a working foreign-component example in the [interop guide](docs/HOW_TO.md#existing-react-components-including-shadcn). shadcn and Tailwind are not configured out of the box.

## Run locally

You’ll need Git, Node 22.13 or newer, and [elan, the Lean version manager](https://github.com/leanprover/elan#installation). Think of elan like nvm: it installs the Lean version this project selects. Follow its installation instructions for your OS, then open a new terminal.

```sh
git clone https://github.com/theoriclabs/lean-react.git
cd lean-react
npm ci
npm run dev
```

Open **http://localhost:4173**. The first build may download the Lean compiler. The examples run in browser memory, so you can try them immediately.

Start by editing the [counter component](examples/lean/Examples/Showcase.lean). The dev server rebuilds when you save; refresh the browser to see the change.

## What to expect

This is an experimental library for Lean-authored frontends. The examples demonstrate working components, forms, asynchronous data loading, and shared domain rules. Only a subset of Lean compiles to JavaScript today; routing, React Server Components, and automatic JS/TS bindings are still ahead. See [current support and limits](docs/IMPLEMENTED.md).

To build your own screen, follow the [how-to guide](docs/HOW_TO.md). If you’re using a coding agent, ask it to read [SKILL.md](SKILL.md) first.

Application code lives in [examples/](examples/README.md); reusable framework code lives in [engine/](engine/README.md). Contributor checks and architecture details are in the [development guide](docs/HOW_TO.md#check-and-debug-your-work) and the [documentation index](docs/README.md).
