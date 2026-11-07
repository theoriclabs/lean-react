import LeanReact.DOM

/-! # Large views: render only what is visible

```
virtualList {
  count := rows.size, rowHeight := 28, height := 480, ariaLabel := some "Events"
  key := fun i => Key.nat (rows[i]!).id
  row := fun i => eventRow rows[i]! }

virtualGrid {
  rowCount := 3000, columnCount := 200, rowHeight := 24, columnWidth := 64,
  height := 480, width := 900, stickyColumns := 1
  cell := fun r c => if c == 0 then text s!"Unit {r}" else text (toString (value r c)) }
```

Rows (and grid cells) have fixed sizes in CSS pixels. Only the rows inside the viewport, plus
`overscan` rows on each side, are rendered; each is absolutely positioned in a spacer as tall as
the whole list, so the scrollbar is the real one. Rows are keyed (`key`, default the index), so a
row's state follows its item. The scroll position is the element's own, so it is kept when the
data changes (and clamped when the list shrinks). `stickyColumns` leading grid columns stay in
view while the grid scrolls sideways (row labels).

For tens of thousands of intervals per row, a canvas is cheaper than elements: see the timeline
canvas in `examples/lean/Examples/Large.lean`. -/

namespace LeanReact
open LeanReact.DOM

/-- The rows `[first, stop)` to render for a scroll offset: those intersecting the viewport,
widened by `overscan` on each side. -/
def visibleRange (count size viewport overscan offset : Nat) : Nat × Nat :=
  if size == 0 || count == 0 then (0, 0) else
  let first := min (offset / size) (count - 1)
  let shown := (viewport + size - 1) / size + 1
  (first - overscan, min count (first + shown + overscan))

private def px (n : Nat) : String := toString n ++ "px"

structure VirtualListProps where
  count : Nat
  /-- Every row's height, in CSS pixels. -/
  rowHeight : Nat
  /-- The viewport's height, in CSS pixels. -/
  height : Nat
  overscan : Nat := 4
  row : Nat → Element
  key : Nat → Key := Key.nat
  ariaLabel : Option String := none
  className : Option String := none

def VirtualList : Component VirtualListProps := Component.named "stable:LeanReact.VirtualList" <| component fun props => do
  let scroll ← useState (0 : Nat) "virtual.scrollTop"
  let (first, stop) := visibleRange props.count props.rowHeight props.height props.overscan scroll.value
  let rows := (Array.range (stop - first)).map fun offset =>
    let index := first + offset
    keyed (props.key index) <| DOM.div {
        role := some "listitem"
        data := #[("index", toString index)]
        style := #[(.position, "absolute"), (.top, px (index * props.rowHeight)), (.left, "0"), (.right, "0"),
          (.height, px props.rowHeight)] } #[props.row index]
  pure <| DOM.div {
      className := props.className
      ariaLabel := props.ariaLabel
      tabIndex := some 0
      data := #[("virtual", "list"), ("first", toString first), ("stop", toString stop)]
      style := #[(.height, px props.height), (.overflowY, "auto"), (.position, "relative")]
      onScroll := some fun event => scroll.set event.scrollTop.toNat } #[
    DOM.div { role := some "list", style := #[(.position, "relative"), (.height, px (props.count * props.rowHeight))] } rows]

/-- A list of `count` fixed-height rows that renders only the visible window. -/
def virtualList (props : VirtualListProps) : Element := element VirtualList props

structure VirtualGridProps where
  rowCount : Nat
  columnCount : Nat
  rowHeight : Nat
  columnWidth : Nat
  /-- The viewport, in CSS pixels. -/
  height : Nat
  width : Nat
  overscan : Nat := 2
  /-- Leading columns that stay in view while the grid scrolls sideways. -/
  stickyColumns : Nat := 0
  cell : Nat → Nat → Element
  ariaLabel : Option String := none
  className : Option String := none

structure GridScroll where
  top : Nat := 0
  left : Nat := 0
  deriving BEq

def VirtualGrid : Component VirtualGridProps := Component.named "stable:LeanReact.VirtualGrid" <| component fun props => do
  let scroll ← useState ({} : GridScroll) "virtual.gridScroll"
  let (firstRow, stopRow) := visibleRange props.rowCount props.rowHeight props.height props.overscan scroll.value.top
  let (firstColumn, stopColumn) := visibleRange props.columnCount props.columnWidth props.width props.overscan scroll.value.left
  let sticky := min props.stickyColumns props.columnCount
  -- Sticky columns are always rendered, offset by the horizontal scroll so they stay in view.
  let columns := (Array.range sticky) ++
    ((Array.range (stopColumn - firstColumn)).map (firstColumn + ·)).filter (· ≥ sticky)
  let cells := (Array.range (stopRow - firstRow)).flatMap fun rowOffset =>
    let row := firstRow + rowOffset
    columns.map fun column =>
      let left := column * props.columnWidth + (if column < sticky then scroll.value.left else 0)
      keyed (Key.string s!"{row}:{column}") <| DOM.div {
          role := some "gridcell"
          data := #[("row", toString row), ("column", toString column)] ++ (if column < sticky then #[("sticky", "")] else #[])
          style := #[(.position, "absolute"), (.top, px (row * props.rowHeight)), (.left, px left),
            (.width, px props.columnWidth), (.height, px props.rowHeight)] ++
            (if column < sticky then #[(.zIndex, "1"), (.background, "inherit")] else #[]) } #[props.cell row column]
  pure <| DOM.div {
      className := props.className
      ariaLabel := props.ariaLabel
      role := some "grid"
      tabIndex := some 0
      data := #[("virtual", "grid"), ("rows", s!"{firstRow}-{stopRow}"), ("columns", s!"{firstColumn}-{stopColumn}")]
      style := #[(.height, px props.height), (.width, px props.width), (.overflow, "auto"), (.position, "relative")]
      onScroll := some fun event => scroll.set { top := event.scrollTop.toNat, left := event.scrollLeft.toNat } } #[
    DOM.div { style := #[(.position, "relative"), (.height, px (props.rowCount * props.rowHeight)),
      (.width, px (props.columnCount * props.columnWidth))] } cells]

/-- A grid of fixed-size cells that renders only the visible window (plus sticky columns). -/
def virtualGrid (props : VirtualGridProps) : Element := element VirtualGrid props

end LeanReact
