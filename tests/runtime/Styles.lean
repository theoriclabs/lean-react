/- Issue #66: typed lengths, styles as values with generated class names, static extraction. -/
import LeanReact
open LeanReact

-- Typed lengths: `.px 12` type-checks.
example : Inline := { left := some (.px 12) }
example : Inline := { width := some (.calc (.pct 100) .sub (.px 8)) }

-- A bare string is not a length.
/--
error: Application type mismatch: The argument
  "12"
has type
  String
but is expected to have type
  Length
in the application
  some "12"
-/
#guard_msgs in
example : Inline := { left := some "12" }

#guard (Length.calc (.pct 100) .sub (.px 8)).text == "calc(100% - 8px)"
#guard (Inline.entries { left := some (.px 12), fontSize := some (.rem 2), color := some (.hex "#fff") })
  == #[("left", "12px"), ("fontSize", "2rem"), ("color", "#fff")]
#guard cssProperty "borderTopLeftRadius" == "border-top-left-radius"

def chartBar : Style := { name := "use-read", base := { background := some (.hex "#36c") } }
def inspectorText : Style := { name := "use-read", base := { color := some (.hex "#36c") } }
def chartBarAgain : Style := { name := "use-read", base := { background := some (.hex "#36c") } }

-- Same name, different rules: different classes. Equal styles: one class.
#guard chartBar.className != inspectorText.className
#guard chartBar.className == chartBarAgain.className
#guard chartBar.className.startsWith "use-read-"
#guard ({ name := "1 odd name!" } : Style).className.startsWith "s1-odd-name--"

-- Extraction: tokens on :root, each class once, a variant as its selector.
def hovered : Style := { name := "link", variants := [(.hover, { color := some (.var "accent") }), (.selected, { color := some .currentColor })] }
#guard Stylesheet.extract [chartBar, chartBarAgain, hovered] [⟨"accent", "#5b7f4b"⟩] == .ok (
  ":root{--accent:#5b7f4b;}\n" ++
  s!".{chartBar.className}\{background:#36c;}\n" ++
  s!".{hovered.className}:hover\{color:var(--accent);}\n" ++
  s!".{hovered.className}[aria-selected=\"true\"]\{color:currentColor;}\n")

-- `Props.styles` adds generated classes after `className`; `inline` joins `style`.
#guard (DOM.Props.attributes { className := some "plain", styles := #[chartBar, inspectorText] }).any fun
  | .string "className" value => value == s!"plain {chartBar.className} {inspectorText.className}"
  | _ => false
#guard (DOM.Props.attributes { style := #[(.top, "0")], inline := { left := some (.px 3) } }).any fun
  | .style entries => entries == #[("top", "0"), ("left", "3px")]
  | _ => false
