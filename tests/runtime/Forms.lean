import LeanReact
import Examples.Tickets.Domain

open LeanReact Ontology Examples.Tickets

private instance : Inhabited ValidationError := ⟨{ code := "missing-test-error" }⟩

private def check (condition : Bool) (message : String) : IO Unit :=
  unless condition do throw <| IO.userError message

private def titleParser : DraftParser String Title :=
  DraftParser.ofExcept Title.parse Title.value fun error =>
    match error with
    | .empty => ValidationErrors.single "title.empty"
    | .tooLong length => ValidationErrors.single "title.tooLong" [] [("length", toString length)]

private def rawTitle : Lens (String × Nat) String :=
  Lens.field ⟨"tests", "Draft"⟩ "title" Prod.fst (fun raw value => (value, raw.2))
private def rawCount : Lens (String × Nat) Nat :=
  Lens.field ⟨"tests", "Draft"⟩ "count" Prod.snd (fun raw value => (raw.1, value))

private def errorsOf : Validation α → List ValidationError
  | .ok _ => [] | .error errors => errors.toList

private def TextEditor : Editor String := component fun binding => pure <| DOM.input {
  value := some binding.value
  onChange := some fun event => binding.set event.value
}

private def OptionalText : Editor (Option String) := Editor.optional TextEditor "new" fun model =>
  fragment #[model.child, DOM.button { onPress := some model.enable } #[text "enable"],
    DOM.button { onPress := some model.clear } #[text "clear"]]

private def RowEditor : Editor (Array (String × String)) := Editor.list
  (fun row => Key.string row.1)
  (fun field remove => DOM.div {} #[
    element TextEditor (field.focus (Lens.field ⟨"tests", "Row"⟩ "value" Prod.snd (fun row value => (row.1, value)))),
    DOM.button { onPress := some remove } #[text "remove"]])
  (fun rows append => fragment #[rows, DOM.button { onPress := some (append ("new", "")) } #[text "append"]])

partial def presses : RenderedTree → Array (Action Unit)
  | .text _ => #[]
  | .node _ attributes children =>
    (attributes.filterMap fun attr => match attr with | .press handler => some (handler {}) | _ => none) ++
      children.foldl (fun actions child => actions ++ presses child) #[]
  | .fragment children => children.foldl (fun actions child => actions ++ presses child) #[]
  | .keyed _ child | .child _ _ child => presses child

private def runPress (controls : Array (Action Unit)) (index : Nat) : IO Unit :=
  match controls[index]? with
  | none => throw <| IO.userError "missing editor action"
  | some work => Reference.runAction work

private def useTitle (initial : String) := useForm titleParser initial "title-form"
private def Compact : Component String := component fun initial => do
  let form ← useTitle initial
  pure <| element TextEditor form.binding
private def Wide : Component String := component fun initial => do
  let form ← useTitle initial
  pure <| DOM.div {} #[DOM.h2 {} #[text form.draft.raw], element TextEditor form.binding]

def main : IO Unit := do
  let invalid := Draft.create titleParser ""
  check (invalid.raw == "" && (errorsOf invalid.parsed).length == 1) "invalid input was discarded"
  let long := String.ofList (List.replicate 201 'x')
  let tooLong := Draft.create titleParser long
  check (tooLong.raw == long) "long raw text was rewritten"
  check ((errorsOf tooLong.parsed).head!.code == "title.tooLong") "typed domain parse error mapping"
  let pairParser := titleParser.atPath rawTitle.identity |>.product (titleParser.atPath [.key "second"])
  let pairErrors := errorsOf (pairParser.parse ("", ""))
  check (pairErrors.length == 2) "independent fields did not accumulate errors"
  check (pairErrors[0]!.path == rawTitle.identity && pairErrors[1]!.path == [.key "second"]) "field error paths"
  check ((match titleParser.optional.parse none with | .ok none => true | _ => false)) "absent optional is invalid"
  check ((errorsOf (titleParser.optional.parse (some ""))).length == 1) "present invalid optional accepted"
  let listErrors := errorsOf (titleParser.list.parse #["", "valid", ""])
  check (listErrors.length == 2 && listErrors[0]!.path == [.index 0] && listErrors[1]!.path == [.index 2]) "indexed list errors"
  check ((match (titleParser.map Title.value Title.mk).parse "valid" with | .ok value => value == "valid" | _ => false)) "parser map"
  let checked := titleParser.checked (fun title => if title.value == "reserved" then Validation.fail "reserved" else .ok title) id
  check ((errorsOf (checked.parse "reserved")).head!.code == "reserved") "dependent parser check"

  let raw ← Reference.runHook (useState ("first", 0))
  let fields := FieldBinding.ofState raw.value
  let title := fields.focus rawTitle
  let count := fields.focus rawCount
  Reference.runAction (count.modify (· + 1))
  Reference.runAction (title.set "changed")
  check ((← raw.value.read.runIO) == ("changed", 1)) "focused update overwrote a sibling"
  let nested ← Reference.runHook (useState (("old", 0), true))
  let outer : Lens ((String × Nat) × Bool) (String × Nat) := Lens.field ⟨"tests", "Outer"⟩ "inner" Prod.fst (fun raw value => (value, raw.2))
  Reference.runAction (((FieldBinding.ofState nested.value).focus (outer.comp rawTitle)).set "nested")
  check ((← nested.value.read.runIO) == (("nested", 0), true)) "composed lens lost outer fields"
  let mapped := count.map (fun n => (n, ())) Prod.fst
  Reference.runAction (mapped.modify (fun pair => (pair.1 + 2, ())))
  check ((← raw.value.read.runIO).2 == 3) "mapped field modify used stale snapshot"

  let form ← Reference.runHook (useTitle "initial")
  let submitted ← IO.mkRef (#[] : Array String)
  let save := fun title => Action.ofIO (submitted.modify (·.push title.value))
  Reference.runAction (form.value.binding.set "")
  let failure ← Reference.runAction (form.value.submit save)
  check ((errorsOf failure).length == 1 && (← submitted.get).isEmpty) "invalid form was submitted"
  check ((← form.value.read.runIO).raw == "") "failed validation replaced the raw draft"
  Reference.runAction (form.value.binding.set "ready")
  let _ ← Reference.runAction (form.value.submit save)
  check ((← submitted.get) == #["ready"]) "submit did not parse current input"
  Reference.runAction form.value.reset
  check ((← form.value.read.runIO).raw == "initial") "form reset"
  let _ ← Reference.render (fragment #[element Compact "one", element Wide "two"])

  let optional ← Reference.runHook (useState (some "before"))
  let binding := FieldBinding.ofState optional.value
  let some child := binding.present | throw <| IO.userError "missing optional field"
  Reference.runAction (binding.set none)
  Reference.runAction (child.set "late")
  check ((← optional.value.read.runIO).isNone) "late optional callback resurrected removed data"
  let optionalView ← Reference.render (element OptionalText { binding with value := none })
  let controls := presses optionalView.value
  runPress controls 0
  runPress controls 0
  check ((← optional.value.read.runIO) == some "new") "optional enable"
  runPress controls 1
  check ((← optional.value.read.runIO).isNone) "optional clear"

  let rows ← Reference.runHook (useState #[("a", "A"), ("b", "B")])
  let list := FieldBinding.ofState rows.value
  let keyOf := fun row : String × String => Key.string row.1
  let some rowA := list.item keyOf (Key.string "a") | throw <| IO.userError "row binding missing"
  Reference.runAction (rows.value.modify Array.reverse)
  Reference.runAction (rowA.modify (fun row => (row.1, "edited")))
  check ((← rows.value.read.runIO) == #[("b", "B"), ("a", "edited")]) "row binding followed index instead of key"
  let rowsView ← Reference.render (element RowEditor list)
  runPress (presses rowsView.value) 0
  Reference.runAction (rowA.set ("a", "late"))
  check ((← rows.value.read.runIO) == #[("b", "B")]) "removed row resurrected by old callback"
  runPress (presses rowsView.value) 2
  check ((← rows.value.read.runIO) == #[("b", "B"), ("new", "")]) "list append lost current edits"
  IO.println "P06 form checks passed (domain parsers, raw drafts, paths, bindings, optional/list editors, forms, layouts)."
