import LeanReact.Style

/-! # Attributes of a declarative view

Attributes are data. An event attribute holds a pure decoder from the event's payload (the
same payload types as the hook API: `PressEvent`, `InputEvent`, `KeyEvent`, …) to an optional
message; the host dispatches the message, so a handler can never run code. -/

namespace LeanReact.Program

inductive Attr (Msg : Type) where
  | attr (name value : String)
  | bool (name : String) (value : Bool)
  /-- React camelCase property names and CSS values. -/
  | style (entries : List (String × String))
  /-- Generated class names (see `LeanReact.Style`). -/
  | styles (values : List Style)
  | onPress (decode : PressEvent → Option Msg)
  | onInput (decode : InputEvent → Option Msg)
  | onChange (decode : ChangeEvent → Option Msg)
  /-- `prevent` decides synchronously whether to stop the browser default. -/
  | onKeyDown (decode : KeyEvent → Option Msg) (prevent : KeyEvent → Bool)
  | onFocus (decode : FocusEvent → Option Msg)
  | onBlur (decode : FocusEvent → Option Msg)
  /-- A form submission: the default (navigation) is always prevented. -/
  | onSubmit (msg : Msg)

namespace Attr

def map (f : α → β) : Attr α → Attr β
  | .attr name value => .attr name value
  | .bool name value => .bool name value
  | .style entries => .style entries
  | .styles values => .styles values
  | .onPress decode => .onPress fun e => (decode e).map f
  | .onInput decode => .onInput fun e => (decode e).map f
  | .onChange decode => .onChange fun e => (decode e).map f
  | .onKeyDown decode prevent => .onKeyDown (fun e => (decode e).map f) prevent
  | .onFocus decode => .onFocus fun e => (decode e).map f
  | .onBlur decode => .onBlur fun e => (decode e).map f
  | .onSubmit msg => .onSubmit (f msg)

end Attr

/-! ## Typed helpers -/

def cls (name : String) : Attr Msg := .attr "className" name
/-- The element's `id` (named so that `id` stays core's identity function in patterns). -/
def elementId (value : String) : Attr Msg := .attr "id" value
def role (value : String) : Attr Msg := .attr "role" value
def ariaLabel (value : String) : Attr Msg := .attr "aria-label" value
def href (value : String) : Attr Msg := .attr "href" value
def placeholder (value : String) : Attr Msg := .attr "placeholder" value
def type_ (value : String) : Attr Msg := .attr "type" value
def name (value : String) : Attr Msg := .attr "name" value
def htmlFor (value : String) : Attr Msg := .attr "htmlFor" value
def dataAttr (key value : String) : Attr Msg := .attr ("data-" ++ key) value
/-- A controlled control's value. -/
def value (text : String) : Attr Msg := .attr "value" text
def checked (on : Bool) : Attr Msg := .bool "checked" on
def disabled (on : Bool) : Attr Msg := .bool "disabled" on
def ariaSelected (on : Bool) : Attr Msg := .attr "aria-selected" (if on then "true" else "false")
def ariaPressed (on : Bool) : Attr Msg := .attr "aria-pressed" (if on then "true" else "false")
def styled (values : List Style) : Attr Msg := .styles values
def inline (rules : Inline) : Attr Msg := .style rules.entries.toList

/-- A click (or a press of Enter/Space on a button) sends `msg`. -/
def onClick (msg : Msg) : Attr Msg := .onPress fun _ => some msg
/-- Each edit sends the control's text (React's `onChange`, which fires on every edit). -/
def onInput (toMsg : String → Msg) : Attr Msg := .onChange fun e => some (toMsg e.value)
/-- A checkbox change sends its checked state. -/
def onCheck (toMsg : Bool → Msg) : Attr Msg := .onChange fun e => some (toMsg e.checked)
def onKeyDown (decode : KeyEvent → Option Msg) (prevent : KeyEvent → Bool := fun _ => false) : Attr Msg :=
  .onKeyDown decode prevent
def onSubmit (msg : Msg) : Attr Msg := .onSubmit msg
def onBlur (msg : Msg) : Attr Msg := .onBlur fun _ => some msg

end LeanReact.Program
