import LeanAppNative.Storage

open LeanAppNative.Storage LeanDb Ontology

private def check (ok : Bool) (label : String) : IO Unit :=
  unless ok do throw <| IO.userError s!"FAIL: {label}"

private def rejected : Except ε α → Bool
  | .error _ => true
  | .ok _ => false

private def roundTrip (n : Nat) : Bool :=
  match fromCol (α := ExactNat) (toCol (ExactNat.mk n)) with
  | .ok decoded => decoded.value == n
  | .error _ => false

def main : IO Unit := do
  for n in [0, 1, 9223372036854775807] do
    match SqlNat.ofNat n with
    | .error e => throw <| IO.userError e
    | .ok checked =>
      match fromCol (α := SqlNat) (toCol checked) with
      | .error e => throw <| IO.userError e
      | .ok decoded => check (decoded.value == n) "bounded INTEGER round-trip"
  for n in [9223372036854775808, 18446744073709551616, 10^100] do
    check (rejected (SqlNat.ofNat n)) "refuse narrowing"
    check (roundTrip n) "exact TEXT round-trip"
  check (rejected (fromCol (α := SqlNat) (.int (-1)))) "reject negative INTEGER"
  for s in ["", "-1", "+1", "01", " 1", "1 ", "1.0", "1e9"] do
    check (rejected (ExactNat.parse s)) "reject noncanonical TEXT"
  check (rejected (fromCol (α := ExactNat) (.int 1))) "reject wrong storage class"
  let .ok id := EntityId.parse (α := Unit) "café" "注文-42"
    | throw <| IO.userError "ID fixture"
  match (PublicIdColumns.encode id).decode (α := Unit) with
  | .ok decoded => check (decoded == id) "ID reconstruction"
  | .error _ => throw <| IO.userError "ID reconstruction failed"
  check (rejected (PublicIdColumns.decode (α := Unit) ⟨"", "x"⟩)) "empty scope"
  check (rejected (PublicIdColumns.decode (α := Unit) ⟨"tenant", ""⟩)) "empty key"
  IO.println "PASS: checked SQLite integers, exact decimal text, and nominal ID reconstruction"
