import LeanReact
import LeanReact.Forms
import {{Name}}.Contracts

namespace {{Name}}.UI
open LeanReact

structure AppProps where
  service : NoteService Action

/-- The form keeps the raw draft; `Title.parse` decides when it becomes a value. -/
def titleParser : DraftParser String Title :=
  ⟨fun raw => (Title.parse raw).mapError (fun code => Ontology.ValidationErrors.single code), Title.value⟩

def TitleField : Editor String := Component.named "TitleField" <| component fun binding =>
  pure <| DOM.input {
    id := some "note-title"
    value := some binding.value
    onChange := some (fun event => binding.set event.value) }

def load (service : NoteService Action) (_ : ResourceRequest) : Action (Except String (Array Note)) :=
  service.list

def message : String → String
  | "title.empty" => "Give the note a title."
  | "title.too_long" => "Keep the title under 121 characters."
  | "notes.limit" => "This notebook is full (100 notes)."
  | code => "Something went wrong: " ++ code

def App : Component AppProps := Component.named "{{Name}}App" <| component fun props => do
  let notes ← useResource (Key.string "notes") (load props.service) #[] true "notes"
  let form ← useForm titleParser "" "note-draft"
  let notice ← useState "" "notice"
  let add : Action Unit := do
    let result ← form.submit fun title => do
      match ← props.service.add title with
      | .ok _ =>
        notice.set "Note added."
        form.reset
        notes.refresh
      | .error code => notice.set (message code)
    match result with
    | .ok _ => pure ()
    | .error errors => notice.set (message errors.first.code)
  let listing := match notes.state with
    | .idle => empty
    | .loading _ => DOM.p {} #[text "Loading…"]
    | .failure _ (.loader code) => DOM.p { role := some "alert" } #[text (message code)]
    | .failure _ (.call .unauthenticated) => DOM.p { role := some "alert" } #[text "Sign in first."]
    | .failure _ (.call failure) => DOM.p { role := some "alert" } #[text ("Request failed: " ++ failure.code)]
    | .failure _ (.exception detail) => DOM.p { role := some "alert" } #[text ("Unexpected: " ++ detail)]
    | .success _ items =>
      if items.isEmpty then DOM.p { className := some "empty" } #[text "No notes yet."]
      else DOM.ul { className := some "notes" } (items.map fun note => DOM.li {} #[text note.title])
  pure <| DOM.div { className := some "panel" } #[
    DOM.h1 {} #[text "Notes"],
    DOM.label { htmlFor := "note-title" } #[text "New note"],
    element TitleField form.binding,
    DOM.div { className := some "controls" } #[
      DOM.button { className := some "primary", onPress := some add } #[text "Add note"]],
    DOM.p { role := some "status" } #[text notice.value],
    listing]

end {{Name}}.UI
