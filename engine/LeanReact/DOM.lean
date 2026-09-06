import LeanReact.Core

namespace LeanReact.DOM

/-- Common attributes have typed event payloads; input-only props are kept on InputProps. -/
structure Props where
  id : Option String := none
  className : Option String := none
  title : Option String := none
  role : Option String := none
  ariaLabel : Option String := none
  onClick : Option (PressEvent → Action Unit) := none
  onKeyDown : Option (KeyEvent → Action Unit) := none

private def optionalString (name : String) (value : Option String) : Array Attribute :=
  match value with
  | none => #[]
  | some value => #[.string name value]

def Props.attributes (props : Props) : Array Attribute :=
  optionalString "id" props.id ++ optionalString "className" props.className ++
  optionalString "title" props.title ++ optionalString "role" props.role ++
  optionalString "aria-label" props.ariaLabel ++
  (match props.onClick with | none => #[] | some f => #[.press f]) ++
  (match props.onKeyDown with | none => #[] | some f => #[.keyDown f])

def div (props : Props := {}) (children : Array Element := #[]) : Element := node "div" props.attributes children
def span (props : Props := {}) (children : Array Element := #[]) : Element := node "span" props.attributes children
def p (props : Props := {}) (children : Array Element := #[]) : Element := node "p" props.attributes children
def h1 (props : Props := {}) (children : Array Element := #[]) : Element := node "h1" props.attributes children
def h2 (props : Props := {}) (children : Array Element := #[]) : Element := node "h2" props.attributes children
def «section» (props : Props := {}) (children : Array Element := #[]) : Element := node "section" props.attributes children
def article (props : Props := {}) (children : Array Element := #[]) : Element := node "article" props.attributes children
def ul (props : Props := {}) (children : Array Element := #[]) : Element := node "ul" props.attributes children
def li (props : Props := {}) (children : Array Element := #[]) : Element := node "li" props.attributes children

inductive ButtonType where
  | button | submit | reset
  deriving Repr, BEq

def ButtonType.value : ButtonType → String
  | .button => "button" | .submit => "submit" | .reset => "reset"

structure ButtonProps extends Props where
  disabled : Bool := false
  type : ButtonType := .button
  onPress : Option (Action Unit) := none

def button (props : ButtonProps := {}) (children : Array Element := #[]) : Element :=
  node "button" (props.toProps.attributes ++ #[.bool "disabled" props.disabled, .string "type" props.type.value] ++
    (match props.onPress with | none => #[] | some work => #[.press fun _ => work])) children

inductive InputType where
  | text | email | password | search | checkbox | number
  deriving Repr, BEq

def InputType.value : InputType → String
  | .text => "text" | .email => "email" | .password => "password"
  | .search => "search" | .checkbox => "checkbox" | .number => "number"

structure InputProps extends Props where
  type : InputType := .text
  value : Option String := none
  defaultValue : Option String := none
  checked : Option Bool := none
  defaultChecked : Option Bool := none
  placeholder : Option String := none
  disabled : Bool := false
  readOnly : Bool := false
  onChange : Option (ChangeEvent → Action Unit) := none

private def optionalBool (name : String) (value : Option Bool) : Array Attribute :=
  match value with | none => #[] | some value => #[.bool name value]

def input (props : InputProps := {}) : Element :=
  node "input" (props.toProps.attributes ++ #[.string "type" props.type.value, .bool "disabled" props.disabled,
      .bool "readOnly" props.readOnly] ++
    optionalString "value" props.value ++ optionalString "defaultValue" props.defaultValue ++
    optionalString "placeholder" props.placeholder ++ optionalBool "checked" props.checked ++
    optionalBool "defaultChecked" props.defaultChecked ++
    (match props.onChange with | none => #[] | some f => #[.change f])) #[]

structure LabelProps extends Props where
  htmlFor : String

def label (props : LabelProps) (children : Array Element) : Element :=
  node "label" (props.toProps.attributes.push (.string "htmlFor" props.htmlFor)) children

structure AnchorProps extends Props where
  href : String

def a (props : AnchorProps) (children : Array Element) : Element :=
  node "a" (props.toProps.attributes.push (.string "href" props.href)) children

end LeanReact.DOM
