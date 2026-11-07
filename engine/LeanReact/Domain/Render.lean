import LeanReact.Domain.Drafts
import LeanReact.DOM

/-! # Views derived from a type's wire description

Forms derive one editor per field from an operation's input codec. `render` is the mirror for
output: any type with a wire codec (every `Domain` type, its records, enums, lists and
references) gets a default view, so a page can show what an endpoint returns without a
bespoke view.

```
def bookPage (book : Ref Book) : Element :=
  load (api.getBook book) (onError := …) render

def booksPage : Element :=
  load api.books (onError := nofun) (renderWith {
    refPath := fun type id => if type.name == "Book" then some s!"/books/{id}" else none
    types := [RenderConfig.type fun (price : Money) => text price.display]
    fields := [RenderConfig.field "summary" fun (summary : Text) => DOM.p {} #[text summary.value]] })
```

* A record is a description list (`dl`): a `dt` label and a `dd` value per field.
* A list of records is a table, one column per field; another list is a `ul`.
* A payload-free variant is its label; a variant with a payload is its label then the payload.
* A reference is a link to `refPath` (text when `refPath` gives `none`); an `Instant` is UTC
  text (`2026-10-17 19:00 UTC`); `Bool` is Yes/No; `none` is an em dash.
* `RenderConfig.type` overrides every value of a named type (a record or enum, by its wire
  identity); `RenderConfig.field` overrides one field name in every record. A `Render`
  instance overrides `render` for a whole type at the top level.

Labels come from field and constructor names: `dueDate` reads "Due date". -/

namespace LeanReact.Domain
open LeanDb.Model Ontology LeanReact

/-- How `renderWith` shows values. Overrides receive the value's wire form and decode it with
the type's codec (`RenderConfig.type`, `RenderConfig.field`), so they stay typed. -/
structure RenderConfig where
  /-- Per named type, by wire identity. -/
  types : List (TypeId × (Lean.Json → Option Element)) := []
  /-- Per field name, in every record. -/
  fields : List (String × (Lean.Json → Option Element)) := []
  /-- The page of a reference: its target type and id; `none` shows it as text. -/
  refPath : TypeId → String → Option String := fun _ _ => none

/-- Every value of `α` (a named type: a record, enum or other `.named` codec) shown by `view`. -/
def RenderConfig.type [Wire α] (view : α → Element) : TypeId × (Lean.Json → Option Element) :=
  let codec := Wire.codec (α := α)
  let identity := match codec.schema with | .named identity _ _ => identity | _ => ⟨"", ""⟩
  (identity, fun json => match codec.decode json with | .ok value => some (view value) | .error _ => none)

/-- Every field called `name` whose value decodes as `α` shown by `view`. -/
def RenderConfig.field [Wire α] (name : String) (view : α → Element) : String × (Lean.Json → Option Element) :=
  (name, fun json => match (Wire.codec (α := α)).decode json with | .ok value => some (view value) | .error _ => none)

/-- `dueDate` → `Due date`, `hostOnly` → `Host only`. -/
def humanize (name : String) : String :=
  let words := name.toList.foldl (fun (out : List Char) c =>
    if c.isUpper && !out.isEmpty then c.toLower :: ' ' :: out else c :: out) []
  match words.reverse with
  | [] => ""
  | first :: rest => String.ofList (first.toUpper :: rest)

private def scalarText (json : Lean.Json) : String :=
  match json with
  | .str text => text
  | .num number => if number.exponent == 0 then toString number.mantissa else "?"
  | .bool value => if value then "Yes" else "No"
  | .null => "—"
  | .obj _ => match json.getObjVal? "value" with
    | .ok (.str text) => text
    | _ => "?"
  | .arr _ => "?"

private def isReference (version : String) : Bool := version == "ref/2" || version == "entity-id/1"

private def referenceId (json : Lean.Json) : String :=
  match json with
  | .obj _ => match json.getObjVal? "id" with | .ok value => scalarText value | .error _ => scalarText json
  | _ => scalarText json

private def instantText (json : Lean.Json) : String :=
  match json with
  | .str raw => match parseRfc3339? raw >>= (Instant.ofEpochSeconds · |>.toOption) with
    | some instant => instant.format
    | none => raw
  | other => scalarText other

private def recordFields : WireSchema → Option (List (String × WireSchema))
  | .named _ version body => if isReference version then none else recordFields body
  | .record fields => some fields
  | _ => none

private theorem fieldSmaller (entry : String × WireSchema) : sizeOf entry.2 < sizeOf entry := by
  rcases entry with ⟨name, schema⟩
  simp +arith

/-- The view of `json`, described by `schema`. With `row`, a record is a fragment of table
cells (`td`), for the rows of a table of records. -/
def renderWire (config : RenderConfig) (row : Bool) (schema : WireSchema) (json : Lean.Json) : Element :=
  match schema with
  | .named identity version body =>
    match config.types.lookup identity >>= (· json) with
    | some custom => if row then DOM.td { colSpan := (recordFields body).map (·.length) } #[custom] else custom
    | none =>
      if isReference version then
        let id := referenceId json
        let label := text (humanize identity.name ++ " " ++ id)
        match config.refPath identity id with
        | some href => DOM.a { href } #[label]
        | none => DOM.span {} #[label]
      else if version == "rfc3339/1" then DOM.span {} #[text (instantText json)]
      else renderWire config row body json
  | .record fields =>
    let cells := fields.attach.toArray.map fun entry =>
      let value := (json.getObjVal? entry.val.1).toOption.getD .null
      (entry.val.1, (config.fields.lookup entry.val.1 >>= (· value)).getD (renderWire config false entry.val.2 value))
    if row then fragment (cells.map fun (_, shown) => DOM.td {} #[shown])
    else DOM.dl {} (cells.flatMap fun (name, shown) => #[DOM.dt {} #[text (humanize name)], DOM.dd {} #[shown]])
  | .variant cases =>
    let (tag, payload) := match json with
      | .str tag => (tag, Lean.Json.null)
      | other => (scalarText ((other.getObjVal? "tag").toOption.getD .null), (other.getObjVal? "value").toOption.getD .null)
    match cases.attach.find? (·.val.1 == tag) with
    | some entry =>
      match entry.val.2 with
      | .unit => DOM.span {} #[text (humanize tag)]
      | _ => DOM.div {} #[DOM.span {} #[text (humanize tag)], renderWire config false entry.val.2 payload]
    | none => DOM.span {} #[text (humanize tag)]
  | .option inner =>
    -- `{"tag":"none"}` or `{"tag":"some","value":…}` (`null` is read as `none` too).
    match json.getObjVal? "value", json.getObjVal? "tag" with
    | .ok value, .ok (.str "some") => renderWire config row inner value
    | _, _ => if row then DOM.td {} #[text "—"] else DOM.span {} #[text "—"]
  | .list item | .array item =>
    let items := match json with | .arr values => values | _ => #[]
    match recordFields item with
    | some fields =>
      DOM.table {} #[
        DOM.thead {} #[DOM.tr {} (fields.toArray.map fun (name, _) => DOM.th {} #[text (humanize name)])],
        DOM.tbody {} (items.map fun value => DOM.tr {} #[renderWire config true item value])]
    | none => DOM.ul {} (items.map fun value => DOM.li {} #[renderWire config false item value])
  | .product left right =>
    let values := match json with | .arr values => values | _ => #[]
    DOM.span {} #[renderWire config false left (values[0]?.getD .null), text ", ",
      renderWire config false right (values[1]?.getD .null)]
  | .map _ value =>
    let entries : List (String × Lean.Json) := match json with
      | .arr values => values.toList.map fun entry => match entry with
        | .arr pair => (scalarText (pair[0]?.getD .null), pair[1]?.getD .null)
        | other => ("?", other)
      | .obj values => values.toList
      | _ => []
    DOM.dl {} (entries.toArray.flatMap fun (key, entry) =>
      #[DOM.dt {} #[text key], DOM.dd {} #[renderWire config false value entry]])
  | .unit => empty
  | .ref identity =>
    let id := referenceId json
    let label := text (humanize identity.name ++ " " ++ id)
    match config.refPath identity id with
    | some href => DOM.a { href } #[label]
    | none => DOM.span {} #[label]
  | .boolean | .string | .natural | .integer => DOM.span {} #[text (scalarText json)]
termination_by sizeOf schema
decreasing_by
  all_goals simp_wf
  all_goals first
    | omega
    | have small := List.sizeOf_lt_of_mem entry.property
      have part := fieldSmaller entry.val
      omega

/-- A value's default view, with overrides. -/
def renderWith [Wire α] (config : RenderConfig) (value : α) : Element :=
  let codec := Wire.codec (α := α)
  renderWire config false codec.schema (codec.encode value)

/-- How a type is shown by `render`: the derived view unless an instance says otherwise
(`instance : Render Money := ⟨fun m => text m.display⟩`). -/
class Render (α : Type) where
  render : α → Element

instance (priority := low) [Wire α] : Render α := ⟨renderWith {}⟩

/-- The default view of `value` (a `Render` instance, else derived from its wire codec). -/
def render [Render α] (value : α) : Element := Render.render value

end LeanReact.Domain
