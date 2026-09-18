import LeanReact

open LeanReact

-- Core higher-order signatures stay generic; no effect row or event enum is needed.
example (initial : α) : Hook (State α) := useState initial
example (callback : α → Action Unit) (value : α) : Action Unit := callback value
example (context : Context α) : Hook α := useContext context
example (context : Context α) (value : α) (child : Element) : Element := provide context value child
example (items : Array α) (key : α → Key) (slot : α → Element) : Element := keyedEach items key slot
example (hook : Hook α) (layout : α → Element) : Component Unit :=
  component fun _ => do pure (layout (← hook))

-- These assertions fail the test if an invalid program starts type-checking.
#check_failure element (component fun (_ : Nat) => pure empty) "wrong props"
#check_failure (show Hook Nat from (pure 1 : Action Nat))
#check_failure DOM.input { onChange := some (fun (_ : PressEvent) => pure ()) }
#check_failure DOM.button { onPress := some (pure "wrong result" : Action String) }
#check_failure (show State Nat → Action Unit from fun state => state.set "wrong state")
#check_failure DOM.div { style := #[(.colour, "red")] }
