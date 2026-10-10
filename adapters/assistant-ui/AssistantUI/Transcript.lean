import AssistantUI.Thread

/-! # Transcripts

Agent runtimes record a conversation as a flat sequence of rows: text, tool calls, and tool
results as rows of their own, after the call. `Message.ofTranscript` folds such a transcript into
the messages a thread renders. An application maps its own transcript type to `Entry` and keeps
the fold; the fold is pure Lean, compiled for the browser and run natively alike. -/

namespace AssistantUI

/-- What one transcript row carries. -/
inductive Content where
  | text (value : String)
  | reasoning (value : String)
  | image (url : String)
  | toolCall (callId : String) (name : String) (arguments : ToolArguments)
  | toolResult (callId : String) (result : String) (isError : Bool := false)
  deriving Repr, BEq, Inhabited

/-- One row of a flat transcript, in order. -/
structure Entry where
  id : String
  role : Role
  content : Content
  atMs : Option Nat := none
  deriving Repr, BEq, Inhabited

namespace Message

/-- `parts` with `result` attached to the pending call `callId`, or `none` when there is no such call. -/
private def attachResult (parts : Array Part) (callId : String) (result : ToolResult) : Option (Array Part) :=
  let step := fun (acc : Array Part × Bool) (part : Part) =>
    match part, acc.2 with
    | .toolCall id name arguments none, false =>
      if id == callId then (acc.1.push (.toolCall id name arguments (some result)), true)
      else (acc.1.push part, false)
    | _, done => (acc.1.push part, done)
  let (updated, found) := parts.toList.foldl step (#[], false)
  if found then some updated else none

/-- The index of the last message with a pending call `callId`. -/
private def pendingCall (messages : Array Message) (callId : String) : Option Nat :=
  (messages.toList.foldl (init := ((0 : Nat), (none : Option Nat))) fun acc message =>
    let pending := message.parts.toList.any fun
      | .toolCall id _ _ none => id == callId
      | _ => false
    (acc.1 + 1, if pending then some acc.1 else acc.2)).2

/-- Append `part`: to the last message when both are assistant rows, otherwise as a new message. -/
private def append (messages : Array Message) (entry : Entry) (part : Part) : Array Message :=
  let fresh : Message := { id := entry.id, role := entry.role, parts := #[part], createdAtMs := entry.atMs }
  match messages.back? with
  | some last =>
    if last.role == .assistant && entry.role == .assistant then
      messages.set! (messages.size - 1) { last with parts := last.parts.push part }
    else messages.push fresh
  | none => messages.push fresh

/-- Fold a flat transcript into thread messages. An assistant turn is one message: its consecutive
text, reasoning and tool-call rows join, and a tool result attaches to the pending call with its id,
wherever that call is. User and system rows are one message each. A result whose call is not in the
transcript becomes an assistant message of its own, named `unknown`, so nothing is dropped silently. -/
def ofTranscript (entries : Array Entry) : Array Message :=
  entries.toList.foldl (init := #[]) fun messages entry =>
    match entry.content with
    | .text value => append messages entry (.text value)
    | .reasoning value => append messages entry (.reasoning value)
    | .image url => append messages entry (.image url)
    | .toolCall callId name arguments => append messages entry (.toolCall callId name arguments none)
    | .toolResult callId value isError =>
      let result : ToolResult := { value, isError }
      match pendingCall messages callId with
      | some index =>
        match messages[index]? with
        | some message =>
          match attachResult message.parts callId result with
          | some parts => messages.set! index { message with parts }
          | none => messages
        | none => messages
      | none =>
        messages.push {
          id := entry.id
          role := .assistant
          createdAtMs := entry.atMs
          parts := #[.toolCall callId "unknown" (.raw "") (some result)] }

end Message

end AssistantUI
