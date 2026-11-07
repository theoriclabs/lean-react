import LeanReact.Program.Elements
import LeanReact.Program.Cmd

/-! # Components: a state machine plus a view

```
def Counter : Program.Component Unit Nat Msg where
  init _ := (0, .none)
  update _ msg n := match msg with | .add k => (n + k, .none) | .reset => (0, .none)
  view _ n := div [] [text s!"Count: {n}", button [onClick (.add 1)] [text "+1"]]
```

`init`, `update` and `view` are pure. All state is one `Model`; every change is a named `Msg`
and a total transition; effects are `Cmd` data run by the host after the transition. -/

namespace LeanReact.Program

structure Component (Props Model Msg : Type) where
  init : Props → Model × Cmd Msg
  update : Props → Msg → Model → Model × Cmd Msg
  view : Props → Model → Html Msg
  subscriptions : Props → Model → Sub Msg := fun _ _ => .none
  /-- A new `Props` from the parent, as a message (default: ignore; the view still re-renders). -/
  propsChanged : Option (Props → Msg) := none

end LeanReact.Program
