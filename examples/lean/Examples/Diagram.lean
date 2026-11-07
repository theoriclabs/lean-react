import LeanReact
import LeanReact.Compiler

/-! SVG without `Float`: an architecture diagram with arrows between boxes, and a timeline that
scrubs when dragged and zooms with the wheel. Coordinates are integer user units of a `viewBox`;
pointer positions arrive in CSS pixels with the target's size, so mapping a position to a cycle
is integer arithmetic. -/

namespace Examples.Diagram
open LeanReact

/-! ## Architecture diagram -/

structure Box where
  id : String
  label : String
  x : Int
  y : Int

structure Arrow where
  source : String
  target : String
  label : String

def boxes : Array Box := #[
  ⟨"memory", "Global memory", 10, 40⟩, ⟨"registers", "Registers", 270, 40⟩,
  ⟨"alu", "ALU", 530, 40⟩, ⟨"shared", "Shared memory", 270, 150⟩]

def arrows : Array Arrow := #[
  ⟨"memory", "registers", "LOAD4"⟩, ⟨"registers", "alu", "operands"⟩, ⟨"alu", "shared", "WRITE4"⟩]

def boxWidth : Nat := 160
def boxHeight : Nat := 50

/-- The arrow from the right edge of `a` to the left edge of `b`, or from the bottom of `a` to the
right of `b` when `b` is lower. -/
def connect (a b : Box) : Int × Int × Int × Int :=
  if b.y > a.y then (a.x + boxWidth / 2, a.y + boxHeight, b.x + boxWidth, b.y + boxHeight / 2)
  else (a.x + boxWidth, a.y + boxHeight / 2, b.x, b.y + boxHeight / 2)

def ArchitectureDiagram : Component Unit := Component.named "ArchitectureDiagram" <| component fun _ => do
  let find := fun id => (boxes.filter (·.id == id))[0]?
  pure <| SVG.svg {
      viewBox := some ⟨0, 0, 700, 220⟩
      role := some "img"
      ariaLabel := some "Data path"
      className := some "diagram" } #[
    SVG.defs {} #[SVG.arrowhead "arrow"],
    SVG.g {} (boxes.map fun box => SVG.g { data := #[("box", box.id)] } #[
      SVG.rect {
        x := box.x, y := box.y, width := boxWidth, height := boxHeight, rx := 6
        fill := some "none", stroke := some "currentColor", strokeWidth := some 2 },
      SVG.text { x := box.x + boxWidth / 2, y := box.y + 30, anchor := .middle } #[text box.label]]),
    SVG.g {} (arrows.map fun arrow => match find arrow.source, find arrow.target with
      | none, _ | _, none => empty
      | some a, some b =>
      let (x1, y1, x2, y2) := connect a b
      SVG.g { data := #[("arrow", arrow.source ++ "->" ++ arrow.target)] } #[
        SVG.line { x1, y1, x2, y2, stroke := some "currentColor", strokeWidth := some 2, markerEnd := some "arrow" },
        -- A level arrow's label sits above it; a sloping one's beside its midpoint.
        if y1 == y2 then SVG.text { x := (x1 + x2) / 2, y := y1 - 8, anchor := .middle } #[text arrow.label]
        else SVG.text { x := (x1 + x2) / 2 + 12, y := (y1 + y2) / 2 } #[text arrow.label]])]

/-! ## Timeline -/

/-- One busy interval of a unit, in cycles `[start, stop)`. -/
structure Interval where
  start : Nat
  stop : Nat
  deriving Repr, BEq

def total : Nat := 4096
def minSpan : Nat := 16
def width : Nat := 1000

/-- A deterministic trace: 256 intervals of varying length. -/
def trace : Array Interval := (Array.range 256).map fun i =>
  let start := i * 16
  ⟨start, start + 4 + (i * 7) % 11⟩

structure Window where
  start : Nat := 0
  span : Nat := total
  deriving Repr, BEq

/-- The cycle under a pointer at `x` of `pixels` (the target's width). -/
def Window.cycleAt (window : Window) (x pixels : Int) : Nat :=
  if pixels ≤ 0 then window.start
  else min (total - 1) (window.start + (max 0 x).toNat * window.span / pixels.toNat)

/-- Zoom in (`deltaY < 0`) or out by two, keeping the cycle under the pointer in place. -/
def Window.zoom (window : Window) (x pixels deltaY : Int) : Window :=
  let span := if deltaY < 0 then max minSpan (window.span / 2) else if deltaY > 0 then min total (window.span * 2) else window.span
  let anchor := window.cycleAt x pixels
  let offset := if pixels ≤ 0 then 0 else (max 0 x).toNat * span / pixels.toNat
  { start := min (total - span) (anchor - offset), span }

def Window.toUnits (window : Window) (cycle : Nat) : Int :=
  ((cycle : Int) - window.start) * width / window.span

def Timeline : Component Unit := Component.named "Timeline" <| component fun _ => do
  let window ← useState ({} : Window) "window"
  let cursor ← useState 0 "cursor"
  let dragging ← useCell false "dragging"
  let scrub := fun (event : PointerEvent) => cursor.set (window.value.cycleAt event.x event.width)
  let visible := trace.filter fun i => i.stop > window.value.start && i.start < window.value.start + window.value.span
  pure <| DOM.section { className := some "panel timeline" } #[
    DOM.h2 {} #[text "A timeline in SVG"],
    DOM.p { className := some "note" } #[text "Drag to scrub; use the wheel to zoom around the pointer."],
    SVG.svg {
        viewBox := some ⟨0, 0, width, 60⟩
        preserveAspectRatio := some "none"
        role := some "img"
        ariaLabel := some "Timeline"
        className := some "timeline-chart"
        data := #[("testid", "timeline")]
        capturePointer := true
        onPointerDown := some fun event => do
          let _ ← dragging.modifyGet fun _ => ((), true)
          scrub event
        onPointerMove := some fun event => do if ← dragging.read then scrub event
        onPointerUp := some fun _ => do let _ ← dragging.modifyGet fun _ => ((), false)
        onWheel := some fun event => window.set (window.value.zoom event.x event.width event.deltaY) } #[
      SVG.g { fill := some "currentColor" } (visible.map fun i =>
        let x := window.value.toUnits i.start
        SVG.rect { x, y := 10, width := max 1 (window.value.toUnits i.stop - x).toNat, height := 30 }),
      SVG.line {
        x1 := window.value.toUnits cursor.value, y1 := 0, x2 := window.value.toUnits cursor.value, y2 := 60
        stroke := some "#c0392b", strokeWidth := some 2, data := #[("testid", "timeline-cursor")] }],
    DOM.p { role := some "status", data := #[("testid", "timeline-cursor-text")] } #[text s!"Cycle {cursor.value}"],
    DOM.p { className := some "note", data := #[("testid", "timeline-window")] }
      #[text s!"Showing cycles {window.value.start}–{window.value.start + window.value.span} of {total} ({visible.size} intervals)"]]

/-- Both, as one playground example. -/
def Demo : Component Unit := Component.named "DiagramDemo" <| component fun _ => do
  pure <| DOM.div {} #[
    DOM.section { className := some "panel" } #[DOM.h2 {} #[text "An architecture diagram"], element ArchitectureDiagram ()],
    element Timeline ()]

end Examples.Diagram

-- `lake build` checks the example is portable (LeanJS), not only generation.
#leanreact_check Examples.Diagram.Demo
