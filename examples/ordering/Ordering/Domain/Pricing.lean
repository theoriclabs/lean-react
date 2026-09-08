import Ordering.Domain.Configuration

namespace Ordering

/-- Stored rule data: all matching signed adjustments apply; first matching override wins.
    Unlike Eats, adjustments are arbitrary precision and negative totals are errors. -/
structure PricingRule (currency : Currency) where
  base : Money currency
  adjustments : Array (Pattern × Int) := #[]
  overrides : Array (Pattern × Money currency) := #[]

inductive PricingError where
  | negativeTotal (minor : Int)
  deriving Repr, BEq, DecidableEq

def PricingRule.evaluate (rule : PricingRule c) (config : AdmissibleConfiguration) :
    Except PricingError (Money c) :=
  match rule.overrides.find? (fun entry => entry.1.matches config.value) with
  | some entry => .ok entry.2
  | none =>
    let total := rule.adjustments.foldl (fun total entry =>
      if entry.1.matches config.value then total + entry.2 else total) (Int.ofNat rule.base.minor)
    if total < 0 then .error (.negativeTotal total) else .ok ⟨total.toNat⟩

inductive PreviewError where
  | configuration (error : ConfigurationError)
  | pricing (error : PricingError)
  deriving Repr, BEq, DecidableEq

def preview (rule : PricingRule c) (config : Configuration) : Except PreviewError (Money c) := do
  let checked ← config.check.mapError PreviewError.configuration
  rule.evaluate checked |>.mapError PreviewError.pricing

end Ordering
