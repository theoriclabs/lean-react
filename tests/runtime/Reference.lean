import LeanReact

open LeanReact

private def assertTrue (condition : Bool) (message : String) : IO Unit :=
  unless condition do throw <| IO.userError message

structure TestTheme where
  name : String
  deriving TypeName

def theme : Context TestTheme := createContext "tests.theme" { name := "default" }

def ThemeText : Component Unit := component fun _ => do
  let value ← useContext theme (site := "theme")
  pure <| text value.name

structure WidgetOps where
  draw : Array Nat → Action (HandleResult Nat)

partial def firstPress : RenderedTree → Option (Action Unit)
  | .text _ => none
  | .node _ attributes children =>
    (attributes.findSome? fun attr => match attr with | .press callback => some (callback {}) | _ => none)
      |>.orElse fun _ => children.findSome? firstPress
  | .fragment children => children.findSome? firstPress
  | .keyed _ child | .child _ _ child => firstPress child

def main : IO Unit := do
  let state ← Reference.runHook (useState (0 : Nat) (site := "counter"))
  let increment := state.value.modify (· + 1)
  assertTrue ((← Reference.runAction state.value.read) == 0) "action construction mutated state"
  Reference.runAction increment
  Reference.runAction increment
  assertTrue ((← Reference.runAction state.value.read) == 2) "functional updates lost a change"
  assertTrue (state.value.value == 0) "render snapshot should remain immutable"
  assertTrue (state.trace == #[⟨"state", "counter"⟩]) "state hook trace"
  assertTrue (match validateHookTrace state.trace #[] with | .error _ => true | .ok _ => false) "changed hook trace accepted"

  let log ← IO.mkRef (#[] : Array String)
  let setup : String → Action (Action Unit) := fun name => ⟨do
    log.modify (·.push s!"setup:{name}")
    pure ⟨log.modify (·.push s!"cleanup:{name}")⟩⟩
  let prepared ← Reference.runHook do
    useEffect #[] (setup "one") (site := "one")
    useEffect #[] (setup "two") (site := "two")
  assertTrue ((← log.get).isEmpty) "effects executed during prepare"
  let dispose ← prepared.commit
  assertTrue ((← log.get) == #["setup:one", "setup:two"]) "commit setup order"
  Reference.runAction dispose
  Reference.runAction dispose
  assertTrue ((← log.get) == #["setup:one", "setup:two", "cleanup:two", "cleanup:one"]) "cleanup order/idempotence"

  log.set #[]
  let failing ← Reference.runHook do
    useEffect #[] (setup "acquired")
    useEffect #[] ⟨throw <| IO.userError "setup failed"⟩
  let mut rejected := false
  try let _ ← failing.commit catch _ => rejected := true
  assertTrue rejected "failing setup was accepted"
  assertTrue ((← log.get) == #["setup:acquired", "cleanup:acquired"]) "partial setup leaked resource"

  let scopedTree ← Reference.render <| fragment #[
    element ThemeText (),
    provide theme { name := "outer" } <| fragment #[
      element ThemeText (), provide theme { name := "inner" } (element ThemeText ())
    ], element ThemeText ()
  ]
  assertTrue (Reference.RenderedTree.textContent scopedTree.value == "defaultouterinnerdefault") "context scoping"

  let calls ← IO.mkRef (#[] : Array String)
  let child : Component (String × (String → Action Unit) × (String → Element)) := component fun (name, emit, slot) => do
    let _ ← useState (0 : Nat) (site := "child")
    pure <| DOM.button { onPress := some (emit name) } #[slot name]
  let emit := fun name => Action.ofIO (calls.modify (·.push name))
  let tree := element child ("captured", emit, fun name => text s!"slot:{name}")
  assertTrue ((← calls.get).isEmpty) "element construction invoked callback"
  let result ← Reference.render tree
  assertTrue ((← calls.get).isEmpty) "render invoked event action"
  assertTrue result.trace.isEmpty "child hooks leaked into parent trace"
  assertTrue (Reference.RenderedTree.textContent result.value == "slot:captured") "render prop lost its closure"
  match firstPress result.value with
  | none => throw <| IO.userError "missing press handler"
  | some press => Reference.runAction press
  assertTrue ((← calls.get) == #["captured"]) "event lost captured callback value"

  let list ← Reference.render <| keyedEach #[1, 2, 3] Key.nat (fun n => text (toString n))
  assertTrue (Reference.RenderedTree.textContent list.value == "123") "keyed reference content"
  assertTrue (Key.inSpace "a:b" "c" != Key.inSpace "a" "b:c") "key namespace collision"
  let mut duplicateRejected := false
  try
    let _ ← Reference.render <| keyedEach #[1, 1] Key.nat (fun n => text (toString n))
  catch _ => duplicateRejected := true
  assertTrue duplicateRejected "duplicate sibling keys accepted"

  -- Typed form surface: the reference renderer records the new attributes and dispatches their events.
  let submitted ← IO.mkRef (#[] : Array String)
  let nameError ← IO.mkRef ""
  let kept ← IO.mkRef false
  let legacyPresses ← IO.mkRef 0
  let formTree ← Reference.render <| DOM.form { onSubmit := Action.ofIO (submitted.modify (·.push "sent")) } #[
    DOM.input {
      id := some "name", tabIndex := some 0, data := #[("testid", "name")], autoComplete := some "name",
      onBlur := some fun event => Action.ofIO (nameError.set (if event.value.isEmpty then "required" else "")) },
    DOM.select { id := some "topic", value := some "a" } #[DOM.option { value := "a" } #[text "Topic A"]],
    DOM.textarea {
      id := some "message", rows := some 3, style := #[(.resize, "vertical")],
      onKeyDown := some fun event => Action.ofIO do
        if event.ctrl && event.key == "s" then kept.set true; pure .preventDefault else pure .continue },
    -- An `Action Unit` handler still type-checks as a key handler and records `.continue`.
    DOM.div { id := some "legacy", onKeyDown := some fun _ => Action.ofIO (legacyPresses.modify (· + 1)) } #[],
    DOM.button { type := .submit } #[text "Send"]]
  let some formAttributes := Reference.RenderedTree.byTag? formTree.value "form" | throw <| IO.userError "missing form"
  Reference.dispatchSubmit formAttributes
  assertTrue ((← submitted.get) == #["sent"]) "form submit handler"
  let some nameAttributes := Reference.RenderedTree.byTestId? formTree.value "name" | throw <| IO.userError "missing data-testid"
  assertTrue (Reference.attribute? nameAttributes "tabIndex" == some "0") "tabIndex recorded"
  assertTrue (Reference.attribute? nameAttributes "autoComplete" == some "name") "autoComplete recorded"
  Reference.dispatchBlur nameAttributes
  assertTrue ((← nameError.get) == "required") "blur validation"
  Reference.dispatchBlur nameAttributes { value := "Ada" }
  assertTrue ((← nameError.get) == "") "blur validation cleared"
  assertTrue ((Reference.RenderedTree.byTag? formTree.value "option").isSome && Reference.RenderedTree.textContent formTree.value == "Topic ASend") "select options rendered"
  let some messageAttributes := Reference.RenderedTree.byId? formTree.value "message" | throw <| IO.userError "missing textarea"
  assertTrue (Reference.attribute? messageAttributes "rows" == some "3") "rows recorded"
  assertTrue (messageAttributes.any fun attr => match attr with | .style entries => entries == #[("resize", "vertical")] | _ => false) "style recorded"
  assertTrue ((← Reference.dispatchKeyDown messageAttributes { key := "s", ctrl := true }) == .preventDefault) "Ctrl+S recorded as preventDefault"
  assertTrue (← kept.get) "key handler action ran"
  assertTrue ((← Reference.dispatchKeyDown messageAttributes { key := "s" }) == .continue) "plain key continues"
  let some legacyAttributes := Reference.RenderedTree.byId? formTree.value "legacy" | throw <| IO.userError "missing legacy node"
  assertTrue ((← Reference.dispatchKeyDown legacyAttributes { key := "a" }) == .continue) "Action Unit key handler continues"
  assertTrue ((← legacyPresses.get) == 1) "Action Unit key handler ran"

  -- Foreign handles: commit hands `onReady` a Handle over caller-supplied stubs; dispose runs `onGone`.
  let draws ← IO.mkRef (#[] : Array (Array Nat))
  let lifecycle ← IO.mkRef (#[] : Array String)
  let received ← IO.mkRef (none : Option (Handle WidgetOps))
  let stubs : WidgetOps := {
    draw := fun points => Action.ofIO do draws.modify (·.push points); pure (.ok points.size)
  }
  let widget := foreign "widget" {
    props := "chart"
    onReady := fun handle => Action.ofIO do received.set (some handle); lifecycle.modify (·.push "ready")
    onGone := Action.ofIO (lifecycle.modify (·.push "gone"))
    reference := { render := fun title => text s!"[{title}]", ops := some fun _ => stubs }
  }
  let prepared ← Reference.render widget
  assertTrue (Reference.RenderedTree.textContent prepared.value == "[chart]") "foreign reference render"
  assertTrue (← received.get).isNone "onReady ran before commit"
  let dispose ← prepared.commit
  let some handle := ← received.get | throw <| IO.userError "onReady did not deliver a handle"
  assertTrue (← Reference.runAction handle.alive) "handle alive after commit"
  assertTrue ((← Reference.runAction (handle.ops.draw #[1, 2, 3])) == .ok 3) "stub op result"
  assertTrue ((← draws.get) == #[#[1, 2, 3]]) "stub op recorded"
  Reference.runAction dispose
  assertTrue (!(← Reference.runAction handle.alive)) "handle dead after dispose"
  assertTrue ((← lifecycle.get) == #["ready", "gone"]) "foreign lifecycle order"
  let silent ← Reference.render (foreign "widget" { props := (), onReady := fun (_ : Handle WidgetOps) => pure () })
  assertTrue silent.effects.isEmpty "foreign without stubs queued an effect"
  IO.println "LeanReact reference checks passed (state/actions, hooks, effects, context, callbacks, slots, keys, forms, handles)."
