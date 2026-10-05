import LeanReact.Domain.Drafts
import LeanReact.Resources
import LeanContract.Operation
import LeanReact.DOM
import LeanReact.Cell
import LeanReact.Domain.DateInput

namespace LeanReact.Domain
open LeanDb.Model Ontology

structure Feedback (Input : Type) [HasRecord Input] where
  fields : List ((HasRecord.record (T := Input)).Field × String) := []
  message : Option String := none
  navigation : Option String := none

def fieldError [HasRecord I] (field : (HasRecord.record (T := I)).Field) (message : String) : Feedback I :=
  { fields := [(field, message)] }
def fieldErrorNamed [HasRecord I] (name : String) [NamedField I name] (message : String) : Feedback I :=
  fieldError (NamedField.field name) message

def notice [HasRecord I] (message : String) : Feedback I := { message := some message }
def go [HasRecord I] (path : String) : Feedback I := { navigation := some path }

structure FormSpec (kind : Contract.OperationKind) (Input Output Error : Type) [HasRecord Input] where
  operation : Contract.Operation kind Input Output Error
  onError : Error → Feedback Input
  onSuccess : Output → Feedback Input := fun _ => {}
  /-- Runs after a success is shown (an endpoint form's `onSuccess`, e.g. `navigate`). -/
  afterSuccess : Output → Action Unit := fun _ => pure ()
  label : String := "Submit"
  editors : Bool := true
  establishesSession : Bool := false
  editor : (HasRecord.record (T := Input)).Field → FieldBinding Lean.Json → Bool → Option Element := fun _ _ _ => none

/-- Shared transport/auth/cancellation handlers cannot consume domain alternatives. -/
structure ShellProps where
  generation : Nat
  currentGeneration : Action Nat
  framework : Contract.CallError Empty → Action Unit
  navigate : String → Action Unit
  refresh : Action Unit
  authenticationChanged : Action Unit := pure ()

structure Shell extends ShellProps where
  client : Contract.Interpreter Action
  requestClient : Option (ResourceRequest → Contract.Interpreter Action) := none

private def dispatch [HasRecord I] (shell : Shell) (feedback : Feedback I) : Action Unit := do
  if let some path := feedback.navigation then shell.navigate path

private def frameworkError : Contract.CallError E → Option (Contract.CallError Empty)
  | .domain _ => none
  | .unauthenticated => some .unauthenticated
  | .forbidden => some .forbidden
  | .transport error => some (.transport error)
  | .protocol error => some (.protocol error)
  | .decode error => some (.decode error)
  | .incompatible error => some (.incompatible error)
  | .cancelled => some .cancelled

structure DomainForm (I : Type) [HasRecord I] where
  form : LeanReact.Form Lean.Json I
  pending : Bool
  feedback : Feedback I
  submit : Action Unit
  readPending : Action Bool
  readFeedback : Action (Feedback I)
  /-- Cancels interest in the current submission and permits a new one. -/
  cancel : Action Unit

private def releaseCleanups (cell : Cell (Array (Action Unit))) : Action Unit := do
  let cleanups ← cell.modifyGet (fun pending => (pending, #[]))
  for cleanup in cleanups do cleanup

def useDomainForm [HasRecord I] (spec : FormSpec k I O E) (shell : Shell)
    (bound : Lean.Json := .mkObj []) (initial : Option I := none) : Hook (DomainForm I) := do
  let raw := initial.map (inputParser spec.operation.inputCodec).format |>.getD (bindFields (initialRaw spec.operation.inputCodec.schema)
    (wireDraft spec.operation.inputCodec.schema (.mkObj (HasRecord.defaultValues (T := I)))))
  let raw := bindFields raw bound
  let parser : DraftParser Lean.Json I := ⟨(fun draft => spec.operation.inputCodec.decode (draftWire spec.operation.inputCodec.schema (bindFields draft bound))), (inputParser spec.operation.inputCodec).format⟩
  let form ← useForm parser raw "domain.draft"
  let pending ← useState false "domain.pending"
  let claim ← useCell ((0 : Nat), false) "domain.submitClaim"
  let mounted ← useCell true "domain.mounted"
  let cleanups ← useCell (#[] : Array (Action Unit)) "domain.requestCleanups"
  useEffect #[] (do
    let _ ← mounted.modifyGet (fun _ => ((), true))
    pure (do
      let _ ← mounted.modifyGet (fun _ => ((), false))
      let _ ← claim.modifyGet (fun current => ((), (current.1 + 1, false)))
      releaseCleanups cleanups)) "domain.form.lifetime"
  let feedback ← useState ({} : Feedback I) "domain.feedback"
  let cancel : Action Unit := do
    let _ ← claim.modifyGet (fun current => ((), (current.1 + 1, false)))
    releaseCleanups cleanups
    if ← mounted.read then pending.set false
  let submit : Action Unit := do
    if !(← mounted.read) then return
    let token ← claim.modifyGet (fun current =>
      if current.2 then (none, current) else (some (current.1 + 1), (current.1 + 1, true)))
    let some token := token | return
    match ← form.validate with
    | .error _ =>
      let _ ← claim.modifyGet (fun current => ((), if current.1 == token then (token, false) else current))
      return
    | .ok input =>
      if !(← mounted.read) || (← claim.read).1 != token then return
      pending.set true
      feedback.set {}
      let request : ResourceRequest := {
        token := ⟨Key.inSpace spec.operation.identity.namespaceName (spec.operation.identity.name ++ ":" ++ spec.operation.identity.version), token⟩
        cancelled := do pure (!(← mounted.read) || (← claim.read).1 != token)
        onCleanup := fun cleanup => do
          if !(← mounted.read) || (← claim.read).1 != token then cleanup
          else
            let _ ← cleanups.modifyGet (fun pending => ((), pending.push cleanup))
            pure () }
      let client := (shell.requestClient.map (fun factory => factory request)).getD shell.client
      let result ← client.call spec.operation input
      if !(← mounted.read) || (← claim.read).1 != token then return
      releaseCleanups cleanups
      pending.set false
      let _ ← claim.modifyGet (fun current => ((), (current.1, false)))
      if (← shell.currentGeneration) != shell.generation then return
      match result with
      | .ok output =>
        if spec.establishesSession then shell.authenticationChanged
        let next := spec.onSuccess output
        feedback.set next
        dispatch shell next
        spec.afterSuccess output
        if next.navigation.isNone then shell.refresh
      | .error (.domain error) =>
        let next := spec.onError error
        feedback.set next
        dispatch shell next
      | .error error =>
        if let some failure := frameworkError error then shell.framework failure
  pure { form, pending := pending.value, feedback := feedback.value, submit, readPending := pending.read, readFeedback := feedback.read, cancel }

private def rawText (value : Lean.Json) : String :=
  match value with | .str text => text | _ => ""

private def labelFor (name : String) : String :=
  match name.toList with | [] => name | first :: rest => String.ofList ((if first.toNat ≥ 97 && first.toNat ≤ 122 then Char.ofNat (first.toNat - 32) else first) :: rest)

def editorField (binding : FieldBinding Lean.Json) (name : String) (schema : WireSchema) (metadata : EditorMetadata) (pending : Bool) : Element :=
  let schema := rawSchema schema
  let value := (binding.value.getObjVal? name).toOption.getD (.str "")
  let set := fun value => binding.modify (fun current => updateField current name value)
  let id := "domain-field-" ++ name
  let control := match schema with
    | .named _ version _ => if boundReference version then empty else
        DOM.input { id := some id, name := some name, value := some (rawText value), disabled := pending, required := metadata.required, onChange := some fun event => set (.str event.value) }
    | _ => if metadata.kind == .instant then
        -- Time (RFC 3339 on the wire) is edited as UTC calendar text over an exact epoch draft.
        DOM.input { id := some id, name := some name, value := some (DateInput.editorText (rawText value)), type := .datetimeLocal, step := some "1", disabled := pending, required := metadata.required, ariaLabel := some (labelFor name ++ " (UTC)"), onChange := some fun event => set (.str (DateInput.epochDraft event.value)) }
      else match schema with
    | .variant choices => DOM.select { id := some id, name := some name, value := some (rawText value), disabled := pending, required := metadata.required, onChange := some fun event => set (.str event.value) }
        (choices.map (fun (tag, _) => DOM.«option» { value := tag } #[LeanReact.text tag])).toArray
    | .boolean => DOM.input { id := some id, name := some name, type := .checkbox, checked := some ((value.getBool?).toOption.getD false), disabled := pending, onChange := some fun event => set (.bool event.checked) }
    | .integer => if metadata.kind == .instant then
        DOM.input { id := some id, name := some name, value := some (DateInput.editorText (rawText value)), type := .datetimeLocal, step := some "1", disabled := pending, required := metadata.required, ariaLabel := some (labelFor name ++ " (UTC)"), onChange := some fun event => set (.str (DateInput.epochDraft event.value)) }
      else DOM.input { id := some id, name := some name, value := some (rawText value), disabled := pending, required := metadata.required, onChange := some fun event => set (.str event.value) }
    | _ => DOM.input { id := some id, name := some name, value := some (rawText value), type := match metadata.kind with | .password => .password | .email => .email | _ => .text, disabled := pending, required := metadata.required, onChange := some fun event => set (.str event.value) }
  match schema with
  | .named _ version _ => if boundReference version then empty else
      DOM.div {} #[DOM.label { htmlFor := id } #[LeanReact.text (labelFor name)], control]
  | _ => DOM.div {} #[DOM.label { htmlFor := id } #[LeanReact.text (labelFor name)], control]

def editorFields (schema : WireSchema) : List (String × WireSchema) :=
  match schema with | .named _ _ body => editorFields body | .record fields => fields | _ => []

def FormSpec.render [HasRecord I] (spec : FormSpec k I O E) (model : DomainForm I) : Element :=
  let fields := if spec.editors then
    (editorFields spec.operation.inputCodec.schema).map (fun (name, schema) =>
      let descriptor := HasRecord.record (T := I)
      let custom := (descriptor.fields.find? (fun field => descriptor.fieldName field == name)).bind
        (fun field => spec.editor field model.form.binding model.pending)
      custom.getD (editorField model.form.binding name schema
        (((HasRecord.fieldMetadata (T := I)).find? (fun field => field.name == name)).map FieldMetadata.editor |>.getD {}) model.pending)) |>.toArray else #[]
  let domainErrors := model.feedback.fields.map fun (field, message) =>
    DOM.p { role := some "alert" } #[LeanReact.text ((HasRecord.record (T := I)).fieldName field ++ ": " ++ message)]
  let parserErrors := (model.form.draft.errors.map (fun errors => errors.toList.map fun error =>
    DOM.p { role := some "alert" } #[LeanReact.text error.code])).getD []
  DOM.form { onSubmit := model.submit, noValidate := true } (fields ++ domainErrors.toArray ++ parserErrors.toArray ++
    #[DOM.p { role := some "status", ariaLive := some "polite" }
        #[LeanReact.text (if model.pending then "Submitting…" else model.feedback.message.getD "")],
      DOM.button { type := .submit, disabled := model.pending } #[LeanReact.text spec.label]])

end LeanReact.Domain
