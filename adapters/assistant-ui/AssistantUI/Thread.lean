import LeanReact

/-! # assistant-ui for Lean

A typed chat thread over the [assistant-ui](https://github.com/assistant-ui/assistant-ui) React
primitives. Lean owns the conversation: the `Message`s, whether a turn is running, and what the
composer may do. `thread props` renders it; in the browser the host adapter
(`adapters/assistant-ui/index.mjs`, registered under `foreignName`) feeds the messages to
assistant-ui's external-store runtime and renders its primitives. Natively the reference renders one
article per message and a stateful composer form, so a component over a thread is testable in Lean
with `LeanReact.Reference`. -/

namespace AssistantUI
open LeanReact

/-- Who said it. assistant-ui renders these three roles; the tool rows of a transcript become
`Part.toolCall` parts of the assistant message that made the call (`Message.ofTranscript`). -/
inductive Role where
  | user
  | assistant
  | system
  deriving Repr, BEq, DecidableEq, Inhabited

def Role.name : Role → String
  | .user => "user"
  | .assistant => "assistant"
  | .system => "system"

structure ToolResult where
  value : String
  isError : Bool := false
  deriving Repr, BEq, Inhabited

/-- The arguments of a tool call, as the thread shows them: named fields when the call was a JSON
object, in display order, with the first field summarizing the call; otherwise the text as sent. -/
inductive ToolArguments where
  | raw (text : String)
  | fields (entries : Array (String × String))
  deriving Repr, BEq, Inhabited

/-- The lines of a text. List-based: the browser-side Lean runs this too. -/
def textLines (text : String) : List String :=
  let (current, done) := text.toList.foldl (init := (([] : List Char), ([] : List String)))
    fun (current, done) c => if c == '\n' then ([], String.ofList current.reverse :: done) else (c :: current, done)
  (String.ofList current.reverse :: done).reverse

/-- The first line that says something: not blank and not a `//` or `#` comment, as tool inputs
often open with one. -/
def firstMeaningfulLine (text : String) : String :=
  let comment (line : List Char) : Bool := ['/', '/'].isPrefixOf line || ['#'].isPrefixOf line
  ((textLines text).map fun line => line.toList.dropWhile Char.isWhitespace).find?
    (fun line => !line.isEmpty && !comment line) |>.map String.ofList |>.getD ""

/-- The first meaningful line of the first field's value, or of the raw text: the collapsed
header's hint. -/
def ToolArguments.summary (arguments : ToolArguments) (width : Nat := 100) : String :=
  let text := match arguments with
    | .raw text => text
    | .fields entries => (entries.getD 0 ("", "")).2
  let line := firstMeaningfulLine text
  if line.length ≤ width then line else String.ofList (line.toList.take width) ++ "…"

example : firstMeaningfulLine "// @exec: {}\n\n  ls -la\nmore" = "ls -la" := by native_decide
example : firstMeaningfulLine "# only a comment" = "" := by native_decide
example : (ToolArguments.fields #[("description", "List files"), ("command", "ls")]).summary = "List files" := by native_decide

/-- One part of a message. A tool call carries its result once the tool answered; an image is a
URL the browser can load, a `data:` URL for one that was pasted. -/
inductive Part where
  | text (value : String)
  | reasoning (value : String)
  | image (url : String)
  | toolCall (callId : String) (name : String) (arguments : ToolArguments) (result : Option ToolResult := none)
  deriving Repr, BEq, Inhabited

/-- The status of an assistant turn. User and system messages are always `.complete`. -/
inductive MessageStatus where
  | complete
  | running
  | cancelled
  | failed (error : String)
  | requiresAction
  deriving Repr, BEq, Inhabited

structure Message where
  id : String
  role : Role
  parts : Array Part
  /-- Milliseconds since the Unix epoch. -/
  createdAtMs : Option Nat := none
  status : MessageStatus := .complete
  deriving Repr, BEq, Inhabited

def Message.text (role : Role) (id : String) (value : String) : Message :=
  { id, role, parts := #[.text value] }

/-- The text parts, joined by newlines. -/
def Message.plainText (message : Message) : String :=
  message.parts.toList.foldl (init := "") fun acc part =>
    match part with
    | .text value => if acc.isEmpty then value else acc ++ "\n" ++ value
    | _ => acc

/-- What the person at the keyboard may do. An absent action hides its control. -/
structure Composer where
  /-- The composer's text, submitted. -/
  send : String → Action Unit
  /-- Stop the running assistant turn. -/
  cancel : Option (Action Unit) := none

structure ThreadProps where
  messages : Array Message
  /-- A turn is in progress: the last assistant message is streaming and the composer offers Stop. -/
  running : Bool := false
  /-- `none` renders a read-only transcript. -/
  composer : Option Composer := none
  placeholder : String := "Write a message…"
  emptyText : String := "No messages yet."
  /-- Messages exist before the first one in `messages`; `loadEarlier` fetches them. -/
  hasEarlier : Bool := false
  loadEarlier : Option (Action Unit) := none

/-- The thread's imperative API, for `threadWithHandle`. -/
structure ThreadOps where
  /-- Replace the composer draft. -/
  setDraft : String → Action (HandleResult Unit)
  /-- Submit the draft, as pressing Send would. -/
  submit : Action (HandleResult Unit)
  /-- Focus the composer input. -/
  focus : Action (HandleResult Unit)

/-- Reference stubs: every operation succeeds without doing anything. -/
def ThreadOps.silent : ThreadOps :=
  { setDraft := fun _ => pure (.ok ()), submit := pure (.ok ()), focus := pure (.ok ()) }

/-- The name the host adapter registers with `registerForeign`. -/
def foreignName : String := "assistant-ui-thread"

/-! ## The native reference

Plain DOM with the same `aui-` class names as the browser side, under a `.child foreignName`
boundary. The composer is a component with a draft in state, so `send` can be exercised natively. -/
namespace Reference

def part : Part → Element
  | .text value => DOM.p { className := some "aui-text" } #[text value]
  | .reasoning value => DOM.p { className := some "aui-reasoning" } #[text value]
  | .image url => DOM.img { className := some "aui-image", src := url, alt := "image" }
  | .toolCall callId name arguments result =>
    node "details" #[.string "className" "aui-tool-call", .string "data-call-id" callId] #[
      node "summary" #[.string "className" "aui-tool-head"] #[
        DOM.span { className := some "aui-tool-name" } #[text name],
        DOM.span { className := some "aui-tool-summary" } #[text arguments.summary]],
      (match arguments with
        | .raw value => DOM.pre { className := some "aui-tool-arguments" } #[text value]
        | .fields entries => DOM.div { className := some "aui-tool-arguments" } (entries.map fun (key, value) =>
            DOM.div { className := some "aui-tool-field" } #[
              DOM.span { className := some "aui-tool-key" } #[text key],
              DOM.pre { className := some "aui-tool-value" } #[text value]])),
      match result with
      | none => DOM.p { className := some "aui-tool-pending" } #[text "No result yet."]
      | some r =>
        DOM.pre { className := some (if r.isError then "aui-tool-result aui-tool-error" else "aui-tool-result") }
          #[text r.value]
    ]

def message (message : Message) : Element :=
  DOM.article { className := some "aui-message", data := #[("role", message.role.name), ("message-id", message.id)] }
    (message.parts.map part)

structure ComposerProps where
  composer : Composer
  placeholder : String
  running : Bool

def ComposerForm : Component ComposerProps := Component.named "AssistantUI.Composer" <| component fun props => do
  let draft ← useState "" "aui-draft"
  let submit : Action Unit := do
    let value ← draft.read
    if value.isEmpty then pure () else
      draft.set ""
      props.composer.send value
  pure <| DOM.form { className := some "aui-composer", onSubmit := submit } #[
    DOM.textarea {
      className := some "aui-composer-input"
      placeholder := some props.placeholder
      value := some draft.value
      onChange := some fun event => draft.set event.value },
    (match props.composer.cancel, props.running with
      | some cancel, true => DOM.button { className := some "aui-composer-cancel", onPress := some cancel } #[text "Stop"]
      | _, _ => DOM.button { className := some "aui-composer-send", type := .submit } #[text "Send"])
  ]

def thread (props : ThreadProps) : Element :=
  DOM.«section» { className := some "aui-thread", data := #[("running", if props.running then "true" else "false")] } #[
    (match props.loadEarlier, props.hasEarlier with
      | some load, true => DOM.button { className := some "aui-load-earlier", onPress := some load } #[text "Load earlier"]
      | _, _ => empty),
    (if props.messages.isEmpty then DOM.p { className := some "aui-empty" } #[text props.emptyText]
      else keyedEach props.messages (fun m => Key.string m.id) message),
    (match props.composer with
      | none => empty
      | some composer => element ComposerForm { composer, placeholder := props.placeholder, running := props.running })
  ]

end Reference

/-- A thread without an imperative handle: read-only when `props.composer` is `none`. -/
def thread (props : ThreadProps) : Element :=
  foreign foreignName {
    props
    onReady := fun (_ : Handle ThreadOps) => pure ()
    reference := { render := Reference.thread } }

/-- A thread with a typed handle. `onReady` runs once per mount with `setDraft`, `submit` and `focus`;
after unmount they resolve to `.unmounted`. Natively the handle runs `stubs`. -/
def threadWithHandle (props : ThreadProps) (onReady : Handle ThreadOps → Action Unit)
    (onGone : Action Unit := pure ()) (stubs : ThreadOps := .silent) : Element :=
  foreign foreignName { props, onReady, onGone, reference := { render := Reference.thread, ops := some fun _ => stubs } }

end AssistantUI
