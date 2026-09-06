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
  IO.println "LeanReact reference checks passed (state/actions, hooks, effects, context, callbacks, slots, keys)."
