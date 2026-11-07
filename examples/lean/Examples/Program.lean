import LeanReact
import LeanReact.Compiler

/-! Declarative components (`LeanReact.Program`): a counter and a keyed todo list, as a model,
messages, a pure `update` and a `view` whose events produce messages. -/

namespace Examples.Program
open LeanReact.Program

/-! ## Counter -/

inductive CounterMsg where
  | add (n : Nat)
  | reset

def Counter : Component Nat Nat CounterMsg where
  init start := (start, .none)
  update _ msg n := match msg with
    | .add k => (n + k, .none)
    | .reset => (0, .none)
  view _ n := div [cls "counter"] [
    p [role "status"] [text s!"Count: {n}"],
    button [onClick (.add 1)] [text "Add one"],
    button [onClick (.add 9007199254740993)] [text "Add 2^53 + 1"],
    button [onClick .reset, disabled (n == 0)] [text "Reset"]]

/-! ## A keyed todo list -/

structure Todo where
  id : Nat
  title : String
  done : Bool := false

structure TodoModel where
  todos : List Todo
  draft : String := ""
  nextId : Nat

inductive TodoMsg where
  | typed (text : String)
  | add
  | toggle (id : Nat)
  | reverse

def todoUpdate : TodoMsg → TodoModel → TodoModel × Cmd TodoMsg
  | .typed text, m => ({ m with draft := text }, .none)
  | .add, m =>
    if m.draft.isEmpty then (m, .none)
    else ({ m with todos := m.todos ++ [{ id := m.nextId, title := m.draft }], draft := "", nextId := m.nextId + 1 }, .none)
  | .toggle id, m => ({ m with todos := m.todos.map fun t => if t.id == id then { t with done := !t.done } else t }, .none)
  | .reverse, m => ({ m with todos := m.todos.reverse }, .none)

def todoView (m : TodoModel) : Html TodoMsg :=
  section_ [ariaLabel "Todos"] [
    form [onSubmit .add] [
      input [ariaLabel "New todo", value m.draft, onInput .typed,
        onKeyDown (fun e => if e.key == "Escape" then some (.typed "") else none) (fun e => e.key == "Escape")],
      button [type_ "submit", disabled m.draft.isEmpty] [text "Add"]],
    each m.todos (fun t => toString t.id) (tag := "ul") fun t =>
      li [dataAttr "id" (toString t.id)] [
        label [] [input [type_ "checkbox", checked t.done, onCheck fun _ => .toggle t.id], text t.title]],
    when (m.todos.length > 1) (button [onClick .reverse] [text "Reverse"])]

def Todos : Component Unit TodoModel TodoMsg where
  init _ := ({ todos := [{ id := 1, title := "Write the plan" }, { id := 2, title := "Ship P1" }], nextId := 3 }, .none)
  update _ := todoUpdate
  view _ := todoView

/-! ## Mounted (the host) -/

/-- The counter as an element. -/
def counterElement (start : Nat) : LeanReact.Element := Counter.toElement start
def todosElement : LeanReact.Element := Todos.toElement ()

/-- Atomicity: one click reaches the button and its row (bubbling); both messages apply. -/
def Nested : Component Unit Nat CounterMsg where
  init _ := (0, .none)
  update _ msg n := match msg with | .add k => (n + k, .none) | .reset => (0, .none)
  view _ n := div [onClick (.add 10), dataAttr "testid" "row"] [
    button [onClick (.add 1)] [text "Inner"], p [role "status"] [text s!"Total {n}"]]

def nestedElement : LeanReact.Element := Nested.toElement ()

/-- Commands: `log` is host work, run once after the commit; a failed task is a message. -/
structure LogProps where
  log : String → LeanReact.Action Unit
  fail : LeanReact.Action Nat

inductive LogMsg where
  | ping
  | pinged
  | failed (reason : String)
  | got (n : Nat)

def Logged : Component LogProps Nat LogMsg where
  init _ := (0, .none)
  update props msg n := match msg with
    | .ping => (n + 1, .batch [.exec (props.log s!"after {n + 1}"), .task (pure (some .pinged))])
    | .pinged => (n, .exec (props.log "pinged"))
    | .failed reason => (n, .exec (props.log s!"failed: {reason}"))
    | .got k => (n + k, .none)
  view _ n := div [] [
    p [role "status"] [text s!"Pings {n}"],
    button [onClick .ping] [text "Ping"],
    button [onClick (.got 0)] [text "Noop"]]

def LoggedFailing : Component LogProps Nat LogMsg :=
  { Logged with update := fun props msg n => match msg with
      | .ping => (n, .perform props.fail fun
          | .ok k => .got k
          | .error (.userError reason) => .failed reason
          | .error _ => .failed "host error")
      | other => Logged.update props other n }

def logged (log : String → LeanReact.Action Unit) (fail : LeanReact.Action Nat) (failing : Bool) : LeanReact.Element :=
  (if failing then LoggedFailing else Logged).toElement ⟨log, fail⟩

/-- Keyed embedded children keep their own models when reordered; a child's `.reset` reaches
the parent through `toParent`. -/
structure BoardModel where
  rows : List Nat
  resets : Nat := 0

inductive BoardMsg where
  | reverse
  | childReset

def Board : Component Unit BoardModel BoardMsg where
  init _ := ({ rows := [1, 2, 3] }, .none)
  update _ msg m := match msg with
    | .reverse => ({ m with rows := m.rows.reverse }, .none)
    | .childReset => ({ m with resets := m.resets + 1 }, .none)
  view _ m := div [] [
    button [onClick .reverse] [text "Reverse rows"],
    p [dataAttr "testid" "resets"] [text s!"Resets {m.resets}"],
    each m.rows toString (tag := "ul") fun row =>
      li [dataAttr "row" (toString row)] [
        Counter.embed row (fun | .reset => some .childReset | _ => none) (key := s!"counter-{row}")]]

def boardElement : LeanReact.Element := Board.toElement ()

/-- Interop both ways: a hook element inside a view, and a program inside a hook component. -/
def Interop : LeanReact.Component Unit := LeanReact.Component.named "ProgramInterop" <| LeanReact.component fun _ => do
  let outer ← LeanReact.useState (0 : Nat) "outer"
  let inner : Component Nat Nat CounterMsg := { Counter with
    view := fun _ n => div [dataAttr "testid" "program"] [
      p [] [text s!"Program {n}"],
      button [onClick (.add 1)] [text "Program +1"],
      Html.element (LeanReact.DOM.span { data := #[("testid", "hook-in-program")] } #[LeanReact.text "hook element"])] }
  pure <| LeanReact.DOM.div {} #[
    LeanReact.DOM.p { data := #[("testid", "outer")] } #[LeanReact.text s!"Outer {outer.value}"],
    inner.toElement 100 (onMsg := fun _ => outer.modify (· + 1))]

/-! ## Commands and subscriptions (P3) -/

/-- A clock: ticks while running (a subscription that starts and stops with the model), and
Escape stops it (a document key subscription). -/
structure ClockModel where
  running : Bool := false
  ticks : Nat := 0

inductive ClockMsg where
  | start | stop | tick (now : Nat)

def Clock : Component Unit ClockModel ClockMsg where
  init _ := ({}, .none)
  update _ msg m := match msg with
    | .start => ({ m with running := true }, .none)
    | .stop => ({ m with running := false }, .none)
    | .tick _ => ({ m with ticks := m.ticks + 1 }, .none)
  view _ m := div [] [
    p [role "status"] [text s!"Ticks {m.ticks}"],
    button [onClick .start, disabled m.running] [text "Start"],
    button [onClick .stop, disabled (!m.running)] [text "Stop"]]
  subscriptions _ m := if m.running then .batch [Sub.every 1000 .tick,
    Sub.onKey fun e => if e.key == "Escape" then some .stop else none] else .none

def clockElement : LeanReact.Element := Clock.toElement ()

/-- A game watcher: the move feed is a host source keyed by game id (switching games stops the
old feed and starts the new one), and signing in is `Cmd.perform` over a host action. -/
structure WatchProps where
  watch : String → (String → LeanReact.Action Unit) → LeanReact.Action (LeanReact.Action Unit)
  signIn : String → LeanReact.Action String

structure WatchModel where
  game : String := "g1"
  moves : List String := []
  user : Option String := none
  error : Option String := none

inductive WatchMsg where
  | open_ (game : String)
  | moved (move : String)
  | signIn
  | signedIn (result : Except IO.Error String)
  | later
  | stored (value : Option String)
  | rolled (n : Nat)
  | roll

def Watcher : Component WatchProps WatchModel WatchMsg where
  init _ := ({}, Cmd.load "watcher.game" .stored)
  update props msg m := match msg with
    | .open_ game => ({ m with game, moves := [] }, .batch [Cmd.store "watcher.game" game, Cmd.focus "moves"])
    | .moved move => ({ m with moves := m.moves ++ [move] }, .none)
    | .signIn => (m, Cmd.perform (props.signIn "ada") .signedIn)
    | .signedIn (.ok user) => ({ m with user := some user, error := none }, Cmd.navigate s!"/games/{m.game}")
    | .signedIn (.error (.userError reason)) => ({ m with error := some reason }, .none)
    | .signedIn (.error _) => ({ m with error := some "sign-in failed" }, .none)
    | .later => (m, Cmd.after 500 (.moved "late"))
    | .stored (some game) => ({ m with game }, .none)
    | .stored none => (m, .none)
    | .rolled n => ({ m with moves := m.moves ++ [s!"rolled {n}"] }, .none)
    | .roll => (m, Cmd.random 6 .rolled)
  view _ m := div [] [
    p [role "status"] [text s!"Game {m.game}: {", ".intercalate m.moves}"],
    p [dataAttr "testid" "user"] [text (m.user.getD (m.error.map ("error: " ++ ·) |>.getD "signed out"))],
    ul [elementId "moves", .attr "tabIndex" "-1"] [],
    button [onClick (.open_ "g1")] [text "Game 1"],
    button [onClick (.open_ "g2")] [text "Game 2"],
    button [onClick .signIn] [text "Sign in"],
    button [onClick .later] [text "Later"],
    button [onClick .roll] [text "Roll"]]
  subscriptions props m := .source s!"game:{m.game}" fun emit => props.watch m.game fun move => emit (.moved move)

def watcherElement (watch : String → (String → LeanReact.Action Unit) → LeanReact.Action (LeanReact.Action Unit))
    (signIn : String → LeanReact.Action String) : LeanReact.Element := Watcher.toElement ⟨watch, signIn⟩

/-! ## Native checks -/

/-- A view as text, for native tests: tags, text and keys. -/
partial def outline : Html α → String
  | .text value => value
  | .node tag _ children => s!"<{tag}>" ++ String.join (children.map outline) ++ s!"</{tag}>"
  | .keyed key child => s!"[{key}]" ++ outline child
  | .embed child => s!"<embed {child.key}>"
  | .lazy key view => s!"<lazy {key}>" ++ outline (view ())
  | .none => ""

/-- The message a click on the first element with exactly this text would send. -/
partial def clickText (label : String) : Html α → Option α
  | .node _ attrs children =>
    let here := if children.any (fun c => match c with | .text t => t == label | _ => false)
      then attrs.findSome? fun | .onPress decode => decode {} | _ => none else none
    here.orElse fun _ => children.findSome? (clickText label)
  | .keyed _ child => clickText label child
  | .lazy _ view => clickText label (view ())
  | _ => none

private def run (msgs : List TodoMsg) : TodoModel :=
  msgs.foldl (fun m msg => (todoUpdate msg m).1) (Todos.init ()).1

#guard outline (Counter.view 0 3) == "<div><p>Count: 3</p><button>Add one</button><button>Add 2^53 + 1</button><button>Reset</button></div>"
#guard ((clickText "Add one" (Counter.view 0 3)).map fun m => (Counter.update 0 m 3).1) == some 4
#guard (run [.typed "Third", .add, .reverse]).todos.map (·.id) == [3, 2, 1]
#guard (run [.typed "", .add]).todos.length == 2
-- `when` drops its view when the condition is false.
#guard outline (when false (text "x") : Html Unit) == ""
-- `Html.map` maps every message, including inside keyed rows.
#guard (clickText "Reverse" ((todoView (run [])).map fun _ => "mapped")) == some "mapped"
-- Duplicate sibling keys are found (the host rejects them).
#guard (each [1, 2, 1] toString (fun n => text (toString n)) : Html Unit).duplicateKey? == some "1"
#guard (todoView (run [.typed "x", .add])).duplicateKey? == none

#leanreact_check Examples.Program.Counter, Examples.Program.Todos, Examples.Program.counterElement,
  Examples.Program.todosElement, Examples.Program.logged, Examples.Program.boardElement, Examples.Program.Interop,
  Examples.Program.clockElement, Examples.Program.watcherElement

end Examples.Program

/-! ## Native behavior tests (`LeanReact.Program.Testing`) -/

namespace Examples.Program.Behavior
open LeanReact.Program

-- The counter: simulate messages, then read the view.
#guard (Counter.simulate 5 [.add 1, .add 2]).1 == 8
#guard (Counter.simulate 5 [.add 1, .reset]).1 == 0
#guard (findByRole (Counter.view 0 8) "status").map (·.text) == some "Count: 8"
#guard (findByRole (Counter.view 0 0) "button" (some "Reset")).map (·.disabled) == some true
#guard (findByRole (Counter.view 0 3) "button" (some "Reset")).map (·.disabled) == some false
-- Clicking *Reset* yields `.reset` (a disabled button yields nothing).
#guard (click (Counter.view 0 3) (byText "Reset")).isSome
#guard ((click (Counter.view 0 3) (byText "Reset")).map fun m => (Counter.update 0 m 3).1) == some 0
#guard (click (Counter.view 0 0) (byText "Reset")).isNone

-- Events bubble: one click on Inner sends `.add 1` then `.add 10`.
#guard ((clicks (Nested.view () 0) (byText "Inner")).foldl (fun n m => (Nested.update () m n).1) 0) == 11

-- The todo form: type, submit, toggle, reverse — all through the view.
private def todoStep (m : TodoModel) (msg : Option TodoMsg) : TodoModel :=
  match msg with | some msg => (todoUpdate msg m).1 | none => m

private def afterTyping : TodoModel :=
  let m := (Todos.init ()).1
  let m := todoStep m (typeInto (todoView m) (byLabel "New todo") "Ship P2")
  todoStep m (submit (todoView m))

#guard afterTyping.todos.map (·.title) == ["Write the plan", "Ship P1", "Ship P2"]
#guard afterTyping.draft == ""
#guard (findByRole (todoView afterTyping) "button" (some "Add")).map (·.disabled) == some true
#guard (findByRole (todoView { afterTyping with draft := "x" }) "button" (some "Add")).map (·.disabled) == some false
-- Clicking the checkbox inside "Ship P1"'s label toggles that todo only.
#guard ((findAll (todoView (todoStep afterTyping (click (todoView afterTyping) (byLabel "Ship P1"))))) (byRole "checkbox")).map (·.checked) == [false, true, false]
#guard (findAll (todoView afterTyping) (byRole "listitem")).length == 3
-- Escape in the input clears the draft (and asks to prevent the default).
#guard (keyDown (todoView { afterTyping with draft := "x" }) (byLabel "New todo") "Escape").isSome
#guard (findAll (todoView (todoStep afterTyping (click (todoView afterTyping) (byText "Reverse")))) (byRole "listitem")).map (·.text)
  == ["Ship P2", "Ship P1", "Write the plan"]

-- A snapshot of a small view.
/--
info: <div className="counter">
  <p role="status">
    Count: 2
  </p>
  <button onClick>
    Add one
  </button>
  <button onClick>
    Add 2^53 + 1
  </button>
  <button onClick>
    Reset
  </button>
</div>
-/
#guard_msgs in #eval IO.print ((Counter.view 0 2).pretty)

end Examples.Program.Behavior
