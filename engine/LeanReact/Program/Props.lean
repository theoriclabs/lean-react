import LeanReact.Program.Component
import LeanApi.Props.Kernel

/-! # Proofs about components

A component is a transition system: the world is its `Model`, a request is a message, a step is
`update`, and the step's output is the command. `Component.toSys` states it against LeanAPI's
property kernel (`LeanApi.Props.Kernel`, which has no server import), so the kernel's proof
principles and authoring commands apply unchanged:

```
invariant Capped (n : Nat) where
  le : n ≤ 99

preserves Capped by cappedUpdate          -- update : Msg → Nat → Nat × Cmd Msg

theorem capped : Invariant (BoundedCounter.toSys ()) (· ≤ 99) :=
  BoundedCounter.invariant_of () (by decide) fun msg n h => (Capped.preserved_cappedUpdate … ⟨h⟩ rfl).le
```

View theorems are plain statements about the pure `view`; `Html.attrsOf` and `Attr.disabledIn`
are total, so they can appear in them ("Reset is disabled exactly when the count is 0"). -/

namespace LeanReact.Program
open LeanApi.Props

/-- The component as a transition system for `props`: initial worlds are `init`'s model. -/
def Component.toSys (c : Component Props Model Msg) (props : Props) : Sys where
  World := Model
  Req := Msg
  Res := Cmd Msg
  Env := Unit
  step _ msg model := let next := c.update props msg model; (next.2, next.1)
  init model := model = (c.init props).1

/-- An invariant of a component: it holds for `init`'s model, and `update` preserves it. -/
theorem Component.invariant_of (c : Component Props Model Msg) (props : Props) {I : Model → Prop}
    (init : I (c.init props).1) (step : ∀ msg model, I model → I (c.update props msg model).1) :
    Invariant (c.toSys props) I :=
  Invariant.of_inductive {
    init := fun _ h => by subst h; exact init
    step := fun _ msg model h => step msg model h }

/-! ## Total queries, for view theorems -/

/-- The text of an element's direct text children. -/
def directText : List (Html Msg) → String
  | [] => ""
  | .text value :: rest => value ++ directText rest
  | _ :: rest => directText rest

mutual
/-- The attributes of the first element with this tag whose direct text is `label`. -/
def Html.attrsOf (tag label : String) : Html Msg → Option (List (Attr Msg))
  | .node t attrs children =>
    if t == tag && directText children == label then some attrs else Html.attrsOfList tag label children
  | .keyed _ child => Html.attrsOf tag label child
  | _ => Option.none

/-- `Html.attrsOf` over siblings, in order. -/
def Html.attrsOfList (tag label : String) : List (Html Msg) → Option (List (Attr Msg))
  | [] => Option.none
  | child :: rest => (Html.attrsOf tag label child).orElse fun _ => Html.attrsOfList tag label rest
end

/-- Whether attributes include `disabled true`. -/
def Attr.disabledIn (attrs : List (Attr Msg)) : Bool :=
  attrs.any fun | .bool "disabled" value => value | _ => false

end LeanReact.Program
