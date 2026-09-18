import LeanReact

namespace Examples.Feedback
open LeanReact

/-- Option values and labels for the topic picker. -/
def topics : Array (String × String) := #[("idea", "An idea"), ("bug", "A bug report"), ("question", "A question")]

def topicLabel (value : String) : String :=
  match topics.find? (·.1 == value) with
  | some (_, label) => label
  | none => value

structure Draft where
  name : String := ""
  topic : String := "idea"
  message : String := ""

/-- A form built only from typed DOM helpers: `form` never navigates, `onBlur` validates, `onPaste`
observes the clipboard snapshot, and `onKeyDown` decides whether the browser default runs. -/
def App : Component Unit := Component.named "Feedback" <| component fun _ => do
  let draft ← useState ({} : Draft) "draft"
  let nameError ← useState "" "name-error"
  let pasted ← useState 0 "pasted"
  let status ← useState "" "status"
  let validateName (value : String) : Action Unit :=
    nameError.set (if value.isEmpty then "Name is required." else "")
  let send : Action Unit := do
    let current ← draft.read
    if current.name.isEmpty then
      nameError.set "Name is required."
      status.set "Add your name before sending."
    else
      status.set s!"Sent {topicLabel current.topic} from {current.name} ({current.message.length} characters)."
  let shortcuts (event : KeyEvent) : Action KeyOutcome := do
    if (event.ctrl || event.metaKey) && event.key == "s" then
      status.set "Draft kept locally."
      pure .preventDefault
    else if event.key == "Enter" && !event.shift then
      send
      pure .preventDefault
    else pure .continue
  let reset : Action Unit := do
    draft.set {}
    nameError.set ""
    pasted.set 0
    status.set ""
  pure <| DOM.form { className := some "panel feedback", ariaLabel := some "Feedback", onSubmit := send } #[
    DOM.h2 {} #[text "Send feedback"],
    DOM.p { className := some "note" } #[
      text "Press ", DOM.kbd {} #[text "Enter"], text " in the message to send, ",
      DOM.kbd {} #[text "Shift+Enter"], text " for a new line, and ", DOM.kbd {} #[text "Ctrl+S"], text " to keep the draft."],
    DOM.label { htmlFor := "feedback-name" } #[text "Your name"],
    DOM.input {
      id := some "feedback-name"
      value := some draft.value.name
      autoComplete := some "name"
      ariaDescribedBy := some "feedback-name-error"
      data := #[("testid", "feedback-name")]
      onChange := some fun event => draft.modify fun current => { current with name := event.value }
      onBlur := some fun event => validateName event.value
    },
    DOM.p { id := some "feedback-name-error", role := some "alert", className := some "error" } #[text nameError.value],
    DOM.label { htmlFor := "feedback-topic" } #[text "Topic"],
    DOM.select {
      id := some "feedback-topic"
      value := some draft.value.topic
      data := #[("testid", "feedback-topic")]
      onChange := some fun event => draft.modify fun current => { current with topic := event.value }
    } (topics.map fun (value, label) => DOM.option { value } #[text label]),
    DOM.label { htmlFor := "feedback-message" } #[text "Message"],
    DOM.textarea {
      id := some "feedback-message"
      value := some draft.value.message
      rows := some 4
      placeholder := some "What should we know?"
      spellCheck := some true
      data := #[("testid", "feedback-message")]
      style := #[(.resize, "vertical"), (.minHeight, "6rem")]
      onChange := some fun event => draft.modify fun current => { current with message := event.value }
      onPaste := some fun event => pasted.set event.text.length
      onKeyDown := some shortcuts
    },
    DOM.p { className := some "note", data := #[("testid", "feedback-pasted")] }
      #[text (if pasted.value == 0 then "" else s!"Pasted {pasted.value} characters.")],
    DOM.div { className := some "controls" } #[
      DOM.button { type := .submit, className := some "primary" } #[text "Send"],
      DOM.button { onPress := some reset } #[text "Clear"]
    ],
    DOM.p { role := some "status", ariaLive := some "polite", data := #[("testid", "feedback-status")] } #[text status.value]
  ]

end Examples.Feedback
