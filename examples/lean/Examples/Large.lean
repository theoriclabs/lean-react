import LeanReact
import LeanReact.Compiler

/-! Large views: a 100,000-row list and a 3,000 × 200 grid that render only what is visible, and
a canvas timeline of a million intervals whose clicks map back to an interval in Lean. -/

namespace Examples.Large
open LeanReact

/-! ## A long list -/

def EventList : Component Unit := Component.named "LargeEventList" <| component fun _ => do
  let count ← useState 100000 "count"
  pure <| DOM.section { className := some "panel" } #[
    DOM.h2 {} #[text "100,000 rows, a few dozen elements"],
    virtualList {
      count := count.value, rowHeight := 28, height := 280, ariaLabel := some "Events"
      className := some "virtual-list"
      row := fun i => DOM.span {} #[text s!"Event {i} · cycle {i * 16}"] },
    DOM.div { className := some "toolbar" } #[
      DOM.button { onPress := some (count.modify (· + 1000)) } #[text "Add 1,000 rows"]],
    DOM.p { className := some "note", data := #[("testid", "event-count")] } #[text s!"{count.value} rows"]]

/-! ## A wide grid with row labels -/

def EventGrid : Component Unit := Component.named "LargeEventGrid" <| component fun _ => do
  pure <| DOM.section { className := some "panel" } #[
    DOM.h2 {} #[text "3,000 × 200 cells, with a sticky label column"],
    virtualGrid {
      rowCount := 3000, columnCount := 200, rowHeight := 24, columnWidth := 72
      height := 240, width := 640, stickyColumns := 1, ariaLabel := some "Units by cycle"
      className := some "virtual-grid"
      cell := fun r c => if c == 0 then DOM.strong {} #[text s!"Unit {r}"] else text (toString ((r * 31 + c * 17) % 100)) }]

/-! ## A dense timeline on a canvas -/

/-- The imperative API of the `"timeline-canvas"` widget (examples/adapters/example-timeline.mjs). -/
structure TimelineOps where
  /-- Draws intervals `[starts[i], stops[i])` over `[0, total)`; reports how many it drew. -/
  draw : Array Nat → Array Nat → Nat → Action (HandleResult Nat)

def TimelineOps.silent : TimelineOps := { draw := fun starts _ _ => pure (.ok starts.size) }

structure TimelineCanvasProps where
  width : Nat := 960
  height : Nat := 48

def timelineCanvas (props : TimelineCanvasProps) (onReady : Handle TimelineOps → Action Unit)
    (reference : TimelineOps := .silent) : Element :=
  foreign "timeline-canvas" {
    props, onReady
    reference := {
      render := fun p => node "canvas" #[.string "width" (toString p.width), .string "height" (toString p.height)] #[]
      ops := some fun _ => reference } }

def intervalCount : Nat := 1000000
def total : Nat := intervalCount * 4

/-- Interval `i` covers `[4i, 4i + 1 + (7i mod 3))`: a million intervals with gaps between them.
Functions, not constants, so the arrays are built when the timeline mounts, not at module load. -/
def makeStarts (count : Nat) : Array Nat := (Array.range count).map (· * 4)
def makeStops (count : Nat) : Array Nat := (Array.range count).map fun i => i * 4 + 1 + (i * 7) % 3

/-- The last interval starting at or before `cycle`, by binary search (a loop: every call is a
tail call). `lo` is at or before the answer and `hi` after it. -/
def lastStartAtOrBefore (starts : Array Nat) (cycle lo hi : Nat) : Nat :=
  if h : lo + 1 < hi then
    let mid := (lo + hi) / 2
    if starts.getD mid 0 ≤ cycle then lastStartAtOrBefore starts cycle mid hi
    else lastStartAtOrBefore starts cycle lo mid
  else lo
termination_by hi - lo

/-- The interval under `cycle`, if any. -/
def intervalAt (starts stops : Array Nat) (cycle : Nat) : Option Nat :=
  if starts.isEmpty || cycle < starts.getD 0 0 then none else
  let i := lastStartAtOrBefore starts cycle 0 starts.size
  if cycle < stops.getD i 0 then some i else none

def TimelineDemo : Component Unit := Component.named "LargeTimeline" <| component fun _ => do
  let status ← useState "Drawing…" "status"
  let data ← useCell ((#[], #[]) : Array Nat × Array Nat) "intervals"
  let ready (h : Handle TimelineOps) : Action Unit := do
    let (starts, stops) ← data.modifyGet fun current =>
      let built := if current.1.isEmpty then (makeStarts intervalCount, makeStops intervalCount) else current
      (built, built)
    match ← h.ops.draw starts stops total with
    | .ok drawn => status.set s!"Drew {drawn} intervals. Click one."
    | .unmounted => pure ()
  let pick (event : PointerEvent) : Action Unit := do
    if event.width ≤ 0 then return
    let (starts, stops) ← data.read
    let cycle := (max 0 event.x).toNat * total / event.width.toNat
    status.set <| match intervalAt starts stops cycle with
      | some i => s!"Interval {i}: cycles {starts.getD i 0}–{stops.getD i 0} (clicked cycle {cycle})"
      | none => s!"No interval at cycle {cycle}"
  pure <| DOM.section { className := some "panel" } #[
    DOM.h2 {} #[text "A million intervals on a canvas"],
    DOM.p { className := some "note" } #[text "The canvas draws from a Lean array; a click maps back to an interval in Lean."],
    DOM.div { className := some "timeline-canvas-frame", data := #[("testid", "timeline-canvas")], onPointerDown := some pick }
      #[timelineCanvas {} ready],
    DOM.p { role := some "status", data := #[("testid", "timeline-pick")] } #[text status.value]]

def Demo : Component Unit := Component.named "LargeDemo" <| component fun _ => do
  pure <| DOM.div {} #[element EventList (), element EventGrid (), element TimelineDemo ()]

#leanreact_check Examples.Large.Demo

-- The click mapping, natively.
private def starts : Array Nat := makeStarts intervalCount
private def stops : Array Nat := makeStops intervalCount
#guard intervalAt starts stops 0 == some 0
#guard intervalAt starts stops 3 == none
#guard intervalAt starts stops 4 == some 1
#guard intervalAt starts stops (total - 1) == none
#guard intervalAt starts stops (4 * 999999) == some 999999
#guard intervalAt starts stops (4 * 2 + 2) == some 2

end Examples.Large
