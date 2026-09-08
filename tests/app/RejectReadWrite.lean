import LeanApp
open LeanApp Contract
def wrong (op : Operation .query Nat Nat String) : Binding Id Option Option op where
  policy := fun _ _ _ => .ok ()
  handler := fun _ cap input => do
    cap.write (some input)
    pure (.ok input)
  http := { path := "/wrong" }
