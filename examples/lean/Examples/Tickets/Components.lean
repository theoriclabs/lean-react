import LeanReact
import LeanReact.Forms
import Examples.Tickets.Domain

namespace Examples.Tickets

open LeanReact

structure CounterProps where
  label : String
  initial : Nat := 0

def useCount (initial : Nat) : Hook (State Nat) := useState initial "count"

def Counter : Component CounterProps := Component.named "Counter" <| component fun props => do
  let count ← useCount props.initial
  pure <| DOM.div { className := some "counter" } #[
    DOM.span {} #[text props.label],
    DOM.strong {} #[text (toString count.value)],
    DOM.button { ariaLabel := some ("Increment " ++ props.label), onPress := some (count.modify (· + 1)) } #[text "+1"]
  ]

structure ListProps (α : Type) where
  items : Array α
  key : α → Key
  row : α → Element
  className : String := "board"

def ListView (α : Type) : Component (ListProps α) :=
  Component.named "ListView" <| component fun props =>
    pure <| DOM.div { className := some props.className } #[keyedEach props.items props.key props.row]

def TicketList : Component (ListProps TicketSummary) := ListView TicketSummary

structure CardProps where
  ticket : TicketSummary
  onOpen : TicketId → Action Unit
  footer : TicketSummary → Element
  selected : Bool := false

def Card : Component CardProps := Component.named "TicketCard" <| component fun props => do
  pure <| DOM.article { className := some (if props.selected then "card selected" else "card") } #[
    DOM.h3 {} #[text props.ticket.value.title.value],
    DOM.span { className := some "badge" } #[text props.ticket.value.status.label],
    props.footer props.ticket,
    DOM.button { onPress := some (props.onOpen props.ticket.id) } #[text "Edit ticket"]
  ]

def TitleInput : LeanReact.Editor String := Component.named "TitleInput" <| component fun binding =>
  pure <| DOM.input {
    id := some "ticket-title"
    value := some binding.value
    onChange := some (fun event => binding.set event.value)
  }

def TitleTextarea : LeanReact.Editor String := Component.named "TitleTextarea" <| component fun binding =>
  pure <| DOM.textarea {
    id := some "ticket-title"
    value := some binding.value
    onChange := some (fun event => binding.set event.value)
  }

def titleParser : DraftParser String Title :=
  DraftParser.ofExcept Title.parse Title.value fun error =>
    match error with
    | .empty => Ontology.ValidationErrors.single "ticket.title.required"
    | .tooLong length => Ontology.ValidationErrors.single "ticket.title.too_long" [] [("length", toString length)]

def titleValidationMessage (errors : Ontology.ValidationErrors) : String :=
  if errors.first.code == "ticket.title.required" then "Give the ticket a title."
  else "Keep the title under 201 characters."

structure EditorProps where
  ticket : TicketSummary
  save : SaveTicket → Action (Except SaveError TicketSummary)
  onClose : Action Unit
  titleEditor : LeanReact.Editor String := TitleInput

structure EditorModel where
  form : Form String Title
  notice : State String
  submit : Action Unit

def useTicketEditor (props : EditorProps) : Hook EditorModel := do
  let form ← useForm titleParser props.ticket.value.title.value "draft-title"
  let notice ← useState "" "save-notice"
  let submit := do
    match ← form.validate with
    | .error errors => notice.set (titleValidationMessage errors)
    | .ok title =>
      match ← props.save {
        id := props.ticket.id
        expectedRevision := props.ticket.revision
        title
        status := props.ticket.value.status
      } with
      | .ok _ => notice.set "Saved."
      | .error .notFound => notice.set "This ticket no longer exists."
      | .error (.conflict _) => notice.set "This ticket changed. Your draft has been kept."
  let submit := submit.catchError (fun _ => notice.set "Could not save. Your draft has been kept.")
  pure { form, notice, submit }

def editorBody (props : EditorProps) (editor : EditorModel) : Element :=
  DOM.div { className := some "editor" } #[
    DOM.label { htmlFor := "ticket-title" } #[text "Ticket title"],
    element props.titleEditor editor.form.binding,
    DOM.div { className := some "controls" } #[
      DOM.button { className := some "primary", onPress := some editor.submit } #[text "Save changes"],
      DOM.button { onPress := some props.onClose } #[text "Close editor"]
    ],
    DOM.p { role := some "status" } #[text editor.notice.value]
  ]

def Editor : Component EditorProps := Component.named "TicketEditor" <| component fun props => do
  let editor ← useTicketEditor props
  pure <| editorBody props editor

/-- A second component uses exactly the same hook and field behavior. -/
def PageEditor : Component EditorProps := Component.named "PageEditor" <| component fun props => do
  let editor ← useTicketEditor props
  pure <| DOM.section { className := some "panel" } #[
    DOM.h2 {} #[text "Ticket detail"],
    DOM.p { className := some "note" } #[text "The same editor hook, composed in a page layout."],
    editorBody props editor
  ]

def revisionFooter (ticket : TicketSummary) : Element :=
  DOM.p { className := some "note" } #[text ("Revision " ++ toString ticket.revision)]

def statusFooter (ticket : TicketSummary) : Element :=
  DOM.p { className := some "note" } #[text ("Next step: " ++ ticket.value.status.next.label)]

def findTicket (id : TicketId) : List TicketSummary → Option TicketSummary
  | [] => none
  | ticket :: rest => if ticket.id == id then some ticket else findTicket id rest

def initialTickets : Array TicketSummary :=
  match seed with | .ok values => values | .error _ => #[]

/-- A list response owns membership and order; an older revision cannot replace a completed save. -/
def reconcileTickets (current incoming : Array TicketSummary) : Array TicketSummary :=
  incoming.map fun next => match findTicket next.id current.toList with
    | some previous => if previous.revision > next.revision then previous else next
    | none => next

structure WorkspaceProps where
  serviceKey : String
  service : TicketService Action
  /-- The list query behind `useResource`. A request-aware host loader forwards the resource's abort signal
  to its I/O (see `examples/adapters/tickets-service.mjs`); the default ignores the request. -/
  load : ResourceRequest → Action (Array TicketSummary) := fun _ => service.list

def resourceStamp : ResourceState α ε → Nat × Nat
  | .idle => (0, 0)
  | .loading token => (token.generation, 1)
  | .success token _ => (token.generation, 2)
  | .failure token _ => (token.generation, 3)

/-- Transport failures are a closed type, so each case gets its own message without string matching. -/
def loadFailureMessage (failure : ResourceFailure String) : String :=
  match Resource.failureAs failure with
  | .ok message => message
  | .error .unauthenticated => "Sign in to load tickets."
  | .error .forbidden => "You do not have access to these tickets."
  | .error .cancelled => "Loading was cancelled."
  | .error (.incompatible expected _) => s!"The ticket service speaks version {expected.version}; reload to update."
  | .error (.transport _) => "Could not reach the ticket service. Try reloading."
  | .error (.decode code) | .error (.protocol code) => s!"The ticket service answered unexpectedly ({code})."

def WorkspaceBody : Component WorkspaceProps := Component.named "TicketsWorkspaceBody" <| component fun props => do
  let query ← useResource (Key.string props.serviceKey)
    (fun request => (do pure (.ok (← props.load request)) : Action (Except String (Array TicketSummary))))
    #[] true "tickets-query"
  let tickets ← useState (#[] : Array TicketSummary) "tickets"
  let stamp := resourceStamp query.state
  useEffect #[.nat stamp.1, .nat stamp.2] (do
    match query.state with
    | .success _ values => tickets.modify (fun previous => reconcileTickets previous values)
    | _ => pure ()
    pure (pure ())) "tickets-snapshot"
  let inbox ← useState false "layout"
  let footer ← useState false "footer"
  let selected ← useState (none : Option TicketId) "selection"
  let pageEditor ← useState false "editor-layout"
  let multiline ← useState false "field-editor"
  let save : SaveTicket → Action (Except SaveError TicketSummary) := fun input => do
    match ← props.service.save input with
    | .error error => pure (.error error)
    | .ok next =>
      tickets.modify (fun values => values.map fun ticket =>
        if ticket.id == next.id && ticket.revision ≤ next.revision then next else ticket)
      pure (.ok next)
  let editor := match selected.value with
    | none => empty
    | some id => match findTicket id tickets.value.toList with
      | none => empty
      | some ticket => keyed (Key.inSpace id.scope.value id.key) <|
          element (if pageEditor.value then PageEditor else Editor) {
            ticket, save, onClose := selected.set none,
            titleEditor := if multiline.value then TitleTextarea else TitleInput
          }
  pure <| DOM.div {} #[
    DOM.section { className := some "panel" } #[
      DOM.h2 {} #[text "One hook, two independent counters"],
      element Counter { label := "First counter", initial := 0 },
      element Counter { label := "Second counter", initial := 10 }
    ],
    DOM.section { className := some "panel" } #[
      DOM.h2 {} #[text "Tickets, composed your way"],
      (match query.state with
       | .loading _ => DOM.p { className := some "note" } #[text "Loading tickets…"]
       | .failure _ failure => DOM.p { role := some "alert" } #[text (loadFailureMessage failure)]
       | _ => empty),
      DOM.div { className := some "toolbar" } #[
        DOM.button { onPress := some query.refresh } #[text "Reload tickets"],
        DOM.button { onPress := some (inbox.modify (!·)) } #[text (if inbox.value then "Show board" else "Show inbox")],
        DOM.button { onPress := some (footer.modify (!·)) } #[text "Swap card footer"],
        DOM.button { onPress := some (pageEditor.modify (!·)) } #[text "Swap editor layout"],
        DOM.button { onPress := some (multiline.modify (!·)) } #[text "Swap field editor"]
      ],
      element TicketList {
        items := tickets.value
        className := if inbox.value then "inbox" else "board"
        key := fun ticket => Key.inSpace ticket.id.scope.value ticket.id.key
        row := fun ticket => element Card {
          ticket, onOpen := fun id => selected.set (some id),
          footer := if footer.value then statusFooter else revisionFooter,
          selected := selected.value == some ticket.id
        }
      },
      editor
    ]
  ]

/-- A service key owns an independent workspace. Old async actions cannot update a new service's state. -/
def Workspace : Component WorkspaceProps := Component.named "TicketsWorkspace" <| component fun props =>
  pure <| keyed (Key.string props.serviceKey) (element WorkspaceBody props)

/-- One immediate transition validates and changes the local store. -/
def memoryService (store : Cell (Array TicketSummary)) : TicketService Action := {
  list := store.read
  save := fun input => store.modifyGet fun values =>
    match findTicket input.id values.toList with
    | none => (.error .notFound, values)
    | some previous =>
      match applySave previous input with
      | .error error => (.error error, values)
      | .ok next =>
        (.ok next, values.map fun ticket => if ticket.id == next.id then next else ticket)
}

/-- A local service interpreter built from the same shared save rule as the native server. -/
def App : Component Unit := Component.named "LocalTickets" <| component fun _ => do
  let store ← useCell initialTickets "local-store"
  pure <| element Workspace { serviceKey := "local", service := memoryService store }

end Examples.Tickets
