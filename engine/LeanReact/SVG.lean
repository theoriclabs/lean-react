import LeanReact.DOM

/-! # SVG elements

Diagrams and charts as SVG, with integer coordinates (no `Float`): user units of the `viewBox`.

```
SVG.svg { viewBox := some ⟨0, 0, 320, 120⟩, ariaLabel := some "Data path" } #[
  SVG.defs {} #[SVG.arrowhead "arrow"],
  SVG.rect { x := 10, y := 40, width := 80, height := 40, rx := 6 } #[],
  SVG.line { x1 := 90, y1 := 60, x2 := 210, y2 := 60, stroke := some "currentColor",
             markerEnd := some "arrow" } #[],
  SVG.path { d := #[.moveTo 0 0, .lineTo 10 5, .close] } #[]]
```

Every element takes the shared `Props` (class names, ARIA, `data-*`, style, and events,
including the pointer and wheel events), plus its geometry. Presentation attributes (`fill`,
`stroke`, `strokeWidth`) are on every shape. `markerStart`/`markerEnd` name a `marker` by id. -/

namespace LeanReact.SVG
open LeanReact LeanReact.DOM

/-- `viewBox="minX minY width height"`. -/
structure ViewBox where
  minX : Int
  minY : Int
  width : Nat
  height : Nat
  deriving Repr, BEq

def ViewBox.text (box : ViewBox) : String :=
  s!"{box.minX} {box.minY} {box.width} {box.height}"

/-- One path command, in absolute user units. -/
inductive PathCommand where
  | moveTo (x y : Int)
  | lineTo (x y : Int)
  | horizontalTo (x : Int)
  | verticalTo (y : Int)
  /-- A cubic Bézier: two control points, then the end point. -/
  | cubicTo (x1 y1 x2 y2 x y : Int)
  /-- A quadratic Bézier: one control point, then the end point. -/
  | quadraticTo (x1 y1 x y : Int)
  | arcTo (rx ry : Nat) (rotation : Int) (largeArc sweep : Bool) (x y : Int)
  | close
  deriving Repr, BEq

private def flag (value : Bool) : String := if value then "1" else "0"

def PathCommand.text : PathCommand → String
  | .moveTo x y => s!"M{x} {y}"
  | .lineTo x y => s!"L{x} {y}"
  | .horizontalTo x => s!"H{x}"
  | .verticalTo y => s!"V{y}"
  | .cubicTo x1 y1 x2 y2 x y => s!"C{x1} {y1} {x2} {y2} {x} {y}"
  | .quadraticTo x1 y1 x y => s!"Q{x1} {y1} {x} {y}"
  | .arcTo rx ry rotation largeArc sweep x y => s!"A{rx} {ry} {rotation} {flag largeArc} {flag sweep} {x} {y}"
  | .close => "Z"

/-- Path data (`d`), e.g. `M0 0 L10 5 Z`. -/
def pathData (commands : Array PathCommand) : String := " ".intercalate (commands.map PathCommand.text).toList

/-- How text is anchored at its `x`. -/
inductive TextAnchor where
  | start | middle | «end»
  deriving Repr, BEq

def TextAnchor.text : TextAnchor → String
  | .start => "start" | .middle => "middle" | .«end» => "end"

/-- Presentation attributes shared by shapes and groups. -/
structure Paint extends Props where
  fill : Option String := none
  stroke : Option String := none
  strokeWidth : Option Nat := none
  /-- A `marker` id, drawn at the start or end of a line, polyline or path. -/
  markerStart : Option String := none
  markerEnd : Option String := none
  /-- `translate(x y)`, applied before the shape's own coordinates. -/
  translate : Option (Int × Int) := none

private def opt (name : String) (value : Option String) : Array Attribute :=
  match value with | none => #[] | some value => #[.string name value]

private def num (name : String) (value : Int) : Array Attribute := #[.string name (toString value)]

private def markerRef (name : String) (id : Option String) : Array Attribute :=
  opt name (id.map fun id => "url(#" ++ id ++ ")")

def Paint.attributes (paint : Paint) : Array Attribute :=
  paint.toProps.attributes ++ opt "fill" paint.fill ++ opt "stroke" paint.stroke ++
    opt "strokeWidth" (paint.strokeWidth.map toString) ++ markerRef "markerStart" paint.markerStart ++
    markerRef "markerEnd" paint.markerEnd ++
    opt "transform" (paint.translate.map fun (x, y) => s!"translate({x} {y})")

structure SvgProps extends Props where
  viewBox : Option ViewBox := none
  width : Option Nat := none
  height : Option Nat := none
  /-- `preserveAspectRatio`, e.g. `"none"` to stretch a timeline to its box. -/
  preserveAspectRatio : Option String := none

/-- The `svg` root. Without a `title` child, give it an `ariaLabel` (and usually `role := "img"`). -/
def svg (props : SvgProps := {}) (children : Array Element := #[]) : Element :=
  node "svg" (props.toProps.attributes ++ opt "viewBox" (props.viewBox.map ViewBox.text) ++
    opt "width" (props.width.map toString) ++ opt "height" (props.height.map toString) ++
    opt "preserveAspectRatio" props.preserveAspectRatio) children

def g (props : Paint := {}) (children : Array Element := #[]) : Element := node "g" props.attributes children
def defs (props : Props := {}) (children : Array Element := #[]) : Element := node "defs" props.attributes children
/-- An accessible name for the parent element (a tooltip in browsers). -/
def title (value : String) : Element := node "title" #[] #[text value]

structure RectProps extends Paint where
  x : Int := 0
  y : Int := 0
  width : Nat := 0
  height : Nat := 0
  rx : Nat := 0

def rect (props : RectProps := {}) (children : Array Element := #[]) : Element :=
  node "rect" (props.toPaint.attributes ++ num "x" props.x ++ num "y" props.y ++ num "width" props.width ++
    num "height" props.height ++ (if props.rx == 0 then #[] else num "rx" props.rx)) children

structure LineProps extends Paint where
  x1 : Int := 0
  y1 : Int := 0
  x2 : Int := 0
  y2 : Int := 0

def line (props : LineProps := {}) (children : Array Element := #[]) : Element :=
  node "line" (props.toPaint.attributes ++ num "x1" props.x1 ++ num "y1" props.y1 ++ num "x2" props.x2 ++
    num "y2" props.y2) children

structure PathProps extends Paint where
  d : Array PathCommand := #[]

def path (props : PathProps := {}) (children : Array Element := #[]) : Element :=
  node "path" (props.toPaint.attributes ++ #[.string "d" (pathData props.d)]) children

structure PolylineProps extends Paint where
  points : Array (Int × Int) := #[]

def polyline (props : PolylineProps := {}) (children : Array Element := #[]) : Element :=
  node "polyline" (props.toPaint.attributes ++
    #[.string "points" (" ".intercalate (props.points.map fun (x, y) => s!"{x},{y}").toList)]) children

structure TextProps extends Paint where
  x : Int := 0
  y : Int := 0
  anchor : TextAnchor := .start

/-- SVG text at `(x, y)` (the baseline). -/
def «text» (props : TextProps := {}) (children : Array Element := #[]) : Element :=
  node "text" (props.toPaint.attributes ++ num "x" props.x ++ num "y" props.y ++
    (if props.anchor == .start then #[] else #[.string "textAnchor" props.anchor.text])) children

structure MarkerProps extends Props where
  viewBox : Option ViewBox := none
  refX : Int := 0
  refY : Int := 0
  markerWidth : Nat := 6
  markerHeight : Nat := 6
  /-- `auto` turns the marker along the line; `auto-start-reverse` mirrors it at the start. -/
  orient : String := "auto"

/-- A marker (arrowhead, dot, …) referenced by `markerStart`/`markerEnd`. Put it in `defs`; `id` is required. -/
def «marker» (props : MarkerProps) (children : Array Element := #[]) : Element :=
  node "marker" (props.toProps.attributes ++ opt "viewBox" (props.viewBox.map ViewBox.text) ++
    num "refX" props.refX ++ num "refY" props.refY ++ num "markerWidth" props.markerWidth ++
    num "markerHeight" props.markerHeight ++ #[.string "orient" props.orient]) children

/-- A filled triangular arrowhead marker with the given `id`, in the line's colour. -/
def arrowhead (id : String) (fill : String := "context-stroke") : Element :=
  «marker» { id := some id, viewBox := some ⟨0, 0, 10, 10⟩, refX := 9, refY := 5, orient := "auto-start-reverse" }
    #[path { d := #[.moveTo 0 0, .lineTo 10 5, .lineTo 0 10, .close], fill := some fill }]

end LeanReact.SVG
