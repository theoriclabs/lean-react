import LeanReact

namespace Examples.Collections
open LeanReact

structure Row where
  id : Nat
  title : String := ""
  detail : String := ""

def required : DraftParser String String :=
  DraftParser.checked DraftParser.identity
    (fun value => if value.isEmpty then Ontology.Validation.fail "required" else .ok value) id

def rowType : Ontology.TypeId := ⟨"examples", "Row"⟩

def rowParser : DraftParser Row Row :=
  let fields := (required.atPath [.field rowType "title"]).product (required.atPath [.field rowType "detail"])
  let parser := (DraftParser.identity : DraftParser Nat Nat).product fields
  ⟨fun row => (parser.parse (row.id, row.title, row.detail)).map
      (fun (id, title, detail) => ⟨id, title, detail⟩), id⟩

def parseRows := (DraftParser.list rowParser).parse

structure RowProps where
  binding : FieldBinding Row
  remove : Action Unit

def RowEditor : Component RowProps := component fun props => do
  let visits ← useState 0 "row-visits"
  let titleBinding := props.binding.focus (Ontology.Lens.field rowType "title" Row.title
    (fun row value => { row with title := value }))
  let detailBinding := props.binding.focus (Ontology.Lens.field rowType "detail" Row.detail
    (fun row value => { row with detail := value }))
  let id := toString props.binding.value.id
  pure <| DOM.article { ariaLabel := some s!"Row {id}" } #[
    DOM.input {
      ariaLabel := some s!"Title {id}"
      placeholder := some "Title"
      value := some titleBinding.value
      onChange := some (fun event => titleBinding.set event.value) },
    DOM.input {
      ariaLabel := some s!"Detail {id}"
      placeholder := some "Detail"
      value := some detailBinding.value
      onChange := some (fun event => detailBinding.set event.value) },
    DOM.button { onPress := some (visits.modify (· + 1)) } #[text s!"Visited {visits.value}"],
    DOM.button { onPress := some props.remove } #[text "Remove row"]]

def CollectionLayout : Component (Element × (Row → Action Unit)) := component fun (children, add) => do
  let nextId ← useCell 3 "next-row-id"
  pure <| DOM.div {} #[children,
    DOM.button { onPress := some do
      let id ← nextId.modifyGet fun id => (id, id + 1)
      add { id } } #[text "Add row"]]

def RowsEditor : Editor (Array Row) := Editor.list (fun row => Key.nat row.id)
  (fun binding remove => element RowEditor ⟨binding, remove⟩)
  (fun children add => element CollectionLayout (children, add))

private def errorText (error : Ontology.ValidationError) : String :=
  let path := error.path.foldl (fun out segment => out ++ match segment with
    | .field _ name | .key name => s!".{name}"
    | .index index => s!"[{index}]"
    | .variant name => s!"<{name}>") ""
  path ++ ": " ++ error.code

def App : Component Unit := component fun _ => do
  let form ← useForm (DraftParser.list rowParser)
    #[⟨1, "Alpha", "First"⟩, ⟨2, "Beta", "Second"⟩] "rows"
  let status ← useState "Not submitted" "submit-status"
  let errors := match form.draft.parsed with
    | .ok _ => #[]
    | .error errors => errors.toList.toArray.map (fun error => DOM.li {} #[text (errorText error)])
  pure <| DOM.div { className := some "collection-example" } #[
    DOM.h2 {} #[text "Collection forms in Lean"],
    element RowsEditor form.binding,
    DOM.button { onPress := some (form.binding.modify
      (fun rows => rows.foldl (fun result row => #[row] ++ result) #[])) } #[text "Reverse rows"],
    DOM.button { onPress := some do
      let result ← form.submit fun rows => status.set s!"Saved {rows.size} rows"
      match result with
      | .error errors => status.set s!"Fix {errors.toList.length} fields"
      | .ok _ => pure () } #[text "Save rows"],
    DOM.ul { ariaLabel := some "Validation errors" } errors,
    DOM.p { role := some "status" } #[text status.value]]

end Examples.Collections
