import Lean
import tests.ordering.Fixtures

open Ordering.Fixtures

def checked (value : Except String (Array String)) : IO Lean.Json :=
  match value with
  | .ok result => pure (Lean.toJson result)
  | .error message => throw (IO.userError message)

def main : IO Unit := do
  let amounts := #[0, 1, 9007199254740993, 9223372036854775808, 123456789012345678901234567890]
  let labels := #["Café ☕ 東京 😀", "é", "𐀀\uE000", "quote\"slash\\\nline", "x\u0000y"]
  let mut cases := #[]
  for amount in amounts do
    for label in labels do
      cases := cases.push (← checked (scenario amount label))
    cases := cases.push (← checked (pricingCases amount))
    cases := cases.push (← checked (stockCases amount))
  IO.println (Lean.Json.arr cases).compress
