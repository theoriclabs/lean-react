/- Represented fields on the Memory backend: round trip, and a stored value the checker
   rejects surfaces as a typed decode fault, never as a value. -/
import tests.domain.Represent
import LeanApp.Domain.Memory
open LeanApp.Domain Ontology RepresentFixture

namespace RepresentRun

private def check (label : String) (condition : Bool) : IO Unit :=
  unless condition do throw (IO.userError ("FAIL: " ++ label))
private def ok [Repr E] (value : Except E A) : IO A :=
  match value with | .ok value => pure value | .error error => throw (IO.userError (reprStr error))
private def parsed (value : Validation A) : IO A :=
  match value with | .ok value => pure value | .error _ => throw (IO.userError "fixture value rejected")

deriving instance Repr for BookError
deriving instance Repr for ShowError

/-- Replace one field of every stored `Booking` row (simulating a corrupted or foreign write). -/
private def tamper (store : Memory.Store) (field : String) (value : Lean.Json) : Memory.Store :=
  { store with rows := store.rows.map fun (key, json) =>
      if key.entity.name == "Booking" then (key, json.setObjVal! field value) else (key, json) }

def main : IO Unit := do
  let initial : Memory.Store := { now := ← parsed (Instant.ofEpochSeconds 1000) }
  let room ← parsed (Name.parse "Lab")
  -- Through the op: inputs and outputs are the represented types.
  let (created, store) ← ok (Memory.command (book room (interval 2 5) (sorted [1, 3, 3]) : Flow .command OpScope BookError _) initial)
  let booking ← ok created
  let (shown, _) ← ok (Memory.read (showBooking booking : Flow .query OpScope ShowError _) store)
  let view ← ok shown
  check "storage round trip" (view.slot == interval 2 5 && view.seats == sorted [1, 3, 3])
  -- Stored as the representation.
  let stored := store.rows.find? (·.1.entity.name == "Booking") |>.map (·.2)
  check "stored as the representation" (stored.map (fun json => (json.getObjValD "slot", json.getObjValD "seats")) ==
    some (.arr #[.num 2, .num 5], .arr #[.num 1, .num 3, .num 3]))
  -- A stored interval the checker rejects is a decode fault naming the type and checker.
  let corrupted := tamper store "slot" (.arr #[.num 9, .num 1])
  match Memory.read (showBooking booking : Flow .query OpScope ShowError _) corrupted with
  | .error (.decode errors) =>
    check "corruption is typed" (errors.first.code == "decode.invalid_representation" &&
      errors.first.params.lookup "type" == some "Interval" && errors.first.params.lookup "check" == some "Interval.check")
  | .error other => throw (IO.userError s!"FAIL: unexpected fault {reprStr other}")
  | .ok _ => throw (IO.userError "FAIL: a rejected stored interval was read as a value")
  let unsorted := tamper store "seats" (.arr #[.num 4, .num 2])
  match Memory.read (showBooking booking : Flow .query OpScope ShowError _) unsorted with
  | .error (.decode errors) => check "unsorted list rejected on read" (errors.first.params.lookup "check" == some "SortedList.ofList?")
  | _ => throw (IO.userError "FAIL: a rejected stored list was read as a value")
  IO.println "PASS represent: op inputs/outputs, storage round trip as the representation, rejected stored values are decode faults"

end RepresentRun

def main := RepresentRun.main
