import tests.compiler.Corpus
open Lean Corpus

private def strNat (n : Nat) := Json.str (toString n)
private def strInt (n : Int) := Json.str (toString n)
private def natArray (xs : Array Nat) := Json.arr (xs.map strNat)
private def ticketJson (t : Ticket) := Json.mkObj [("title", toJson t.title), ("priority", strNat t.priority)]
private def optionJson : Option String → Json
  | none => Json.null
  | some s => toJson s

def main : IO Unit := do
  let ns := #[0, 1, 2, 17, 9007199254740993, 123456789012345678901234567890]
  let zs : Array Int := #[-123456789012345678901234567890, -17, -1, 0, 1, 17, 123456789012345678901234567890]
  let mut arithmetic := #[]
  for a in ns do
    for b in ns do arithmetic := arithmetic.push (strNat (natural a b))
  let mut integers := #[]
  for a in zs do
    for b in zs do integers := integers.push (strInt (signed a b))
  let strings := #["", "ASCII", "A😀é中", "é", "𐀀\uE000", "quote\"slash\\\nline", "x\u0000y"]
  let records := strings.map fun s =>
    let t : Ticket := ⟨s, 9007199254740993, trivial⟩
    Json.mkObj [("updated", ticketJson (updateTicket t 9)), ("check", optionJson (titleCheck t))]
  let statuses := #[Status.waiting, .active "😀a" 8, .done 9007199254740993]
  let arrays := #[#[], #[1,2,3], #[9007199254740993,5]]
  let bounds : Array Nat := #[0,1,3,5,9007199254740993]
  let arrayRanges := arrays.flatMap fun xs => bounds.flatMap fun start => bounds.map fun stop =>
    Json.mkObj [("fold", strNat (arrayFold xs start stop)),
      ("filter", natArray (arrayFilter xs 2 start stop))]
  let result := Json.mkObj [
    ("iteration", Json.arr ((#[#[], #[1], #[2,3,0,9], #[9,0], #[1,2,3]] : Array (Array Nat)).map fun xs =>
      match scanExcept xs with
      | .ok n => Json.mkObj [("value", strNat n)]
      | .error message => Json.mkObj [("error", toJson message)])),
    ("monadicRanges", Json.arr ((#[#[], #[1,0,3], #[2,3,4]] : Array (Array Nat)).flatMap fun xs =>
      bounds.flatMap fun start => bounds.map fun stop =>
        match arrayFoldM xs start stop with | none => Json.null | some n => strNat n)),
    ("arrayRanges", Json.arr arrayRanges),
    ("observation", toJson observation),
    ("monadId", Json.arr (ns.map (strNat ∘ programId))),
    ("monadOption", Json.arr (ns.map fun n => match programOption n with | none => Json.null | some n => strNat n)),
    ("textOrder", Json.arr (strings.flatMap fun a => strings.map fun b => strNat (classifyText a b))),
    ("integerParts", Json.arr (zs.map (strNat ∘ integerParts))),
    ("nestedOption", Json.arr (#[none, some none, some (some 5)].map (strNat ∘ nestedOption))),
    ("arithmetic", Json.arr arithmetic), ("integers", Json.arr integers),
    ("texts", toJson (strings.map text)), ("chars", toJson (strings.map chars)),
    ("records", Json.arr records), ("statuses", Json.arr (statuses.map (strNat ∘ statusScore))),
    ("closures", Json.arr (ns.map fun n => strNat (useCapture n 7))),
    ("services", Json.arr (ns.map (strNat ∘ services))),
    ("typeclass", Json.arr (ns.map (strNat ∘ ticketScore))),
    ("recursive", Json.arr ((Array.range 16).map fun n => strNat (fibonacci n))),
    ("wellFounded", strNat (countdown 150)),
    ("mappedList", natArray (mapCaptured 9 ns.toList).toArray),
    ("listSmall", strNat (listLarge #[1, 2, 3])),
    ("listLarge", strNat (listLarge (Array.range 12000))),
    ("arrayWork", Json.arr (arrays.map fun xs => natArray (arrayWork xs 4))),
    ("arrayRead", Json.arr (arrays.map fun xs => Json.arr ((#[0, 1, 50] : Array Nat).map fun i => strNat (arrayRead xs i)))),
    ("arraySet", natArray (arraySet #[1,2,3] 1 99))]
  IO.println result.compress
