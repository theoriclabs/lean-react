import AssistantUI

/-! Native checks for assistant-ui for Lean: the transcript fold, the reference render of a thread,
the reference composer, and the handle over caller-supplied stubs. -/

open LeanReact AssistantUI

private def check (condition : Bool) (message : String) : IO Unit :=
  unless condition do throw <| IO.userError message

private def entries : Array Entry := #[
  { id := "e1", role := .system, content := .text "Be terse." },
  { id := "e2", role := .user, content := .text "Hello", atMs := some 10 },
  { id := "e3", role := .assistant, content := .text "Looking." },
  { id := "e4", role := .assistant, content := .toolCall "c1" "list" (.raw "{}") },
  { id := "e5", role := .assistant, content := .toolResult "c1" "a b" },
  { id := "e6", role := .assistant, content := .text "Done." },
  { id := "e7", role := .user, content := .text "Thanks" },
  { id := "e7b", role := .user, content := .image "data:image/png;base64,AAAA" },
  { id := "e8", role := .assistant, content := .toolResult "ghost" "orphan" (isError := true) }
]

/-- Every node with `tag`, in document order. -/
partial def nodes (tag : String) : RenderedTree → Array (Array Attribute × Array RenderedTree)
  | .text _ => #[]
  | .node t attributes children =>
    (if t == tag then #[(attributes, children)] else #[]) ++ children.flatMap (nodes tag)
  | .fragment children => children.flatMap (nodes tag)
  | .keyed _ child | .child _ _ child => nodes tag child

partial def boundary? (name : String) : RenderedTree → Bool
  | .text _ => false
  | .node _ _ children | .fragment children => children.any (boundary? name)
  | .keyed _ child => boundary? name child
  | .child n _ child => n == name || boundary? name child

def main : IO Unit := do
  -- The fold.
  let messages := Message.ofTranscript entries
  check (messages.size == 6) s!"expected 6 messages, got {messages.size}"
  check ((messages.map (·.id)) == #["e1", "e2", "e3", "e7", "e7b", "e8"]) "message ids follow the first row of each turn"
  check ((messages.map (·.role)) == #[.system, .user, .assistant, .user, .user, .assistant]) "roles"
  check ((messages.getD 4 default).parts == #[.image "data:image/png;base64,AAAA"]) "an image row is an image part"
  check ((messages.getD 1 default).createdAtMs == some 10) "createdAt from the row"
  let turn := messages.getD 2 default
  check (turn.parts == #[.text "Looking.", .toolCall "c1" "list" (.raw "{}") (some { value := "a b" }), .text "Done."])
    s!"assistant turn joined with the result attached: {repr turn.parts}"
  check (turn.plainText == "Looking.\nDone.") "plainText joins the text parts"
  check ((messages.getD 5 default).parts == #[.toolCall "ghost" "unknown" (.raw "") (some { value := "orphan", isError := true })])
    "an orphan result is kept as an unknown call"
  check (Message.ofTranscript #[] == #[]) "empty transcript"

  -- The reference render of a read-only thread.
  let readOnly ← Reference.render (thread { messages })
  check (boundary? foreignName readOnly.value) "the foreign boundary carries the registered name"
  let articles := nodes "article" readOnly.value
  check (articles.size == 6) s!"one article per message, got {articles.size}"
  check ((articles.map fun (attributes, _) => Reference.attribute? attributes "data-role") ==
    #[some "system", some "user", some "assistant", some "user", some "user", some "assistant"]) "data-role per article"
  check ((nodes "img" readOnly.value).size == 1) "the image row renders an img"
  check ((nodes "form" readOnly.value).isEmpty) "no composer when none is given"
  check ((nodes "details" readOnly.value).size == 2) "tool calls render as details"
  check ((Reference.RenderedTree.textContent readOnly.value).startsWith "Be terse.") "message text in order"
  let empty ← Reference.render (thread { messages := #[], emptyText := "Nothing yet" })
  check (Reference.RenderedTree.textContent empty.value == "Nothing yet") "empty text"

  -- The reference composer sends through the Lean action.
  let sent ← IO.mkRef (#[] : Array String)
  let composer : Composer := { send := fun value => ⟨sent.modify (·.push value)⟩ }
  let interactive ← Reference.render (thread { messages, composer := some composer, placeholder := "Say it" })
  let some (textarea, _) := (nodes "textarea" interactive.value)[0]? | throw (IO.userError "composer textarea")
  check (Reference.attribute? textarea "placeholder" == some "Say it") "placeholder"
  let some (form, _) := (nodes "form" interactive.value)[0]? | throw (IO.userError "composer form")
  Reference.dispatchSubmit form
  check ((← sent.get) == #[]) "an empty draft is not sent"
  Reference.dispatchChange textarea { value := "Hi there" }
  Reference.dispatchSubmit form
  check ((← sent.get) == #["Hi there"]) s!"the draft is sent: {(← sent.get)}"
  let buttons := (nodes "button" interactive.value).map fun (_, children) => Reference.RenderedTree.textContent (.fragment children)
  check (buttons == #["Send"]) s!"Send while idle, got {buttons}"
  let running ← Reference.render (thread {
    messages
    running := true
    composer := some { composer with cancel := some (pure ()) } })
  let buttons := (nodes "button" running.value).map fun (_, children) => Reference.RenderedTree.textContent (.fragment children)
  check (buttons == #["Stop"]) s!"Stop while running with a cancel action, got {buttons}"

  -- The handle over stubs: onReady after commit, ops run the stubs, disposal flips alive and runs onGone.
  let drafts ← IO.mkRef (#[] : Array String)
  let events ← IO.mkRef (#[] : Array String)
  let handle ← IO.mkRef (none : Option (Handle ThreadOps))
  let stubs : ThreadOps := {
    setDraft := fun value => ⟨do drafts.modify (·.push value); pure (.ok ())⟩
    submit := pure (.ok ())
    focus := pure .unmounted }
  let prepared ← Reference.render (threadWithHandle { messages }
    (fun h => ⟨do handle.set (some h); events.modify (·.push "ready")⟩) ⟨events.modify (·.push "gone")⟩ stubs)
  check ((← handle.get).isNone) "onReady waits for commit"
  let dispose ← prepared.commit
  let some h ← handle.get | throw (IO.userError "onReady did not run on commit")
  check ((← Reference.runAction h.alive) == true) "alive after commit"
  check ((← Reference.runAction (h.ops.setDraft "draft")) == .ok ()) "setDraft runs the stub"
  check ((← drafts.get) == #["draft"]) "the stub saw the draft"
  check ((← Reference.runAction h.ops.focus) == .unmounted) "stubs run as given"
  Reference.runAction dispose
  check ((← Reference.runAction h.alive) == false) "alive flips on dispose"
  check ((← events.get) == #["ready", "gone"]) s!"lifecycle order: {(← events.get)}"
  IO.println "AssistantUI native checks passed."
