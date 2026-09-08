import Ordering.Domain.Pricing

namespace Cafe
open Ordering

/-- This record is the untrusted presentation input, not an admissible drink. -/
structure Draft where
  temperature : String
  size : String
  milk : String
  shots : String
  decaf : Bool
  deriving Repr, BEq

def Draft.configuration (d : Draft) : Except String Configuration := do
  let temperature ← match d.temperature with
    | "hot" => pure Temperature.hot | "iced" => pure .iced | _ => throw "invalid_configuration"
  let size ← match d.size with
    | "small" => pure Size.small | "regular" => pure .regular | "large" => pure .large
    | _ => throw "invalid_configuration"
  let milk ← match d.milk with
    | "whole" => pure Milk.whole | "skim" => pure .skim | "oat" => pure .oat
    | "almond" => pure .almond | "soy" => pure .soy | _ => throw "invalid_configuration"
  let shots ← match d.shots with
    | "single" => pure Shots.single | "double" => pure .double | "triple" => pure .triple
    | _ => throw "invalid_configuration"
  pure { temperature, size, milk, shots, decaf := d.decaf }

/-- Exact USD cents; both native save and browser preview evaluate this rule. -/
def rule : PricingRule .usd := {
  base := ⟨450⟩
  adjustments := #[([.size .small], -75), ([.size .large], 100),
    ([.milk .oat], 75), ([.milk .almond], 75), ([.milk .soy], 50),
    ([.shots .single], -50), ([.shots .triple], 75), ([.temperature .iced], 25)] }

def price (draft : Draft) : Except String (Money .usd) := do
  let config ← draft.configuration
  (Ordering.preview rule config).mapError fun
    | .configuration .smallIced => "small_iced"
    | .configuration .decafTriple => "decaf_triple"
    | .pricing _ => "negative_price"

/-- Small primitive-only browser ABI; all decisions remain in the typed model above. -/
def preview (temperature size milk shots : String) (decaf : Bool) : String :=
  match price ⟨temperature, size, milk, shots, decaf⟩ with
  | .ok amount => "ok:" ++ toString amount.minor
  | .error code => "error:" ++ code

end Cafe
