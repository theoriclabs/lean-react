import Lean

/- LR-14/P0 fixtures, intentionally independent of the future public Program API. -/
namespace ComponentSpike
open Lean

inductive Msg where
  | clicked (n : Nat)
  | typed (text : String)
  deriving BEq, Repr

inductive Attr (Msg : Type) where
  | attr (name value : String)
  | on (event : String) (decode : String → Option Msg)

def Attr.map (f : α → β) : Attr α → Attr β
  | .attr name value => .attr name value
  | .on event decode => .on event (fun value => (decode value).map f)

-- P0 #4: minimal host-erased bundles with leaf views. The fully recursive typed
-- shape and its kernel rejection are in ComponentsEmbedRejected.lean.
structure Child (Props Model Msg : Type) where
  init : Props → Model
  update : Msg → Model → Model
  view : Model → String

structure Embed (ParentMsg : Type) where
  Props : Type
  Model : Type
  Msg : Type
  component : Child Props Model Msg
  props : Props
  toParent : Msg → Option ParentMsg

def Embed.map (f : α → β) (child : Embed α) : Embed β :=
  { Props := child.Props, Model := child.Model, Msg := child.Msg,
    component := child.component, props := child.props,
    toParent := fun msg => (child.toParent msg).map f }

-- Keeping the existential type witnesses makes Html universe 1; the ABI erases them.
inductive Html (Msg : Type) : Type 1 where
  | text (value : String)
  | node (tag : String) (attrs : List (Attr Msg)) (children : List (Html Msg))
  | embed (child : Embed Msg)
  | none

-- P0 #2: actual nested structural recursion, not a JS stand-in.
def Html.map (f : α → β) : Html α → Html β
  | .text value => .text value
  | .node tag attrs children => .node tag (attrs.map (Attr.map f)) (children.map (Html.map f))
  | .embed child => .embed (child.map f)
  | .none => .none

def view (labelPrefix : String) : Html Msg :=
  .node "section" [.attr "aria-label" "Component spike"] [
    .node "button" [.on "click" (fun _ => some (.clicked 7))] [.text (labelPrefix ++ " click")],
    .node "input" [.attr "value" "", .on "input" (fun value =>
      if value == "" then none else some (.typed (labelPrefix ++ value)))] [],
    .none]

def mappedView : Html String :=
  (view "nested:").map fun
    | .clicked n => "clicked:" ++ toString n
    | .typed value => "typed:" ++ value

def counterChild : Embed Msg := {
  Props := Nat, Model := Nat, Msg := Nat
  component := ⟨id, (· + ·), fun n => "count:" ++ toString n⟩
  props := 9007199254740993
  toParent := fun n => some (.clicked n) }

def textChild : Embed Msg := {
  Props := String, Model := String, Msg := String
  component := ⟨id, fun suffix text => text ++ suffix, id⟩
  props := "child:"
  toParent := fun text => some (.typed text) }

def embeddedView : Html Msg :=
  .node "section" [] [.embed counterChild, .embed textChild]

def mappedEmbeddedView : Html String :=
  embeddedView.map fun
    | .clicked n => "child-click:" ++ toString n
    | .typed text => "child-text:" ++ text

def embeddedInit (child : Embed Msg) : String := child.component.view (child.component.init child.props)

def embeddedNat : String := embeddedInit counterChild
def embeddedText : String := embeddedInit textChild

-- A full child view is possible when its existential bundle is outside Html's
-- recursive definition. The host owns this boundary instead of a typed Html field.
structure HtmlChild (Props Model Msg : Type) where
  init : Props → Model
  update : Msg → Model → Model
  view : Model → Html Msg

structure HostEmbed (ParentMsg : Type) where
  Props : Type
  Model : Type
  Msg : Type
  component : HtmlChild Props Model Msg
  props : Props
  toParent : Msg → Option ParentMsg

def recursiveChild : HostEmbed Msg := {
  Props := Nat, Model := Nat, Msg := Nat
  component := {
    init := id
    update := (· + ·)
    view := fun count => .node "button" [.on "click" (fun _ => some 2)]
      [.node "span" [] [.text ("recursive:" ++ toString count)]] }
  props := 9007199254740993
  toParent := fun n => some (.clicked n) }

-- P0 #5: continuations capture the model value at the transition.
inductive Cmd (Msg : Type) where
  | none
  | after (ms : Nat) (msg : Msg)
  | request (input : Nat) (done : Nat → Msg)
  | batch (commands : List (Cmd Msg))

structure Model where
  count : Nat
  title : String
  deriving BEq, Repr

def update (msg : Msg) (model : Model) : Model × Cmd Msg :=
  match msg with
  | .clicked n =>
    let count := model.count + n
    ( { model with count }, .batch [
      .after 10 (.typed "committed"),
      .request count (fun result => .typed (model.title ++ ":" ++ toString result))])
  | .typed title => ({ model with title }, .none)

-- P0 #6: derived FromJson over a record, including nontrivial payloads.
structure Payload where
  title : String
  count : Nat
  enabled : Bool
  deriving FromJson, ToJson, BEq, Repr

def decodePayload (value : Lean.Json) : Except String Payload := Lean.fromJson? value

-- P0 #7: the intended 64-square view and a path much deeper than a flat board.
def board : Html Msg :=
  .node "div" [.attr "role" "grid"] ((List.range 64).map fun square =>
    .node "button" [.attr "role" "gridcell", .attr "data-square" (toString square),
      .on "click" (fun _ => some (.clicked square))] [
      .node "span" [.attr "aria-label" ("piece:" ++ toString square)] [.text (toString square)]])

def deep : Nat → Html Msg
  | 0 => .text "bottom"
  | n + 1 => .node "div" [.attr "data-depth" (toString n)] [deep n]

#guard embeddedNat == "count:9007199254740993"
#guard embeddedText == "child:"
#guard (update (.clicked 3) ⟨4, "before"⟩).1 == ⟨7, "before"⟩
#guard match decodePayload (Lean.Json.mkObj [("title", .str "λ"), ("count", toJson (7 : Nat)), ("enabled", .bool true)]) with
  | .ok payload => payload == ⟨"λ", 7, true⟩
  | .error _ => false

end ComponentSpike
