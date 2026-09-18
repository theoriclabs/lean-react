import LeanReact

namespace Examples.Sparkline
open LeanReact

structure SparklineProps where
  width : Nat := 240
  height : Nat := 60
  color : String := "#5b7f4b"

/-- The widget's imperative API. Each operation resolves to `.unmounted` once the canvas is gone. -/
structure SparklineOps where
  /-- Draws the series and reports how many points it plotted. -/
  draw : Array Nat → Action (HandleResult Nat)
  clear : Action (HandleResult Unit)

/-- Reference stubs: succeed without drawing. Tests substitute recording stubs. -/
def SparklineOps.silent : SparklineOps :=
  { draw := fun points => pure (.ok points.size), clear := pure (.ok ()) }

/-- The `<canvas>` widget in examples/adapters/example-sparkline.mjs, registered as `"sparkline"`.
Natively a placeholder canvas node stands in and `reference` backs the handle. -/
def sparkline (props : SparklineProps) (onReady : Handle SparklineOps → Action Unit)
    (onGone : Action Unit := pure ()) (reference : SparklineOps := .silent) : Element :=
  foreign "sparkline" {
    props, onReady, onGone
    reference := {
      render := fun p => node "canvas" #[.string "width" (toString p.width), .string "height" (toString p.height)] #[]
      ops := some fun _ => reference }
  }

def series : Array (Array Nat) := #[#[3, 5, 2, 8, 6, 9, 4], #[1, 2, 4, 8, 16, 12, 20, 18], #[9, 7, 8, 3, 4, 2, 1, 2, 3]]

structure DemoProps where
  reference : SparklineOps := .silent

/-- Keep the handle in a `Cell`: it is a capability, not render state. Calling it after unmount is safe
and yields `.unmounted`, which the status line shows. -/
def Demo : Component DemoProps := Component.named "SparklineDemo" <| component fun props => do
  let handle ← useCell (none : Option (Handle SparklineOps)) "sparkline-handle"
  let events ← useState (#[] : Array String) "events"
  let status ← useState "Waiting for the canvas." "status"
  let index ← useState 0 "series"
  let mounted ← useState true "mounted"
  let generation ← useState 0 "generation"
  let ready (h : Handle SparklineOps) : Action Unit := do
    handle.modifyGet fun _ => ((), some h)
    events.modify (·.push "ready")
    status.set "Canvas ready."
  let gone : Action Unit := do
    events.modify (·.push "gone")
    status.set "Canvas gone."
  let draw : Action Unit := do
    match ← handle.read with
    | none => status.set "No canvas yet."
    | some h =>
      let next := (index.value + 1) % series.size
      match ← h.ops.draw (series.getD next #[]) with
      | .ok count => index.set next; status.set s!"Drew {count} points."
      | .unmounted => status.set "The canvas was unmounted; nothing drawn."
  let clear : Action Unit := do
    match ← handle.read with
    | none => status.set "No canvas yet."
    | some h =>
      match ← h.ops.clear with
      | .ok () => status.set "Cleared."
      | .unmounted => status.set "The canvas was unmounted; nothing cleared."
  pure <| DOM.section { className := some "panel sparkline-demo" } #[
    DOM.h2 {} #[text "An imperative canvas, driven from Lean"],
    DOM.p { className := some "note" } #[text "The widget is plain JavaScript with useImperativeHandle; Lean sees a typed Handle."],
    (if mounted.value then keyed (Key.nat generation.value) (sparkline {} ready gone props.reference)
      else DOM.p { className := some "note", data := #[("testid", "sparkline-placeholder")] } #[text "No canvas mounted."]),
    DOM.div { className := some "toolbar" } #[
      DOM.button { onPress := some draw } #[text "Draw next series"],
      DOM.button { onPress := some clear } #[text "Clear"],
      DOM.button { onPress := some (mounted.modify (!·)) } #[text (if mounted.value then "Unmount canvas" else "Mount canvas")],
      DOM.button { onPress := some (generation.modify (· + 1)) } #[text "Recreate canvas"]
    ],
    DOM.p { role := some "status" } #[text status.value],
    DOM.p { className := some "note", data := #[("testid", "sparkline-events")] }
      #[text (String.intercalate " → " events.value.toList)]
  ]

end Examples.Sparkline
