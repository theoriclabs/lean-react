import LeanReact.Core

namespace LeanReact.DOM

/-- Inline style properties, named as React expects them. A typo is a compile error; values stay strings. -/
inductive StyleProp where
  | alignItems | alignSelf | background | backgroundColor | border | borderBottom | borderColor
  | borderLeft | borderRadius | borderRight | borderTop | bottom | boxShadow | color | cursor
  | display | flex | flexBasis | flexDirection | flexGrow | flexShrink | flexWrap | fontFamily
  | fontSize | fontStyle | fontWeight | gap | gridColumn | gridRow | gridTemplateColumns
  | gridTemplateRows | height | inset | justifyContent | left | letterSpacing | lineHeight
  | listStyle | margin | marginBottom | marginLeft | marginRight | marginTop | maxHeight | maxWidth
  | minHeight | minWidth | opacity | order | outline | overflow | overflowX | overflowY | padding
  | paddingBottom | paddingLeft | paddingRight | paddingTop | pointerEvents | position | resize
  | right | textAlign | textDecoration | textOverflow | textTransform | top | transform
  | transition | userSelect | verticalAlign | visibility | whiteSpace | width | zIndex
  deriving Repr, BEq, DecidableEq

def StyleProp.name : StyleProp → String
  | .alignItems => "alignItems" | .alignSelf => "alignSelf" | .background => "background"
  | .backgroundColor => "backgroundColor" | .border => "border" | .borderBottom => "borderBottom"
  | .borderColor => "borderColor" | .borderLeft => "borderLeft" | .borderRadius => "borderRadius"
  | .borderRight => "borderRight" | .borderTop => "borderTop" | .bottom => "bottom"
  | .boxShadow => "boxShadow" | .color => "color" | .cursor => "cursor" | .display => "display"
  | .flex => "flex" | .flexBasis => "flexBasis" | .flexDirection => "flexDirection"
  | .flexGrow => "flexGrow" | .flexShrink => "flexShrink" | .flexWrap => "flexWrap"
  | .fontFamily => "fontFamily" | .fontSize => "fontSize" | .fontStyle => "fontStyle"
  | .fontWeight => "fontWeight" | .gap => "gap" | .gridColumn => "gridColumn" | .gridRow => "gridRow"
  | .gridTemplateColumns => "gridTemplateColumns" | .gridTemplateRows => "gridTemplateRows"
  | .height => "height" | .inset => "inset" | .justifyContent => "justifyContent" | .left => "left"
  | .letterSpacing => "letterSpacing" | .lineHeight => "lineHeight" | .listStyle => "listStyle"
  | .margin => "margin" | .marginBottom => "marginBottom" | .marginLeft => "marginLeft"
  | .marginRight => "marginRight" | .marginTop => "marginTop" | .maxHeight => "maxHeight"
  | .maxWidth => "maxWidth" | .minHeight => "minHeight" | .minWidth => "minWidth"
  | .opacity => "opacity" | .order => "order" | .outline => "outline" | .overflow => "overflow"
  | .overflowX => "overflowX" | .overflowY => "overflowY" | .padding => "padding"
  | .paddingBottom => "paddingBottom" | .paddingLeft => "paddingLeft" | .paddingRight => "paddingRight"
  | .paddingTop => "paddingTop" | .pointerEvents => "pointerEvents" | .position => "position"
  | .resize => "resize" | .right => "right" | .textAlign => "textAlign"
  | .textDecoration => "textDecoration" | .textOverflow => "textOverflow"
  | .textTransform => "textTransform" | .top => "top" | .transform => "transform"
  | .transition => "transition" | .userSelect => "userSelect" | .verticalAlign => "verticalAlign"
  | .visibility => "visibility" | .whiteSpace => "whiteSpace" | .width => "width" | .zIndex => "zIndex"

/-- Common attributes have typed event payloads; control-only props are kept on the control's props.
`onKeyDown` returns a `KeyOutcome`; handlers returning `Action Unit` coerce to `.continue`. -/
structure Props where
  id : Option String := none
  className : Option String := none
  title : Option String := none
  role : Option String := none
  ariaLabel : Option String := none
  ariaDescribedBy : Option String := none
  ariaLabelledBy : Option String := none
  ariaLive : Option String := none
  ariaExpanded : Option Bool := none
  ariaSelected : Option Bool := none
  ariaPressed : Option Bool := none
  ariaDisabled : Option Bool := none
  tabIndex : Option Int := none
  hidden : Bool := false
  /-- Rendered as `data-<key>="value"`. -/
  data : Array (String × String) := #[]
  style : Array (StyleProp × String) := #[]
  onClick : Option (PressEvent → Action Unit) := none
  onKeyDown : Option (KeyEvent → Action KeyOutcome) := none
  onKeyUp : Option (KeyEvent → Action Unit) := none
  onFocus : Option (FocusEvent → Action Unit) := none
  onBlur : Option (FocusEvent → Action Unit) := none
  onMouseEnter : Option (PressEvent → Action Unit) := none
  onMouseLeave : Option (PressEvent → Action Unit) := none
  onScroll : Option (ScrollEvent → Action Unit) := none

/-- Migration helper: an `Action Unit` key handler, made explicit, means `.continue`. -/
def onKeyDown' (handler : KeyEvent → Action Unit) : Option (KeyEvent → Action KeyOutcome) :=
  some fun event => (handler event).map fun _ => .continue

private def optionalString (name : String) (value : Option String) : Array Attribute :=
  match value with
  | none => #[]
  | some value => #[.string name value]

private def optionalBool (name : String) (value : Option Bool) : Array Attribute :=
  match value with | none => #[] | some value => #[.bool name value]

private def optionalNat (name : String) (value : Option Nat) : Array Attribute :=
  match value with | none => #[] | some value => #[.string name (toString value)]

private def optionalInt (name : String) (value : Option Int) : Array Attribute :=
  match value with | none => #[] | some value => #[.string name (toString value)]

private def handler (value : Option α) (wrap : α → Attribute) : Array Attribute :=
  match value with | none => #[] | some f => #[wrap f]

def Props.attributes (props : Props) : Array Attribute :=
  optionalString "id" props.id ++ optionalString "className" props.className ++
  optionalString "title" props.title ++ optionalString "role" props.role ++
  optionalString "aria-label" props.ariaLabel ++ optionalString "aria-describedby" props.ariaDescribedBy ++
  optionalString "aria-labelledby" props.ariaLabelledBy ++ optionalString "aria-live" props.ariaLive ++
  optionalBool "aria-expanded" props.ariaExpanded ++ optionalBool "aria-selected" props.ariaSelected ++
  optionalBool "aria-pressed" props.ariaPressed ++ optionalBool "aria-disabled" props.ariaDisabled ++
  optionalInt "tabIndex" props.tabIndex ++ (if props.hidden then #[.bool "hidden" true] else #[]) ++
  props.data.map (fun (key, value) => Attribute.string s!"data-{key}" value) ++
  (if props.style.isEmpty then #[] else #[.style (props.style.map fun (prop, value) => (prop.name, value))]) ++
  handler props.onClick .press ++ handler props.onKeyDown .keyDown ++ handler props.onKeyUp .keyUp ++
  handler props.onFocus .focus ++ handler props.onBlur .blur ++
  handler props.onMouseEnter .mouseEnter ++ handler props.onMouseLeave .mouseLeave ++
  handler props.onScroll .scroll

def div (props : Props := {}) (children : Array Element := #[]) : Element := node "div" props.attributes children
def span (props : Props := {}) (children : Array Element := #[]) : Element := node "span" props.attributes children
def p (props : Props := {}) (children : Array Element := #[]) : Element := node "p" props.attributes children
def h1 (props : Props := {}) (children : Array Element := #[]) : Element := node "h1" props.attributes children
def h2 (props : Props := {}) (children : Array Element := #[]) : Element := node "h2" props.attributes children
def h3 (props : Props := {}) (children : Array Element := #[]) : Element := node "h3" props.attributes children
def h4 (props : Props := {}) (children : Array Element := #[]) : Element := node "h4" props.attributes children
def h5 (props : Props := {}) (children : Array Element := #[]) : Element := node "h5" props.attributes children
def h6 (props : Props := {}) (children : Array Element := #[]) : Element := node "h6" props.attributes children
def «section» (props : Props := {}) (children : Array Element := #[]) : Element := node "section" props.attributes children
def article (props : Props := {}) (children : Array Element := #[]) : Element := node "article" props.attributes children
def nav (props : Props := {}) (children : Array Element := #[]) : Element := node "nav" props.attributes children
def header (props : Props := {}) (children : Array Element := #[]) : Element := node "header" props.attributes children
def footer (props : Props := {}) (children : Array Element := #[]) : Element := node "footer" props.attributes children
def main (props : Props := {}) (children : Array Element := #[]) : Element := node "main" props.attributes children
def aside (props : Props := {}) (children : Array Element := #[]) : Element := node "aside" props.attributes children
def ul (props : Props := {}) (children : Array Element := #[]) : Element := node "ul" props.attributes children
def li (props : Props := {}) (children : Array Element := #[]) : Element := node "li" props.attributes children
def strong (props : Props := {}) (children : Array Element := #[]) : Element := node "strong" props.attributes children
def em (props : Props := {}) (children : Array Element := #[]) : Element := node "em" props.attributes children
def code (props : Props := {}) (children : Array Element := #[]) : Element := node "code" props.attributes children
def pre (props : Props := {}) (children : Array Element := #[]) : Element := node "pre" props.attributes children
def kbd (props : Props := {}) (children : Array Element := #[]) : Element := node "kbd" props.attributes children
def summary (props : Props := {}) (children : Array Element := #[]) : Element := node "summary" props.attributes children
def table (props : Props := {}) (children : Array Element := #[]) : Element := node "table" props.attributes children
def thead (props : Props := {}) (children : Array Element := #[]) : Element := node "thead" props.attributes children
def tbody (props : Props := {}) (children : Array Element := #[]) : Element := node "tbody" props.attributes children
def tr (props : Props := {}) (children : Array Element := #[]) : Element := node "tr" props.attributes children

structure CellProps extends Props where
  colSpan : Option Nat := none
  rowSpan : Option Nat := none
  /-- `th` only: `col`, `row`, `colgroup` or `rowgroup`. -/
  scope : Option String := none

private def cellAttributes (props : CellProps) : Array Attribute :=
  props.toProps.attributes ++ optionalNat "colSpan" props.colSpan ++ optionalNat "rowSpan" props.rowSpan ++
  optionalString "scope" props.scope

def th (props : CellProps := {}) (children : Array Element := #[]) : Element := node "th" (cellAttributes props) children
def td (props : CellProps := {}) (children : Array Element := #[]) : Element := node "td" (cellAttributes props) children

/-- `open` is the HTML attribute name; Lean needs the guillemets because it is a keyword. -/
structure DisclosureProps extends Props where
  «open» : Bool := false

def dialog (props : DisclosureProps := {}) (children : Array Element := #[]) : Element :=
  node "dialog" (props.toProps.attributes.push (.bool "open" props.«open»)) children
def details (props : DisclosureProps := {}) (children : Array Element := #[]) : Element :=
  node "details" (props.toProps.attributes.push (.bool "open" props.«open»)) children

structure ImgProps extends Props where
  src : String
  /-- Required: use `""` only for purely decorative images. -/
  alt : String
  width : Option Nat := none
  height : Option Nat := none

def img (props : ImgProps) : Element :=
  node "img" (props.toProps.attributes ++ #[.string "src" props.src, .string "alt" props.alt] ++
    optionalNat "width" props.width ++ optionalNat "height" props.height) #[]

inductive ButtonType where
  | button | submit | reset
  deriving Repr, BEq

def ButtonType.value : ButtonType → String
  | .button => "button" | .submit => "submit" | .reset => "reset"

structure ButtonProps extends Props where
  disabled : Bool := false
  type : ButtonType := .button
  autoFocus : Bool := false
  onPress : Option (Action Unit) := none

def button (props : ButtonProps := {}) (children : Array Element := #[]) : Element :=
  node "button" (props.toProps.attributes ++ #[.bool "disabled" props.disabled, .string "type" props.type.value] ++
    (if props.autoFocus then #[.bool "autoFocus" true] else #[]) ++
    (match props.onPress with | none => #[] | some work => #[.press fun _ => work])) children

/-- Attributes shared by text-entry controls (`input`, `textarea`). -/
structure FieldProps extends Props where
  name : Option String := none
  placeholder : Option String := none
  disabled : Bool := false
  readOnly : Bool := false
  required : Bool := false
  autoFocus : Bool := false
  autoComplete : Option String := none
  spellCheck : Option Bool := none
  maxLength : Option Nat := none
  /-- IME-safe live text; fires on every edit, including during composition. -/
  onInput : Option (InputEvent → Action Unit) := none
  onPaste : Option (PasteEvent → Action Unit) := none

private def fieldAttributes (props : FieldProps) : Array Attribute :=
  props.toProps.attributes ++ #[.bool "disabled" props.disabled, .bool "readOnly" props.readOnly] ++
  (if props.required then #[.bool "required" true] else #[]) ++
  (if props.autoFocus then #[.bool "autoFocus" true] else #[]) ++
  optionalString "name" props.name ++ optionalString "placeholder" props.placeholder ++
  optionalString "autoComplete" props.autoComplete ++ optionalBool "spellCheck" props.spellCheck ++
  optionalNat "maxLength" props.maxLength ++ handler props.onInput .input ++ handler props.onPaste .paste

inductive InputType where
  | text | email | password | search | checkbox | number | url | tel | date | time | range | radio
  deriving Repr, BEq

def InputType.value : InputType → String
  | .text => "text" | .email => "email" | .password => "password"
  | .search => "search" | .checkbox => "checkbox" | .number => "number"
  | .url => "url" | .tel => "tel" | .date => "date" | .time => "time" | .range => "range" | .radio => "radio"

structure InputProps extends FieldProps where
  type : InputType := .text
  value : Option String := none
  defaultValue : Option String := none
  checked : Option Bool := none
  defaultChecked : Option Bool := none
  /-- Numeric and date constraints are passed through as strings. -/
  min : Option String := none
  max : Option String := none
  step : Option String := none
  onChange : Option (ChangeEvent → Action Unit) := none

def input (props : InputProps := {}) : Element :=
  node "input" (fieldAttributes props.toFieldProps ++ #[.string "type" props.type.value] ++
    optionalString "value" props.value ++ optionalString "defaultValue" props.defaultValue ++
    optionalBool "checked" props.checked ++ optionalBool "defaultChecked" props.defaultChecked ++
    optionalString "min" props.min ++ optionalString "max" props.max ++ optionalString "step" props.step ++
    handler props.onChange .change) #[]

structure TextAreaProps extends FieldProps where
  value : Option String := none
  defaultValue : Option String := none
  rows : Option Nat := none
  cols : Option Nat := none
  onChange : Option (ChangeEvent → Action Unit) := none

def textarea (props : TextAreaProps := {}) : Element :=
  node "textarea" (fieldAttributes props.toFieldProps ++
    optionalString "value" props.value ++ optionalString "defaultValue" props.defaultValue ++
    optionalNat "rows" props.rows ++ optionalNat "cols" props.cols ++ handler props.onChange .change) #[]

/-- `onChange` receives the selected option's `value`. -/
structure SelectProps extends Props where
  name : Option String := none
  value : Option String := none
  defaultValue : Option String := none
  disabled : Bool := false
  required : Bool := false
  autoFocus : Bool := false
  onChange : Option (ChangeEvent → Action Unit) := none

def select (props : SelectProps := {}) (options : Array Element := #[]) : Element :=
  node "select" (props.toProps.attributes ++ #[.bool "disabled" props.disabled] ++
    (if props.required then #[.bool "required" true] else #[]) ++
    (if props.autoFocus then #[.bool "autoFocus" true] else #[]) ++
    optionalString "name" props.name ++ optionalString "value" props.value ++
    optionalString "defaultValue" props.defaultValue ++ handler props.onChange .change) options

structure OptionProps extends Props where
  value : String
  disabled : Bool := false

def «option» (props : OptionProps) (children : Array Element := #[]) : Element :=
  node "option" (props.toProps.attributes ++ #[.string "value" props.value, .bool "disabled" props.disabled]) children

/-- A LeanReact form never navigates: the browser's submit default is always prevented, then `onSubmit`
runs. Enter in a field and `type := .submit` buttons both submit. Use `node "form"` for native submission. -/
structure FormProps extends Props where
  name : Option String := none
  autoComplete : Option String := none
  noValidate : Bool := false
  onSubmit : Action Unit := pure ()

def form (props : FormProps := {}) (children : Array Element := #[]) : Element :=
  node "form" (props.toProps.attributes ++ optionalString "name" props.name ++
    optionalString "autoComplete" props.autoComplete ++
    (if props.noValidate then #[.bool "noValidate" true] else #[]) ++ #[.submit props.onSubmit]) children

structure LabelProps extends Props where
  htmlFor : String

def label (props : LabelProps) (children : Array Element) : Element :=
  node "label" (props.toProps.attributes.push (.string "htmlFor" props.htmlFor)) children

structure AnchorProps extends Props where
  href : String
  target : Option String := none
  rel : Option String := none

def a (props : AnchorProps) (children : Array Element) : Element :=
  node "a" (props.toProps.attributes.push (.string "href" props.href) ++ optionalString "target" props.target ++
    optionalString "rel" props.rel) children

end LeanReact.DOM
