import tests.compiler.Corpus
open Lean Corpus

private def strNat (n : Nat) := Json.str (toString n)
private def strInt (n : Int) := Json.str (toString n)
private def natArray (xs : Array Nat) := Json.arr (xs.map strNat)
private def ticketJson (t : Ticket) := Json.mkObj [("title", toJson t.title), ("priority", strNat t.priority)]
private def optionJson : Option String → Json
  | none => Json.null
  | some s => toJson s

/-- A linear congruential generator mirrored in `compiler.test.mjs`. -/
private def next (seed bound : Nat) : Nat × Nat :=
  let seed := (seed * 1103515245 + 12345) % 2147483648
  (seed / 65536 % bound, seed)

/-- Random scalars: ASCII, Latin-1, CJK, emoji, ZWJ family members, a variation
selector, a skin-tone modifier, the first/last astral scalars, private use, NUL. -/
private def palette : Array Nat := #[0x41, 0x62, 0x7A, 0x20, 0xE9, 0x4E2D, 0x1F600, 0x200D, 0x1F468,
  0x1F469, 0x1F467, 0xFE0F, 0x1F3FD, 0x10000, 0x10FFFF, 0xE000, 0xD7FF, 0x0]

private def digestNat (h x : Nat) : Nat := (h * 1000003 + x + 1) % 1000000007
private def digestNats (h : Nat) (xs : List Nat) : Nat := xs.foldl digestNat h
private def digestString (h : Nat) (s : String) : Nat := digestNats h (s.toList.map Char.toNat)

private structure Random where
  strings : Nat := 7
  lists : Nat := 7
  arrays : Nat := 7
  loops : Nat := 7
  stringSamples : Array Json := #[]
  listSamples : Array Json := #[]
  arraySamples : Array Json := #[]

/-- 10,000 random strings/lists/arrays through every new builtin; the digest and
the first samples are compared with the generated module. -/
private def random : Random := Id.run do
  let mut seed := 20250918
  let mut out : Random := {}
  for _ in [:10000] do
    let (len, s1) := next seed 25
    seed := s1
    let mut scalars : Array Char := #[]
    for _ in [:len] do
      let (i, s2) := next seed palette.size
      seed := s2
      scalars := scalars.push (Char.ofNat palette[i]!)
    let (n, s3) := next seed (len + 3)
    let (k, s4) := next s3 (len + 3)
    seed := s4
    let text := scalarOps (String.ofList scalars.toList) n k
    out := { out with
      strings := digestString out.strings text
      stringSamples := if out.stringSamples.size < 64 then out.stringSamples.push (toJson text) else out.stringSamples }
    let (count, s5) := next seed 13
    seed := s5
    let mut xs : Array Nat := #[]
    for _ in [:count] do
      let (x, s6) := next seed 100
      seed := s6
      xs := xs.push x
    let (i, s7) := next seed (count + 2)
    let (m, s8) := next s7 (count + 3)
    seed := s8
    let listed := listOps xs.toList m
    let arrayed := arrayOps xs i n
    let looped := [sumAcc xs.toList n, countLoop n m, sumEven xs.toList m, sumWhere xs.toList]
    out := { out with
      lists := digestNats out.lists listed
      arrays := digestNats out.arrays arrayed.toList
      loops := digestNats out.loops looped
      listSamples := if out.listSamples.size < 32 then out.listSamples.push (natArray listed.toArray) else out.listSamples
      arraySamples := if out.arraySamples.size < 32 then out.arraySamples.push (natArray arrayed) else out.arraySamples }
  return out

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
    ("listSlices", Json.arr (((#[#[], #[1,2,3], Array.range 12000] : Array (Array Nat)).flatMap fun xs =>
      (#[0, 1, 6000, 12000, 9007199254740993] : Array Nat).map fun n => strNat (listSlices xs n)))),
    ("randomStrings", strNat random.strings), ("randomStringSamples", Json.arr random.stringSamples),
    ("randomLists", strNat random.lists), ("randomListSamples", Json.arr random.listSamples),
    ("randomArrays", strNat random.arrays), ("randomArraySamples", Json.arr random.arraySamples),
    ("randomLoops", strNat random.loops),
    ("loops", natArray #[sumAcc (List.range 12000) 5, countLoop 12000 0, sumEven (List.range 12000) 0, sumWhere (List.range 12000)]),
    ("arrayWork", Json.arr (arrays.map fun xs => natArray (arrayWork xs 4))),
    ("arrayRead", Json.arr (arrays.map fun xs => Json.arr ((#[0, 1, 50] : Array Nat).map fun i => strNat (arrayRead xs i)))),
    ("arraySet", natArray (arraySet #[1,2,3] 1 99))]
  IO.println result.compress
