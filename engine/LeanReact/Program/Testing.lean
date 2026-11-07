import LeanReact.Program.Component

/-! # Native testing: simulate a component and query its view, without a browser

```
#guard (Counter.simulate 0 [.add 2, .add 3]).1 == 5
#guard (click (Counter.view 0 5) (byText "Reset")) == some .reset
#guard (find? (Todos.view () m) (byRole "button" "Add")).map (·.disabled) == some true
```

Queries read the view as data: `byText` matches an element's own text, `byRole` its explicit
`role` or the implicit one of its tag (`button`, `link`, `textbox`, `checkbox`, `heading`,
`list`, `listitem`, `form`), `byLabel` its `aria-label` (or a wrapping `label`'s text).
`click` gives the message a click would send (the element's own handler, else the nearest
ancestor's: events bubble), `clicks` every message in bubbling order. These run natively only
(`partial` is fine here); the browser tests cover the host. -/

namespace LeanReact.Program

/-- Run `init`, then each message in order, recording commands without running them. -/
def Component.simulate (c : Component Props Model Msg) (props : Props) (msgs : List Msg) :
    Model × List (Cmd Msg) :=
  let (model, cmd) := c.init props
  msgs.foldl (fun (model, cmds) msg =>
    let (next, cmd) := c.update props msg model
    (next, cmds ++ [cmd])) (model, [cmd])

/-- What a query matches. -/
structure Selector where
  text : Option String := none
  role : Option String := none
  label : Option String := none
  tag : Option String := none

def byText (text : String) : Selector := { text := some text }
def byRole (role : String) (text : Option String := none) : Selector := { role := some role, text }
def byLabel (label : String) : Selector := { label := some label }
def byTag (tag : String) : Selector := { tag := some tag }

/-- An element of a view, with the label text around it. -/
structure Found (Msg : Type) where
  tag : String
  attrs : List (Attr Msg)
  children : List (Html Msg)
  /-- Text of an enclosing `label`, if any. -/
  labelText : Option String := none

namespace Html

/-- All text of a view, in order. -/
partial def textContent : Html Msg → String
  | .text value => value
  | .node _ _ children => String.join (children.map textContent)
  | .keyed _ child => textContent child
  | .lazy _ view => textContent (view ())
  | _ => ""

end Html

private def attrValue? (attrs : List (Attr Msg)) (name : String) : Option String :=
  attrs.findSome? fun | .attr n v => if n == name then some v else none | _ => none

private def boolAttr (attrs : List (Attr Msg)) (name : String) : Bool :=
  attrs.any fun | .bool n v => n == name && v | _ => false

def Found.attr? (f : Found Msg) (name : String) : Option String := attrValue? f.attrs name
def Found.disabled (f : Found Msg) : Bool := boolAttr f.attrs "disabled"
def Found.checked (f : Found Msg) : Bool := boolAttr f.attrs "checked"
def Found.text (f : Found Msg) : String := String.join (f.children.map Html.textContent)

/-- The explicit role, or the implicit role of the tag. -/
def Found.role (f : Found Msg) : Option String :=
  (f.attr? "role").orElse fun _ => match f.tag, f.attr? "type" with
    | "button", _ => some "button" | "a", _ => some "link" | "form", _ => some "form"
    | "ul", _ | "ol", _ => some "list" | "li", _ => some "listitem"
    | "input", some "checkbox" => some "checkbox" | "input", some "submit" => some "button"
    | "input", _ | "textarea", _ => some "textbox" | "select", _ => some "combobox"
    | "h1", _ | "h2", _ | "h3", _ | "h4", _ | "h5", _ | "h6", _ => some "heading"
    | _, _ => none

def Selector.matches (s : Selector) (f : Found Msg) : Bool :=
  s.tag.all (· == f.tag) && s.role.all (some · == f.role) && s.text.all (· == f.text) &&
    s.label.all fun l => f.attr? "aria-label" == some l || f.labelText == some l

/-- Every element, in document order, each with its ancestors (nearest first). -/
partial def elements (view : Html Msg) : List (Found Msg × List (Found Msg)) :=
  go view [] none
where
  go (view : Html Msg) (ancestors : List (Found Msg)) (labelText : Option String) :
      List (Found Msg × List (Found Msg)) :=
    match view with
    | .node tag attrs children =>
      let here : Found Msg := { tag, attrs, children, labelText }
      let inner := if tag == "label" then some here.text else labelText
      (here, ancestors) :: children.flatMap fun child => go child (here :: ancestors) inner
    | .keyed _ child => go child ancestors labelText
    | .lazy _ v => go (v ()) ancestors labelText
    | _ => []

/-- The first element matching `s`. -/
def find? (view : Html Msg) (s : Selector) : Option (Found Msg) :=
  ((elements view).find? fun (f, _) => s.matches f).map (·.1)

/-- Every element matching `s`. -/
def findAll (view : Html Msg) (s : Selector) : List (Found Msg) :=
  ((elements view).filter fun (f, _) => s.matches f).map (·.1)

def findByText (view : Html Msg) (text : String) := find? view (byText text)
def findByRole (view : Html Msg) (role : String) (text : Option String := none) := find? view (byRole role text)
def findByLabel (view : Html Msg) (label : String) := find? view (byLabel label)

/-- A click's message on one element: its press handler, or for a checkbox its toggled change. -/
private def pressOf (f : Found Msg) : Option Msg :=
  (f.attrs.findSome? fun | .onPress decode => decode {} | _ => none).orElse fun _ =>
    if f.tag == "input" && f.attr? "type" == some "checkbox" then
      f.attrs.findSome? fun | .onChange decode => decode { value := "on", checked := !f.checked } | _ => none
    else none

/-- Every message a click on the first match sends, in bubbling order (none if disabled). -/
def clicks (view : Html Msg) (s : Selector) : List Msg :=
  match (elements view).find? fun (f, _) => s.matches f with
  | some (target, ancestors) => if target.disabled then [] else (target :: ancestors).filterMap pressOf
  | none => []

/-- The message a click on the first match sends (its own handler, else the nearest ancestor's). -/
def click (view : Html Msg) (s : Selector) : Option Msg := (clicks view s).head?

/-- The message typing `text` into the first match sends. -/
def typeInto (view : Html Msg) (s : Selector) (text : String) : Option Msg :=
  (find? view s).bind fun f => f.attrs.findSome? fun
    | .onChange decode => decode { value := text, checked := false }
    | .onInput decode => decode { value := text, isComposing := false }
    | _ => none

/-- The message submitting the first matching form (default: the first form) sends. -/
def submit (view : Html Msg) (s : Selector := byTag "form") : Option Msg :=
  (find? view s).bind fun f => f.attrs.findSome? fun | .onSubmit msg => some msg | _ => none

/-- The message a key press on the first match sends. -/
def keyDown (view : Html Msg) (s : Selector) (key : String) : Option Msg :=
  (find? view s).bind fun f => f.attrs.findSome? fun | .onKeyDown decode _ => decode { key } | _ => none

/-! ## Snapshots -/

private def attrText : Attr Msg → Option String
  | .attr name value => some s!"{name}=\"{value}\""
  | .bool name value => if value then some name else none
  | .style entries => some ("style=\"" ++ "; ".intercalate (entries.map fun (k, v) => k ++ ": " ++ v) ++ "\"")
  | .styles values => some ("styles=\"" ++ " ".intercalate (values.map (·.name)) ++ "\"")
  | .onPress _ => some "onClick" | .onInput _ => some "onInput" | .onChange _ => some "onChange"
  | .onKeyDown _ _ => some "onKeyDown" | .onFocus _ => some "onFocus" | .onBlur _ => some "onBlur"
  | .onSubmit _ => some "onSubmit"

/-- An indented rendering of a view, for snapshot tests (handlers are shown by name). -/
partial def Html.pretty (view : Html Msg) (indent : String := "") : String :=
  match view with
  | .text value => indent ++ value ++ "\n"
  | .node tag attrs children =>
    let open_ := " ".intercalate (tag :: attrs.filterMap attrText)
    if children.isEmpty then indent ++ "<" ++ open_ ++ " />\n"
    else indent ++ "<" ++ open_ ++ ">\n" ++ String.join (children.map (·.pretty (indent ++ "  "))) ++ indent ++ "</" ++ tag ++ ">\n"
  | .keyed key child => indent ++ "[key " ++ key ++ "]\n" ++ child.pretty (indent ++ "  ")
  | .embed child => indent ++ "<embed " ++ child.key ++ " />\n"
  | .lazy key v => indent ++ "[lazy " ++ key ++ "]\n" ++ (v ()).pretty (indent ++ "  ")
  | .none => ""

end LeanReact.Program
