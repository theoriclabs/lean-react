import LeanJS
import Ordering

namespace Ordering.Probe
def price (n : Nat) : String :=
  match preview ({ base := ⟨n⟩, adjustments := #[([.milk .oat], 75)] } : PricingRule .usd)
      { milk := .oat } with
  | .ok m => "café ☕ " ++ toString m.minor
  | .error _ => "error"

def capacity (n : Nat) : Nat :=
  match Stock.fromRaw n 0 with
  | .error _ => 0
  | .ok stock => match stock.reserve n with
    | .error _ => 0
    | .ok stock => stock.reserved
end Ordering.Probe

run_meta do
  IO.FS.createDirAll "tests/ordering/.build"
  LeanJS.writeModule "tests/ordering/.build/probe.mjs" #[`Ordering.Probe.price, `Ordering.Probe.capacity]

def main : IO Unit := do
  IO.println (Ordering.Probe.price 123456789012345678901234567890)
  IO.println (Ordering.Probe.capacity 123456789012345678901234567890)
