/- Checked representation adapters: `Interval` and `SortedList` (private constructors, declared
   in a library-free module) become entity fields, record fields and op inputs/outputs. -/
import tests.domain.RepresentTypes
import LeanApp.Core
open LeanApp.Core

/-- An interval is stored and sent as its bounds, and read back through `Interval.check`. -/
represent Interval as Nat × Nat by Interval.toPair checked Interval.check
/-- A sorted list is stored and sent as its items, and read back through `SortedList.ofList?`. -/
represent SortedList as List Nat by SortedList.items checked SortedList.ofList?

/-! ## What `represent` generated -/

/-- info: Interval.representation : Representation Interval (Nat × Nat) -/
#guard_msgs in #check Interval.representation

/--
info: def Interval.representation : Representation Interval (Nat × Nat) :=
{ encode := Interval.toPair, check := LeanApp.Domain.RepresentationCheck.check Interval.check,
  checker := "Interval.check" }
-/
#guard_msgs in #print Interval.representation

/-- info: Interval.instWire -/
#guard_msgs in #synth Ontology.Wire Interval
/-- info: Interval.instStorageCodec -/
#guard_msgs in #synth LeanApp.Domain.StorageCodec Interval
/-- info: Interval.instFieldType -/
#guard_msgs in #synth LeanApp.Domain.FieldType Interval
/-- info: Interval.instHasTypeId -/
#guard_msgs in #synth Ontology.HasTypeId Interval
/-- info: SortedList.instWire -/
#guard_msgs in #synth Ontology.Wire SortedList

namespace RepresentFixture

def interval (lo hi : Nat) (h : lo ≤ hi := by decide) : Interval := Interval.make lo hi h

def sorted (items : List Nat) : SortedList := match SortedList.ofList? items with
  | .ok value => value
  | .error _ => SortedList.empty

def decodes [BEq α] (codec : Ontology.Codec α) (json : Lean.Json) (expected : α) : Bool :=
  match codec.decode json with | .ok value => value == expected | .error _ => false

def rejection (codec : Ontology.Codec α) (json : Lean.Json) : Option (String × List (String × String)) :=
  match codec.decode json with
  | .ok _ => none
  | .error errors => some (errors.first.code, errors.first.params)

-- Wire: the representation's form, under the type's own name.
#guard (Ontology.Wire.codec (α := Interval)).schema ==
  .named { packageName := "domain", name := "Interval" } "1" (.product .natural .natural)
#guard (Ontology.Wire.codec (α := SortedList)).schema ==
  .named { packageName := "domain", name := "SortedList" } "1" (.list .natural)
#guard (Ontology.Wire.codec (α := Interval)).encode (interval 2 5) == Lean.Json.arr #[.num 2, .num 5]
#guard decodes (Ontology.Wire.codec (α := Interval)) (.arr #[.num 2, .num 5]) (interval 2 5)
#guard decodes (Ontology.Wire.codec (α := SortedList)) (.arr #[.num 1, .num 1, .num 4]) (sorted [1, 1, 4])
-- Invalid input is rejected with the type, the checker and its reason.
#guard rejection (Ontology.Wire.codec (α := Interval)) (.arr #[.num 5, .num 2]) ==
  some ("decode.invalid_representation", [("type", "Interval"), ("check", "Interval.check"), ("reason", "rejected")])
#guard rejection (Ontology.Wire.codec (α := SortedList)) (.arr #[.num 3, .num 1]) ==
  some ("decode.invalid_representation",
    [("type", "SortedList"), ("check", "SortedList.ofList?"), ("reason", "items are not in nondecreasing order")])
-- A malformed representation fails in the representation's own codec.
#guard (rejection (Ontology.Wire.codec (α := Interval)) (.str "2..5")).isSome

end RepresentFixture

/-! ## As entity fields, record fields, op inputs and outputs -/

structure Booking where
  room  : Name
  slot  : Interval
  seats : SortedList
  deriving Entity

#guard (LeanApp.Domain.Domain.fields (T := Booking)).map (fun f => (f.name, f.kind == .value)) ==
  [("room", false), ("slot", true), ("seats", true)]

inductive BookError where
  | tooLong

def book (room : Name) (slot : Interval) (seats : SortedList) : Op BookError (Ref Booking) := do
  let ⟨_short⟩ ← require (slot.hi - slot.lo ≤ 8) .tooLong
  Booking.insert { room, slot, seats }

structure BookingView where
  slot  : Interval
  seats : SortedList

inductive ShowError where
  | notFound

def showBooking (booking : Ref Booking) : ReadOp ShowError BookingView := do
  let some b ← Booking.find booking | throw .notFound
  return { slot := b.slot, seats := b.seats }

def api : Api := [
  post "/bookings"          book,
  get  "/bookings/:booking" showBooking
]

/-- info: api.showBooking (booking : Ref Booking) : Endpoint showBooking.Input ShowError BookingView -/
#guard_msgs in #check api.showBooking
#guard book.operation.contract.describe.input ==
  .named { packageName := "domain", name := "book.Input" } "1" (.record [("room", .string),
    ("slot", .named { packageName := "domain", name := "Interval" } "1" (.product .natural .natural)),
    ("seats", .named { packageName := "domain", name := "SortedList" } "1" (.list .natural))])
