import LeanReact
import LeanReact.Compiler

/-! Typed, scoped styles. The chart and the inspector each define a style named `use-read`,
and the chart's value bands and the legend each one named `held` — the names that collided
as global class names. As values they get distinct generated classes, so a bar colour cannot
leak into inspector text and the bands' `position: absolute` cannot reach the legend. -/

namespace Examples.Styles
open LeanReact

/-! ## Tokens -/

def accent : Token Color := ⟨"accent", .hex "#5b7f4b"⟩
def readColor : Token Color := ⟨"read", .hex "#3a6ea5"⟩
def gutter : Token Length := ⟨"gutter", .px 8⟩

/-! ## Chart styles -/

namespace Chart
def useRead : Style := {
  name := "use-read"
  base := { background := some readColor.color, height := some (.px 14), borderRadius := some (.px 2) }
  variants := [(.hover, { background := some accent.color })] }
def held : Style := {
  name := "held"
  base := { position := some "absolute", top := some (.px 0), height := some (.pct 100), background := some (.rgb 91 127 75) } }
def frame : Style := {
  name := "chart"
  base := { position := some "relative", height := some (.px 40), margin := some gutter.length } }
end Chart

/-! ## Inspector and legend styles, with the same names -/

namespace Inspector
def useRead : Style := { name := "use-read", base := { color := some readColor.color, fontSize := some (.rem 1) } }
end Inspector

namespace Legend
def held : Style := {
  name := "held"
  base := { display := some "inline-block", width := some (.px 12), height := some (.px 12), background := some (.rgb 91 127 75) } }
end Legend

def Demo : Component Unit := Component.named "StylesDemo" <| component fun _ => do
  let bands : Array (Nat × Nat) := #[(10, 30), (55, 20)]
  pure <| DOM.section { className := some "panel", data := #[("testid", "styles")] } #[
    DOM.h2 {} #[text "Scoped styles"],
    DOM.div { styles := #[Chart.frame], data := #[("testid", "chart")] } (
      bands.map (fun (left, width) => DOM.div {
        styles := #[Chart.held]
        inline := { left := some (.pct left), width := some (.pct width) }
        data := #[("testid", "band")] } #[]) ++
      #[DOM.div { styles := #[Chart.useRead], inline := { width := some (.pct 40) }, data := #[("testid", "bar")] } #[]]),
    DOM.p {} #[DOM.span { styles := #[Inspector.useRead], data := #[("testid", "inspector-read")] } #[text "LOAD4 reads r3"]],
    DOM.p { data := #[("testid", "legend")] } #[DOM.span { styles := #[Legend.held] } #[], text " held"]]

#leanreact_check Examples.Styles.Demo

-- Same names, different rules: different classes.
#guard Chart.useRead.className != Inspector.useRead.className
#guard Chart.held.className != Legend.held.className
#guard Chart.useRead.className.startsWith "use-read-"

end Examples.Styles
