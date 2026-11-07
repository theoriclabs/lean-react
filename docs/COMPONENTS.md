# Declarative components: design principles

Status: design, 2026-09-23. P1 (core types), P2 (host), P3 (commands and subscriptions), P4 (native testing), P5 (proofs) and P6 (typed calls) are implemented in `LeanReact.Program`; see [P1–P6 as built](COMPONENTS_PLAN.md#p1p6-as-built) and `examples/lean/Examples/Program.lean`. Implementation plan: [COMPONENTS_PLAN.md](COMPONENTS_PLAN.md). Purge: [LR-13](https://github.com/theoriclabs/lean-react/issues/43). Companion to LeanAPI's [typed endpoints](https://github.com/theoriclabs/leanapi/blob/main/docs/ENDPOINTS.md), which applies the same ideas to the server.

**The goal:** read a component's definition and know three things:
- every state it can be in;
- everything a user can do to it;
- everything it asks the outside world for.

Then prove things about it, as we already do for the server.

## Where we are

Today a component is `Props → Hook Element`, written with React-style hooks. From the chess UI (`leanchess/ui/App.lean`):

```lean
let session ← useState (props.saved) "session"
let game ← useState (none : Option Game) "game"
let selected ← useState "" "selected"          -- "" means "nothing selected"
let promoting ← useState "" "promoting"
let promotingTo ← useState "" "promotingTo"
let notice ← useState "" "notice"
-- … four more …
let press (f r : String) : Action Unit := do
  let current ← game.read
  let who ← session.read
  let origin ← selected.read
  match current, who with
  | some g, some s => … selected.set sq … notice.set "" … report (← props.api.act s g.id "play" origin sq "")
  …
DOM.button { className := some "ghost", onPress := some signOut } #[text "Sign out"]
```

What that costs:

- **State is scattered and stringly.** There are ten independent cells. Their combinations include states that make no sense, such as "promoting" with nothing selected, and `""` stands for "none".
- **Changes are imperative sequences.** A handler reads the last committed values, then writes several cells one after another. The steps are not atomic, and handlers re-`read` because `value` is a render snapshot.
- **Hooks need string labels.** A static checker walks the component's compiled code to prove the hook order. It needs fuel, and leanchess had to raise it to 2,000,000.
- **Effects hide in closures.** `useEffect` takes dependency arrays that are built by hand. A server call is `Action (Except String _)`, so nothing makes the UI handle each way a call can fail.
- **Markup is noisy.** `some` on every attribute, `#[…]` children, `text` wrappers.
- **Nothing can be proved.** `Hook`, `Action` and `Element` are IO closures, opaque to the kernel. No theorem about UI code exists today.

## The model

A component is a **state machine plus a view**, written as ordinary pure Lean:

```lean
/-- A chess board: select a piece, move it, promote. -/
inductive Selection where
  | none
  | piece (from : Square)
  | promoting (from to : Square)

structure Model where
  game : GameView
  selection : Selection := .none
  notice : Option Notice := none

/-- Everything a player can do here, and every answer the page can receive. -/
inductive Msg where
  | pressed (sq : Square)
  | promote (kind : PieceKind)
  | resign
  | moved (result : Except GameError (Versioned GameView))

def update : Msg → Model → Model × Cmd Msg
  | .pressed sq, m => …                        -- pure: the next model, and what to ask for
  | .promote k, m => …
  | .resign, m => (m, .call gamesApi.resign ⟨m.game.id⟩ .moved)
  | .moved (.ok g), m => ({ m with game := g.val, selection := .none }, .none)
  | .moved (.error e), m => ({ m with notice := some (.refused e) }, .none)

def view (m : Model) : Html Msg :=
  section_ [cls "table"] [
    board m.game m.selection,                  -- squares emit `.pressed sq`
    button [onClick .resign, disabled m.game.over] [text "Resign"]
  ]

def Board : Component GameView Model Msg := { init := fun g => ({ game := g }, .none), update, view }
```

## Principles

**1. All state is one typed value.**
- A component's state is a `Model`: a structure or inductive, not a set of cells.
- Invalid combinations are unrepresentable. `Selection.promoting from to` carries both squares, and there is no `""` sentinel.
- There are no hook labels and no hook-order checker: each component has exactly one state slot.

**2. Every change is a named message and a pure transition.**
- `Msg` lists everything a user or the outside world can do. `update : Msg → Model → Model × Cmd Msg` is total and pure.
- The runtime applies it atomically to the latest state, so there are no read-then-write races and no stale snapshots.

**3. The view is data.**
- `view : Model → Html Msg` returns a tree whose event handlers produce *messages*: `onClick .resign`, `onInput .typed`.
- Handlers cannot run code, so the whole view can be inspected, tested and reasoned about.
- Markup uses plain combinators with attribute lists:

  ```lean
  button [cls "primary", onClick .start, disabled busy] [text "Start"]
  ```

  There is no `some` and no `#[…]`, and a missing attribute is simply absent. A JSX-like `html!` notation can come later as pure sugar over the same data.

**4. Effects are data, and requests are typed by the server.**
- `update` returns `Cmd Msg` values: a call, navigation, a timer, local storage. The host runs them after the transition, and their results come back as messages.
- **A call is typed by the server endpoint it targets.** `Cmd.call gamesApi.playMove input .moved` only typechecks if `.moved` accepts the endpoint's declared response, `Except GameError (Replayed (Versioned GameView))`. The compiler then makes `update` handle every failure the server declares.
- Transport failures arrive as a typed `CallFailure` in the same message.
- This is where the UI and the API meet: the *same* type is the server's promise and the client's obligation.

**5. Long-lived inputs are declared, not effected.**
- `subscriptions : Model → Sub Msg` says what the component listens to *given its state*: a game's move stream while one is open, a clock tick while a game is running.
- The runtime starts and stops subscriptions as the model changes. There are no dependency arrays and no cleanup closures.

**6. Composition is typed.**
- A child component takes `Props`, and its messages are mapped into the parent's `Msg` (`Html.map`, `Cmd.map`).
- A child reports outward through a typed `Out` value, not a callback closure. A form reports `submitted value`; a modal reports `closed`.

**7. Components are provable.**
- `update` is a transition system, so the property library that proves LeanAPI's invariants applies unchanged. Examples:
  - "a selection always holds one of my own pieces"
  - "the promotion prompt appears only with a legal promotion pending"
  - "a form whose fields are invalid cannot emit `submitted`"
- `view` is a pure function, so properties like "Resign is disabled once the game is over" are theorems about data.

**8. Use LeanJS with the P0-tested representations.**
- `Model`, `Msg`, `update` and `view` are ordinary Lean. Structures, inductives, closures and typeclasses all compile today.
- The host side is small:
  - one React component per `Component`, holding one state slot;
  - `dispatch` applies `update` to the latest model synchronously (atomic in single-threaded JS), commits, then runs the commands;
  - the `Html` tree is walked in JavaScript into React elements, so React still does keyed diffing and DOM reconciliation.
- The [P0 results](#p0-compiler-spike-lean-4350) require host-erased child embedding and generated JSON codecs. No new hook checker is needed for this path.

**9. It stays testable natively.**
- `Component.simulate : List Msg → Model` and the pure `view` run in Lean with no browser.
- Browser tests stay for the host runtime and real DOM behavior.

**10. The low level stays, for now.**
- The hook API remains as an escape hatch, the way `Route` does in LeanAPI.
- New code uses components; existing examples migrate one by one.

## Keeping each tool focused: purge LeanApp from LeanReact

LeanReact grew a whole application framework (`LeanApp`, `LeanAppNative`, a Node gateway, a scaffold, demos and docs). Server concerns now live in LeanAPI. After the purge, **LeanReact is the UI library plus the LeanJS compiler**, and nothing else.

| Item | Action | Why |
|---|---|---|
| `engine/LeanReact`, `engine/LeanJS`, `engine/runtime`, `engine/adapters` | Keep | The UI library and its compiler |
| `engine/LeanOntology` | Keep, for now | `Forms` uses its validation types. It may become a shared package later |
| `engine/LeanContract` | Keep the client side (`CallFailure`, codecs, generated clients); move the `PublicOperation` family out of `LeanApp/Binding.lean` into it | `Resources` and the generated clients need it, and moving it breaks a `LeanContract → LeanApp` import cycle |
| `engine/LeanApp`, `engine/gateway`, `adapters/native`, `templates/app`, `deploy/` | Delete | Server-side. LeanAPI covers sessions, auth, policies, routing and proofs |
| `examples/{native,cafe,notes,auth,ordering,security}` and the `Ordering`, `Cafe`, `PrivateNotes` libraries | Delete | App demos. The proved private-data example now lives in LeanAPI (`private-games`) |
| App tests, scripts, `package.json` scripts, and the `native`, `auth` and `cafe` Playwright configs | Delete | App-only |
| App docs (ARCHITECTURE, AUTH, AUTHORIZATION_DEMO, PRIVATE_NOTES, DOMAIN_MODELING, FULLSTACK_INTERFACES, GETTING_STARTED, HOSTING, NATIVE, RELEASE) | Delete, and fix the links to them | App-only |
| `examples/lean/Examples/Tickets/Contracts.lean` | Rewrite without `LeanApp.Binding` | Otherwise `lake build Examples` still pulls LeanApp in |
| `Channels`/`Streams` and their runtime | Delete (LR-13) | Their only server was the deleted gateway, and the JS bridge was never finished; they return as `Sub` |

What must keep working:
- the package name `leanreact`, which leanchess requires by name;
- `LeanReact.Compiler`, which leanchess's Dockerfile builds;
- the JS adapters leanchess imports;
- every UI test and Playwright suite.

## Open questions

1. **Where does the property kernel live?** LeanReact should not depend on LeanAPI. `LeanApi.Props` would move to its own small package that both depend on.
2. **Where do endpoint types live, for typed calls?** The client needs the endpoint signatures and response types, not the server runtime. The likely answer is splitting LeanAPI into a pure "spec" part (input wrappers, typed responses, `Api` descriptions) and the server. The client derives request building and response decoding from the same signature.
3. **Channels and Streams.** Decided in [LR-13](https://github.com/theoriclabs/lean-react/issues/43): removed with the gateway, whose protocols were their only server (and their JS bridge was never exported). Long-lived inputs return as `Sub`, backed by LeanAPI.
4. **JSX-like notation.** Is it worth it on top of the combinators, and when?
5. **Migration order.** Counter and Forms examples first, then Tickets, then the leanchess UI as the real test.

## P0 compiler spike: Lean 4.35.0

Validated on 2026-11-06 for [LR-14](https://github.com/theoriclabs/lean-react/issues/44).
The fixtures are probes, not the public `Program` API. Run `npm run test:compiler`;
[Components.lean](../tests/compiler/Components.lean),
[GenerateComponents.lean](../tests/compiler/GenerateComponents.lean) and
[the jsdom assertions](../tests/compiler/components.test.mjs) cover all seven questions.
The harness regenerates and compares the ESM, declarations, manifests, codecs and
recorded rejection decisions in separate Lean processes.

| Construct | Result | Decision for P1 and later |
| --- | --- | --- |
| Nested `Html Msg` with `List (Html Msg)` | Compiles and renders nested nodes, attributes, text and `none` in jsdom. | Keep lists; no flat or array representation is required by this probe. |
| Structural `Html.map` | Compiles and maps handlers under nested nodes and the child bundle. | Keep the pure map. It uses the JavaScript stack; this is not a stack-safety result for arbitrary trees. |
| Closures inside attributes | Captures survive compilation; input decoders return `some` messages or suppress dispatch with `none`. | Keep typed event decoders. |
| Existential child embed | A bundle with hidden props/model/message types compiles; its three type witnesses are `null` at the ABI, and children with Nat and String models remain distinct. The fully recursive indexed `Html` attempt is rejected by Lean's kernel before LeanJS. | Use the planned host-erased child boundary. Do not assume that a fully typed recursive `Embed` record can simply be inserted into the List-based view. |
| `update : Msg → Model → Model × Cmd Msg` | A `Model × Cmd Msg` result, a batch, a timer and a request continuation compile. Tests feed the continuation result through `update` again and preserve integers beyond 2^53. | Keep pure transition results and captured command continuations. Running commands and dispatch ordering remain P2/P3 work. |
| Derived `FromJson` for a record | Native decoding works, but LeanJS rejects the derived decoder through `Lean.Name.beq`, a native extern reached by its error formatting. | Use generated codecs for P6. The same Lean record has a generated client codec tested against native wire output, large integers, missing/extra fields and malformed values. Host JSON parsing does not make the Lean decoder portable. |
| 64-square view and deeper paths | The board renders 64 squares from 193 Html nodes at depth 4. A separate 128-wrapper path also renders (129 nodes/depth 129). | No flattening or lazy cache is forced at this scale. Keep measuring in P2; this does not establish unbounded depth or production rendering performance. |

The existential attempt is preserved in
[ComponentsEmbedRejected.lean](../tests/compiler/ComponentsEmbedRejected.lean).
A child whose view returns its own `Html ChildMsg` motivates an indexed `Html`;
putting that local message index under `List` produces the kernel error
“nested inductive datatypes parameters cannot contain local variables”. Keeping
explicit existential witnesses also raises the bundle/view universe to `Type 1`.
The positive fallback fixtures check leaf bundles inside the tree and a full
child bundle outside the recursive Html definition. That host boundary renders
the child’s own `Html ChildMsg`, dispatches its messages through its own model,
and maps reports to the parent. This is a probe host; production mounting,
atomicity, commands and lifecycle still belong to P2/P3.

The jsdom run reports walk and commit timings without enforcing a flaky speed
threshold. One local run took about 1 ms to walk the board and 6 ms including the
commit; these numbers are an observation, not a browser performance guarantee.
Both rejection paths are executable gates, so a future compiler or Lean change
must revisit the corresponding fallback instead of silently retaining it.
