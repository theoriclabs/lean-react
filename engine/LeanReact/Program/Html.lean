import LeanReact.Program.Attr
import LeanJS.StackSafe

/-! # Views as data

`Html Msg` is a tree whose events produce messages. A child component is embedded through the
host (`Embed`): Lean's kernel rejects a typed recursive child (the P0 spike), so an embed
carries how to mount the child given the parent's dispatch. -/

namespace LeanReact.Program

/-- A child mounted by the host: given the parent's dispatch, an element. -/
structure Embed (Msg : Type) where
  key : String
  mount : (Msg → Action Unit) → Element

def Embed.map (f : α → β) (child : Embed α) : Embed β :=
  { key := child.key, mount := fun dispatch => child.mount (dispatch ∘ f) }

inductive Html (Msg : Type) where
  | text (value : String)
  | node (tag : String) (attrs : List (Attr Msg)) (children : List (Html Msg))
  /-- A child with a key among its siblings; reordering keeps each keyed child's state and DOM
  identity. -/
  | keyed (key : String) (child : Html Msg)
  | embed (child : Embed Msg)
  /-- Re-walked only when `key` changes. -/
  | lazy (key : String) (view : Unit → Html Msg)
  | none

namespace Html

/-- The same view, its messages mapped through `f` (composing a child's view into a parent). -/
@[leanjs_stack_safe] def map (f : α → β) : Html α → Html β
  | .text value => .text value
  | .node tag attrs children => .node tag (attrs.map (Attr.map f)) (children.map (Html.map f))
  | .keyed key child => .keyed key (child.map f)
  | .embed child => .embed (child.map f)
  | .lazy key view => .lazy key fun _ => (view ()).map f
  | .none => .none

/-- The key of a keyed child. -/
def key? : Html Msg → Option String
  | .keyed key _ => some key
  | _ => Option.none

mutual
/-- The first duplicate key among siblings, anywhere in the view (the host rejects such a view;
a native test can check it first). Lazy subtrees are not expanded. -/
def duplicateKey? : Html Msg → Option String
  | .node _ _ children => duplicateIn [] children
  | .keyed _ child => duplicateKey? child
  | _ => Option.none

/-- `duplicateKey?` over siblings, with the sibling keys `seen` so far. -/
def duplicateIn (seen : List String) : List (Html Msg) → Option String
  | [] => Option.none
  | child :: rest =>
    let here := match key? child with
      | some k => if seen.contains k then some k else Option.none
      | Option.none => Option.none
    here.orElse fun _ => (duplicateKey? child).orElse fun _ => duplicateIn (seen ++ (key? child).toList) rest
end

/-- An element from the hook API inside a view; its events do not reach this component. -/
def element (e : Element) : Html Msg := .embed { key := "element", mount := fun _ => e }

end Html

end LeanReact.Program
