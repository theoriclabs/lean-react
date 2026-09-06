import LeanReact
import Examples.Tickets.Domain

open LeanReact Ontology Examples.Tickets

namespace P06Examples

-- Reuse the actual Tickets parser. Only its errors are adapted to structured validation.
def titleParser : DraftParser String Title := DraftParser.ofExcept Title.parse Title.value fun error =>
  match error with
  | .empty => ValidationErrors.single "ticket.title.empty"
  | .tooLong length => ValidationErrors.single "ticket.title.tooLong" [] [("length", toString length)]

def TextField : Editor String := component fun field => pure <| DOM.input {
  value := some field.value
  onChange := some fun event => field.set event.value
}

structure EditProps where
  initial : String
  save : Title → Action Unit

structure EditModel where
  form : Form String Title
  submit : Action Unit

def useTitleEditor (props : EditProps) : Hook EditModel := do
  let form ← useForm titleParser props.initial "ticket-title"
  pure { form, submit := do let _ ← form.submit props.save; pure () }

def Compact : Component EditProps := component fun props => do
  let editor ← useTitleEditor props
  pure <| DOM.div {} #[
    element TextField editor.form.binding,
    DOM.button { onPress := some editor.submit } #[text "Save"]
  ]

def Page : Component EditProps := component fun props => do
  let editor ← useTitleEditor props
  let notice := match editor.form.draft.parsed with
    | .ok title => text s!"Ready: {title.value}"
    | .error errors => text errors.first.code
  pure <| DOM.section {} #[
    DOM.h2 {} #[text "Edit ticket"], element TextField editor.form.binding, notice,
    DOM.button { onPress := some editor.submit } #[text "Save"],
    DOM.button { onPress := some editor.form.reset } #[text "Reset"]
  ]

def titleLens : Lens (String × Bool) String := Lens.field ⟨"example", "Draft"⟩ "title"
  Prod.fst (fun draft title => (title, draft.2))

def Composite : Component Unit := component fun _ => do
  let parser := titleParser.product (DraftParser.identity : DraftParser Bool Bool)
  let form ← useForm parser ("", false) "composite"
  pure <| element TextField (form.binding.focus titleLens)

def OptionalText : Editor (Option String) := Editor.optional TextField "" fun model =>
  DOM.div {} #[model.child,
    DOM.button { onPress := some model.enable } #[text "Enable"],
    DOM.button { onPress := some model.clear } #[text "Clear"]]

def textRows (newId : Action String) : Editor (Array (String × String)) := Editor.list
  (fun row => Key.string row.1)
  (fun row remove => DOM.div {} #[
    element TextField (row.focus (Lens.field ⟨"example", "Row"⟩ "text" Prod.snd (fun old value => (old.1, value)))),
    DOM.button { onPress := some remove } #[text "Remove"]])
  (fun rows append => DOM.div {} #[rows,
    DOM.button { onPress := some (do let id ← newId; append (id, "")) } #[text "Append"]])

structure TicketResourceProps where
  scope : String
  revision : Nat
  load : ResourceRequest → Action (Except SaveError (Array TicketSummary))

def TicketResource : Component TicketResourceProps := component fun props => do
  let result ← useResource (Key.inSpace "tickets" props.scope) props.load
    #[.nat props.revision] true "ticket-resource"
  let content := match result.state with
    | .idle => text "Idle"
    | .loading _ => text "Loading"
    | .success _ tickets => text s!"{tickets.size} tickets"
    | .failure _ (.loader .notFound) => text "Missing"
    | .failure _ (.loader (.conflict _)) => text "Changed on the server"
    | .failure _ (.exception message) => text message
  pure <| DOM.div {} #[content,
    DOM.button { onPress := some result.refresh } #[text "Refresh"]]

end P06Examples
