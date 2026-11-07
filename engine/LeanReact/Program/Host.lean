import LeanReact.Program.Component
import LeanReact.Cell
import LeanJS.StackSafe

/-! # The host: a `Component` as a React element

One generic hook component runs every program:
* the model lives in one cell (the latest value) mirrored into one state slot (for rendering);
* `dispatch msg` applies `update` to the latest model at once, so two dispatches in one event
  see each other, then commits and queues the command;
* queued commands run after the commit, in order, and their messages re-enter `dispatch`;
* nothing runs `update` during render, so StrictMode's double renders never repeat it;
* `Html` becomes elements: events decode their payload in Lean and dispatch `some msg`, keyed
  children become React keys (a duplicate key throws), and an embedded child is mounted with
  the parent's dispatch. -/

namespace LeanReact.Program

private def send (dispatch : Msg → Action Unit) : Option Msg → Action Unit
  | some msg => dispatch msg
  | Option.none => pure ()

/-- One attribute, its events dispatching through `dispatch`. Class names are merged by `node`. -/
def Attr.toAttributes (dispatch : Msg → Action Unit) : Attr Msg → Array Attribute
  | .attr name value => if name == "className" then #[] else #[.string name value]
  | .bool name value => #[.bool name value]
  | .style entries => #[.style entries.toArray]
  | .styles _ => #[]
  | .onPress decode => #[.press fun e => send dispatch (decode e)]
  | .onInput decode => #[.input fun e => send dispatch (decode e)]
  | .onChange decode => #[.change fun e => send dispatch (decode e)]
  | .onKeyDown decode prevent => #[.keyDown fun e => do
      send dispatch (decode e)
      pure (if prevent e then KeyOutcome.preventDefault else KeyOutcome.continue)]
  | .onFocus decode => #[.focus fun e => send dispatch (decode e)]
  | .onBlur decode => #[.blur fun e => send dispatch (decode e)]
  | .onSubmit msg => #[.submit (dispatch msg)]

private def classes : Attr Msg → List String
  | .attr "className" value => [value]
  | .styles values => values.map Style.className
  | _ => []

/-- All attributes; `cls` and `styled` become one `className`. -/
def attributes (dispatch : Msg → Action Unit) (attrs : List (Attr Msg)) : Array Attribute :=
  let names := attrs.flatMap classes
  (if names.isEmpty then #[] else #[Attribute.string "className" (" ".intercalate names)]) ++
    (attrs.toArray.flatMap (Attr.toAttributes dispatch))

/-- The elements of a view. -/
@[leanjs_stack_safe] def Html.toElement (dispatch : Msg → Action Unit) : Html Msg → Element
  | .text value => LeanReact.text value
  | .node tag attrs children =>
    let elements := children.map fun child => (child.key?, Html.toElement dispatch child)
    LeanReact.node tag (attributes dispatch attrs) <|
      if elements.any (·.1.isSome) then
        -- Keyed siblings (from `each`): one keyed list, which rejects a duplicate key.
        #[keyedEach (elements.zipIdx.toArray) (fun ((key, _), i) => Key.string (key.getD s!"#{i}")) (·.1.2)]
      else elements.toArray.map (·.2)
  | .keyed _ child => Html.toElement dispatch child
  | .embed child => LeanReact.keyed (Key.inSpace "embed" child.key) (child.mount dispatch)
  | .lazy key view => LeanReact.keyed (Key.inSpace "lazy" key) (Html.toElement dispatch (view ()))
  | .none => LeanReact.empty

/-- What the host component receives. -/
structure HostProps (Props Model Msg : Type) where
  component : Component Props Model Msg
  props : Props
  /-- Every message also goes here (a parent's mapping, or `pure ()`). -/
  onMsg : Msg → Action Unit
  /-- When set, a change of this text dispatches `component.propsChanged`. -/
  propsKey : Option String

mutual
@[leanjs_stack_safe] private def run (dispatch : Msg → Action Unit) : Cmd Msg → Action Unit
  | .none => pure ()
  | .batch commands => runAll dispatch commands
  | .task work => do if let some msg ← work then dispatch msg

/-- Start each command in order without waiting for it (a timer must not hold up the next). -/
@[leanjs_stack_safe] private def runAll (dispatch : Msg → Action Unit) : List (Cmd Msg) → Action Unit
  | [] => pure ()
  | cmd :: rest => do Effects.spawn (run dispatch cmd); runAll dispatch rest
end

/-- Run each stop action (sources are few: bounded by the subscriptions' shape). -/
@[leanjs_stack_safe] private def stopAll : List (String × Action Unit) → Action Unit
  | [] => pure ()
  | (_, stop) :: rest => do stop; stopAll rest

/-- Start the wanted sources whose key is not in `running`, returning `running` extended. -/
@[leanjs_stack_safe] private def startNew {Msg : Type} (dispatch : Msg → Action Unit) (running : List (String × Action Unit)) :
    List (String × ((Msg → Action Unit) → Action (Action Unit))) → Action (List (String × Action Unit))
  | [] => pure running
  | (key, start) :: rest => do
    if running.any (·.1 == key) then startNew dispatch running rest
    else
      let stop ← start dispatch
      startNew dispatch (running ++ [(key, stop)]) rest

/-- Stop running sources whose key is gone; start wanted ones that are not running. -/
private def reconcile {Msg : Type} (dispatch : Msg → Action Unit) (running : Cell (List (String × Action Unit)))
    (wanted : List (String × ((Msg → Action Unit) → Action (Action Unit)))) : Action Unit := do
  let current ← running.read
  stopAll (current.filter fun (key, _) => !wanted.any (·.1 == key))
  let next ← startNew dispatch (current.filter fun (key, _) => wanted.any (·.1 == key)) wanted
  let _ ← running.modifyGet fun _ => ((), next)

/-- The one host component every program runs in. -/
def host : LeanReact.Component (HostProps Props Model Msg) :=
  LeanReact.Component.named "stable:LeanReact.Program.Host" <| LeanReact.component fun hp => do
    let initial := hp.component.init hp.props
    let model ← useState initial.1 "program.model"
    let latest ← useCell initial.1 "program.latest"
    let queue ← useCell #[initial.2] "program.queue"
    let mounted ← useCell false "program.mounted"
    let queued ← useState (0 : Nat) "program.queued"
    let lastKey ← useCell (Option.none : Option String) "program.propsKey"
    let sources ← useCell ([] : List (String × Action Unit)) "program.sources"
    let dispatch : Msg → Action Unit := fun msg => do
      if !(← mounted.read) then return
      let (next, cmd) ← latest.modifyGet fun current =>
        let step := hp.component.update hp.props msg current
        (step, step.1)
      model.set next
      let _ ← queue.modifyGet fun pending => ((), pending.push cmd)
      queued.modify (· + 1)
      hp.onMsg msg
    useEffect #[] (do
      let _ ← mounted.modifyGet fun _ => ((), true)
      pure (do
        let _ ← mounted.modifyGet fun _ => ((), false)
        -- Unmounting stops every source.
        let running ← sources.modifyGet fun running => (running, [])
        stopAll running)) "program.lifetime"
    -- After each commit that queued commands: run them in order, then bring the subscriptions in
    -- line with the committed model.
    useEffect #[.nat queued.value, .string (hp.propsKey.getD "")] (do
      let pending ← queue.modifyGet fun pending => (pending, #[])
      runAll dispatch pending.toList
      reconcile dispatch sources (hp.component.subscriptions hp.props (← latest.read)).sources
      pure (pure ())) "program.commands"
    -- A changed `propsKey` (not the first one) dispatches `propsChanged`.
    useEffect #[.string (hp.propsKey.getD "")] (do
      let previous ← lastKey.modifyGet fun previous => (previous, hp.propsKey)
      if previous.isSome && previous != hp.propsKey then
        if let some toMsg := hp.component.propsChanged then dispatch (toMsg hp.props)
      pure (pure ())) "program.props"
    pure (Html.toElement dispatch (hp.component.view hp.props model.value))

/-- A program inside a hook-based tree. `onMsg` sees every message the program handles. -/
def Component.toElement (c : Component Props Model Msg) (props : Props)
    (onMsg : Msg → Action Unit := fun _ => pure ()) (propsKey : Option String := Option.none) : Element :=
  LeanReact.element host { component := c, props, onMsg, propsKey }

/-- A child program inside a parent's view: the child's messages go through `toParent` to the
parent's `update`; `key` identifies the child among its siblings. -/
def Component.embed (c : Component Props Model ChildMsg) (props : Props) (toParent : ChildMsg → Option Msg)
    (key : String := "child") : Html Msg :=
  .embed { key, mount := fun dispatch => c.toElement props fun msg => send dispatch (toParent msg) }

end LeanReact.Program
