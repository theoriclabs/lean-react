import LeanReact
import LeanReact.Forms
import Examples.Tickets.Components

namespace Examples.Blog
open LeanReact

structure CounterProps where
  label : String

def Counter : Component CounterProps := component fun props => do
  let count ← useState 0 "count"
  pure <| DOM.button {
    onPress := some (count.modify (fun value => value + 1))
  } #[text (props.label ++ ": " ++ toString count.value)]

def CounterDemo : Component Unit := component fun _ =>
  pure <| element Counter { label := "Clicks" }

def ticketList (state : ResourceState (Array String) String) : Element :=
  match state with
  | .idle => DOM.p {} #[text "Loading tickets…"]
  | .loading _ => DOM.p {} #[text "Loading tickets…"]
  | .failure _ (.loader message) => DOM.p { role := some "alert" } #[text message]
  | .failure _ (.exception _) =>
      DOM.p { role := some "alert" } #[text "Could not load tickets. Try again."]
  | .success _ titles =>
      if titles.isEmpty then DOM.p {} #[text "No open tickets. You're all caught up."]
      else DOM.ul {} (titles.map fun title => DOM.li {} #[text title])

def requestToken : ResourceToken := { key := Key.string "tickets", generation := 1 }

def ResourceDemo : Component Unit := component fun _ => do
  let state ← useState (.idle : ResourceState (Array String) String) "resource-state"
  let selected ← useState "Idle" "selected-state"
  let choose := fun label value => node "button" #[
    .string "type" "button",
    .string "aria-pressed" (if selected.value == label then "true" else "false"),
    .press (fun _ => do selected.set label; state.set value)
  ] #[text label]
  pure <| DOM.div {} #[
    DOM.div { className := some "state-controls" } #[
      choose "Idle" .idle,
      choose "Loading" (.loading requestToken),
      choose "Success" (.success requestToken #["Fix the login page", "Add a reply button"]),
      choose "Empty" (.success requestToken #[]),
      choose "Failure" (.failure requestToken (.exception "Network unavailable"))
    ],
    DOM.div { className := some "resource-result", role := some "status" } #[ticketList state.value]
  ]

def TitleInput : Editor String := component fun field =>
  pure <| DOM.input {
    value := some field.value
    ariaLabel := some "Ticket title"
    onChange := some (fun event => field.set event.value)
  }

def TitleTextarea : Editor String := component fun field =>
  pure <| node "textarea" #[
    .string "aria-label" "Ticket title", .string "value" field.value,
    .change (fun event => field.set event.value)
  ] #[]

structure TitleFieldProps where
  editor : Editor String := TitleInput

def TitleField : Component TitleFieldProps := component fun props => do
  let draft ← useState "Fix the login page" "title"
  pure <| element props.editor (FieldBinding.ofState draft)

def EditorDemo : Component Unit := component fun _ => do
  let multiline ← useState false "multiline"
  pure <| DOM.div { className := some "editor-demo" } #[
    DOM.p { className := some "field-label" } #[text "Ticket title"],
    element TitleField { editor := if multiline.value then TitleTextarea else TitleInput },
    DOM.button { onPress := some (multiline.modify (!·)) } #[
      text (if multiline.value then "Use single-line input" else "Use textarea")
    ]
  ]

def FormDemo : Component Unit := component fun _ => do
  let form ← useForm Tickets.titleParser "Fix the login page" "draft-title"
  let notice ← useState "" "save-notice"
  let save : Action Unit := do
    let result ← form.submit fun title => notice.set ("Saved: " ++ title.value)
    match result with
    | .ok _ => pure ()
    | .error errors => notice.set (Tickets.titleValidationMessage errors)
  pure <| DOM.div { className := some "form-demo" } #[
    DOM.label { htmlFor := "draft-title" } #[text "Ticket title"],
    DOM.input {
      id := some "draft-title", value := some form.binding.value,
      onChange := some (fun event => do form.binding.set event.value; notice.set "")
    },
    DOM.p { className := some "field-hint" } #[text "Use between 1 and 200 characters."],
    DOM.button { className := some "primary", onPress := some save } #[text "Save title"],
    DOM.p { role := some "status" } #[text notice.value]
  ]

end Examples.Blog
