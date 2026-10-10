import AssistantUI

/-! A chat thread rendered by assistant-ui and owned by Lean: the transcript fold, the turns, and
what the composer may do are Lean values; the browser side is `adapters/assistant-ui/index.mjs`. -/

namespace Examples.Chat
open LeanReact AssistantUI

/-- A transcript as an agent runtime records it: flat rows, the tool result after its call. -/
def transcript : Array Entry := #[
  { id := "e1", role := .system, content := .text "You are a terse assistant." },
  { id := "e2", role := .user, content := .text "What is in this directory?", atMs := some 1700000000000 },
  { id := "e3", role := .assistant, content := .text "Let me look." },
  { id := "e4", role := .assistant, content := .toolCall "call-1" "list_files" (.fields #[("path", ".")]) },
  { id := "e5", role := .assistant, content := .toolResult "call-1" "README.md\nlakefile.toml\nengine/" },
  { id := "e6", role := .assistant, content := .text "Three entries: README.md, lakefile.toml and engine/." }
]

structure DemoProps where
  /-- Native stubs behind the thread's handle; the browser ignores them. -/
  stubs : ThreadOps := .silent

/-- Close the running assistant turn with `reply` and `outcome`. -/
private def finishTurn (outcome : MessageStatus) (reply : String) (messages : Array Message) : Array Message :=
  match messages.back? with
  | some last =>
    if last.role == .assistant then
      messages.set! (messages.size - 1) { last with parts := last.parts.push (.text reply), status := outcome }
    else messages
  | none => messages

/-- Keep the handle in a `Cell`: it is a capability, not render state. -/
def Demo : Component DemoProps := Component.named "ChatDemo" <| component fun props => do
  let messages ← useState (Message.ofTranscript transcript) "messages"
  let running ← useState false "running"
  let status ← useState "Transcript loaded." "status"
  let handle ← useCell (none : Option (Handle ThreadOps)) "thread-handle"
  let send (value : String) : Action Unit := do
    messages.modify fun ms =>
      let n := ms.size
      (ms.push (Message.text .user s!"user-{n}" value)).push
        { id := s!"assistant-{n + 1}", role := .assistant, parts := #[], status := .running }
    running.set true
    status.set s!"Sent: {value}"
  let cancel : Action Unit := do
    messages.modify (finishTurn .cancelled "Stopped.")
    running.set false
    status.set "Cancelled."
  let complete : Action Unit := do
    messages.modify (finishTurn .complete "Done.")
    running.set false
    status.set "Turn complete."
  let ready (h : Handle ThreadOps) : Action Unit := do
    handle.modifyGet fun _ => ((), some h)
    status.set "Thread ready."
  let gone : Action Unit := status.set "Thread gone."
  let draft : Action Unit := do
    match ← handle.read with
    | none => status.set "No thread yet."
    | some h =>
      match ← h.ops.setDraft "Thanks, that is all." with
      | .ok () => status.set "Drafted."
      | .unmounted => status.set "The thread was unmounted; nothing drafted."
  let submit : Action Unit := do
    match ← handle.read with
    | none => status.set "No thread yet."
    | some h =>
      match ← h.ops.submit with
      | .ok () => status.set "Submitted."
      | .unmounted => status.set "The thread was unmounted; nothing submitted."
  pure <| DOM.«section» { className := some "panel chat-demo" } #[
    DOM.h2 {} #[text "A chat thread, owned by Lean"],
    DOM.p { className := some "note" } #[text "assistant-ui renders it. Lean folds the transcript, appends the turns and decides what the composer may do."],
    threadWithHandle {
      messages := messages.value
      running := running.value
      composer := some { send, cancel := some cancel }
      placeholder := "Ask the assistant"
    } ready gone props.stubs,
    DOM.div { className := some "toolbar" } #[
      DOM.button { onPress := some complete, disabled := !running.value } #[text "Complete the turn"],
      DOM.button { onPress := some draft } #[text "Draft a reply"],
      DOM.button { onPress := some submit } #[text "Submit the draft"]
    ],
    DOM.p { role := some "status" } #[text status.value],
    DOM.p { className := some "note", data := #[("testid", "chat-count")] } #[text s!"{messages.value.size} messages"]
  ]

end Examples.Chat
