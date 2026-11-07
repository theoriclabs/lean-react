import LeanReact.Core

/-! # Typed, scoped styles

```
def bar : Style := {
  name := "bar"
  base := { height := some (.px 12), background := some accent.color, borderRadius := some (.px 2) }
  variants := [(.hover, { background := some (.hex "#3d5a30") })] }

DOM.div { styles := #[bar], inline := { left := some (.px offset), width := some (.pct 40) } } #[]
```

* A `Style` is a value: its rules and its variants (hover, focus, selected, …). Elements take it
  in `styles`, never by class name, and its class name is generated from its name and its
  rules (`bar-3071552402`), so two styles cannot share a class by accident: a style written
  for chart bars applies only where it is passed.
* `Stylesheet.extract` (or `#leanreact_css` from `LeanReact.Compiler`) writes one CSS file for
  the styles and tokens of an application; equal styles collapse to one rule, and two
  different styles can never produce one class name.
* Tokens (`Token Length`, `Token Color`, `Token String`) are named values exported as CSS
  custom properties, so plain stylesheets can use them (`var(--accent)`).
* Lengths and colours are typed: `left := some (.px 12)` type-checks; `left := some "12"` does
  not. Plain `className` strings and `style` entries still work beside them.

Values are integers (no `Float`): `.px`, `.pct`, `.rem`, `.em`, `.vh`, `.vw`, `.fr`, and
`.calc` to combine them. -/

namespace LeanReact

inductive CalcOp where
  | add | sub
  deriving Repr, BEq

/-- A plain dimension, the operand of `Length.calc`. -/
inductive Dim where
  | px (n : Int)
  | pct (n : Int)
  | rem (n : Nat)
  | em (n : Nat)
  | vh (n : Nat)
  | vw (n : Nat)
  deriving Repr, BEq

def Dim.text : Dim → String
  | .px n => s!"{n}px" | .pct n => s!"{n}%" | .rem n => s!"{n}rem" | .em n => s!"{n}em"
  | .vh n => s!"{n}vh" | .vw n => s!"{n}vw"

/-- A CSS length. -/
inductive Length where
  | px (n : Int)
  | pct (n : Int)
  | rem (n : Nat)
  | em (n : Nat)
  | vh (n : Nat)
  | vw (n : Nat)
  | fr (n : Nat)
  | auto
  /-- A length token's custom property. -/
  | var (token : String)
  /-- `calc(left ± right)`, e.g. `.calc (.pct 100) .sub (.px 8)`. -/
  | calc (left : Dim) (op : CalcOp) (right : Dim)
  deriving Repr, BEq

def Length.text : Length → String
  | .px n => s!"{n}px" | .pct n => s!"{n}%" | .rem n => s!"{n}rem" | .em n => s!"{n}em"
  | .vh n => s!"{n}vh" | .vw n => s!"{n}vw" | .fr n => s!"{n}fr" | .auto => "auto"
  | .var token => s!"var(--{token})"
  | .calc a op b => "calc(" ++ a.text ++ (if op == .add then " + " else " - ") ++ b.text ++ ")"

/-- A CSS colour. -/
inductive Color where
  | hex (value : String)
  | rgb (r g b : Nat)
  | named (name : String)
  | transparent
  | currentColor
  /-- A colour token's custom property. -/
  | var (token : String)
  deriving Repr, BEq

def Color.text : Color → String
  | .hex value => value | .rgb r g b => s!"rgb({r} {g} {b})" | .named name => name
  | .transparent => "transparent" | .currentColor => "currentColor" | .var token => s!"var(--{token})"

/-- A design token: a named value, exported as the custom property `--name`. -/
structure Token (α : Type) where
  name : String
  value : α

def Token.length (token : Token Length) : Length := .var token.name
def Token.color (token : Token Color) : Color := .var token.name
def Token.font (token : Token String) : String := s!"var(--{token.name})"

/-- A token as its custom property declaration. -/
structure TokenDecl where
  name : String
  value : String
  deriving Repr, BEq

def Token.declLength (t : Token Length) : TokenDecl := ⟨t.name, t.value.text⟩
def Token.declColor (t : Token Color) : TokenDecl := ⟨t.name, t.value.text⟩
def Token.declFont (t : Token String) : TokenDecl := ⟨t.name, t.value⟩

/-- Typed style declarations. `other` takes any further `(camelCaseProperty, value)` pairs. -/
structure Inline where
  position : Option String := none
  display : Option String := none
  left : Option Length := none
  top : Option Length := none
  right : Option Length := none
  bottom : Option Length := none
  width : Option Length := none
  height : Option Length := none
  minWidth : Option Length := none
  minHeight : Option Length := none
  maxWidth : Option Length := none
  maxHeight : Option Length := none
  margin : Option Length := none
  padding : Option Length := none
  gap : Option Length := none
  fontSize : Option Length := none
  lineHeight : Option Length := none
  borderRadius : Option Length := none
  borderWidth : Option Length := none
  color : Option Color := none
  background : Option Color := none
  borderColor : Option Color := none
  fontFamily : Option String := none
  other : Array (String × String) := #[]
  deriving Repr, BEq

private def entry (name : String) (value : Option String) : Array (String × String) :=
  match value with | some value => #[(name, value)] | none => #[]

/-- The declarations, as React camelCase property names and CSS values. -/
def Inline.entries (s : Inline) : Array (String × String) :=
  entry "position" s.position ++ entry "display" s.display ++
  entry "left" (s.left.map Length.text) ++ entry "top" (s.top.map Length.text) ++
  entry "right" (s.right.map Length.text) ++ entry "bottom" (s.bottom.map Length.text) ++
  entry "width" (s.width.map Length.text) ++ entry "height" (s.height.map Length.text) ++
  entry "minWidth" (s.minWidth.map Length.text) ++ entry "minHeight" (s.minHeight.map Length.text) ++
  entry "maxWidth" (s.maxWidth.map Length.text) ++ entry "maxHeight" (s.maxHeight.map Length.text) ++
  entry "margin" (s.margin.map Length.text) ++ entry "padding" (s.padding.map Length.text) ++
  entry "gap" (s.gap.map Length.text) ++ entry "fontSize" (s.fontSize.map Length.text) ++
  entry "lineHeight" (s.lineHeight.map Length.text) ++ entry "borderRadius" (s.borderRadius.map Length.text) ++
  entry "borderWidth" (s.borderWidth.map Length.text) ++
  entry "color" (s.color.map Color.text) ++ entry "background" (s.background.map Color.text) ++
  entry "borderColor" (s.borderColor.map Color.text) ++ entry "fontFamily" s.fontFamily ++ s.other

/-- Where a variant's rules apply. -/
inductive Variant where
  | hover | focus | focusVisible | active | disabled
  /-- `aria-selected="true"`, `aria-pressed="true"`, `aria-expanded="true"`. -/
  | selected | pressed | expanded
  deriving Repr, BEq

def Variant.selector : Variant → String
  | .hover => ":hover" | .focus => ":focus" | .focusVisible => ":focus-visible" | .active => ":active"
  | .disabled => ":disabled" | .selected => "[aria-selected=\"true\"]"
  | .pressed => "[aria-pressed=\"true\"]" | .expanded => "[aria-expanded=\"true\"]"

/-- A style as a value: rules and variants, under a generated class name. -/
structure Style where
  /-- Readable part of the class name; not required to be unique. -/
  name : String
  base : Inline := {}
  variants : List (Variant × Inline) := []
  deriving Repr, BEq

/-- `fontSize` → `font-size`. -/
def cssProperty (name : String) : String :=
  String.ofList (name.toList.foldl (fun (out : List Char) c =>
    if c.isUpper then out ++ ['-', c.toLower] else out ++ [c]) [])

private def block (rules : Inline) : String :=
  String.join (rules.entries.toList.map fun (name, value) => cssProperty name ++ ":" ++ value ++ ";")

/-- The rules without a selector, which determine the class name. -/
def Style.signature (style : Style) : String :=
  block style.base ++ String.join (style.variants.map fun (v, rules) => v.selector ++ "{" ++ block rules ++ "}")

/-- A 32-bit polynomial hash (portable: no bitwise operations). -/
private def hash32 (text : String) : Nat :=
  text.toList.foldl (fun h c => (h * 31 + c.toNat) % 4294967296) 7

private def slug (name : String) : String :=
  let chars := name.toList.map fun c => if c.isAlphanum || c == '-' || c == '_' then c else '-'
  match chars with
  | [] => "s"
  | first :: _ => String.ofList (if first.isDigit || first == '-' then 's' :: chars else chars)

/-- The generated class name: the style's name, then a hash of its name and rules. -/
def Style.className (style : Style) : String :=
  slug style.name ++ "-" ++ toString (hash32 (style.name ++ "\n" ++ style.signature))

/-- The style's CSS rules. -/
def Style.css (style : Style) : String :=
  let cls := "." ++ style.className
  let base := if style.base.entries.isEmpty then "" else cls ++ "{" ++ block style.base ++ "}\n"
  base ++ String.join (style.variants.map fun (v, rules) => cls ++ v.selector ++ "{" ++ block rules ++ "}\n")

/-- One stylesheet for an application: tokens as custom properties on `:root`, then each style
once. Equal styles collapse; two different styles with one class name are an error. -/
def Stylesheet.extract (styles : List Style) (tokens : List TokenDecl := []) : Except String String := do
  let mut seen : List (String × Style) := []
  for style in styles do
    match seen.lookup style.className with
    | some other => if other != style then throw s!"two styles share the class {style.className}"
    | none => seen := seen ++ [(style.className, style)]
  let root := if tokens.isEmpty then "" else
    ":root{" ++ String.join (tokens.map fun t => "--" ++ t.name ++ ":" ++ t.value ++ ";") ++ "}\n"
  return root ++ String.join (seen.map (·.2.css))

end LeanReact
