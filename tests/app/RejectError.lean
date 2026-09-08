import LeanApp
open LeanApp Contract
def wrong (op : Operation .query Nat Nat String) : Binding Id Option Option op where
  policy := fun _ _ _ => .ok ()
  handler := fun _ _ _ => .error (7 : Nat)
  http := { path := "/wrong" }
