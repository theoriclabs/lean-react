/-!
Scalar-indexed string operations that are portable through LeanJS.

Core `String.take`/`drop`/`extract` and `Substring` work on byte positions and
`String.Slice`, which the LeanJS ABI does not represent. These definitions
index by Unicode scalar and are the native reference; the compiler recognises
them by name and substitutes a code-point loop (`engine/LeanJS/Runtime.js`).
Import only this module from portable code: it has no compiler dependency.

Core `Char.isDigit`/`isAlpha`/`isUpper`/`isLower`/`isAlphanum`/`toUpper`/`toLower`,
`String.map`/`toUpper`/`toLower`, `String.splitOn`, `String.toNat?`/`toInt?` and
`String.isNat`/`isInt` are substituted by the compiler, so ordinary code using them is
portable. Core `startsWith`, `endsWith`, `replace`, `trimAscii` and `lines` work on
`String.Slice`; their portable counterparts here (`hasPrefix`, `hasSuffix`, `replaceAll`,
`trimWhitespace`, `splitLines`, `splitWords`) return `String`s. Number formatting
(`Nat.formatGrouped`, `Nat.formatRatio`, `Nat.formatPercent`) is ordinary portable Lean.
-/

namespace String

/-- The first `n` scalars of `s`, or all of `s` when it is shorter. -/
def takeScalars (s : String) (n : Nat) : String := String.ofList (s.toList.take n)

/-- `s` without its first `n` scalars; empty when `s` is shorter. -/
def dropScalars (s : String) (n : Nat) : String := String.ofList (s.toList.drop n)

/-- Up to `len` scalars of `s` starting at scalar index `start`. -/
def extractScalars (s : String) (start len : Nat) : String := String.ofList ((s.toList.drop start).take len)

/-- The number of scalars in `s`; the same value as `String.length`. -/
def scalarLength (s : String) : Nat := s.length

/-- Left fold over the scalars of `s`, in order. -/
def foldlScalars {β : Type u} (f : β → Char → β) (init : β) (s : String) : β := s.toList.foldl f init

/-- Build a string from scalars without a recursive list. -/
def ofScalars (cs : Array Char) : String := String.ofList cs.toList

/-- `true` when `s` starts with `pre` (core `startsWith` with a `String` pattern). -/
def hasPrefix (s pre : String) : Bool := pre.toList.isPrefixOf s.toList

/-- `true` when `s` ends with `suf` (core `endsWith` with a `String` pattern). -/
def hasSuffix (s suf : String) : Bool := suf.toList.reverse.isPrefixOf s.toList.reverse

/-- Every leftmost non-overlapping `pattern` replaced (core `replace` with a `String` pattern).
An empty `pattern` matches before every scalar and at the end, as in core. -/
def replaceAll (s pattern replacement : String) : String :=
  if pattern.isEmpty then replacement ++ String.join (s.toList.map fun c => c.toString ++ replacement)
  else replacement.intercalate (s.splitOn pattern)

/-- `s` without leading and trailing `Char.isWhitespace` (space, tab, CR, LF). -/
def trimWhitespace (s : String) : String :=
  String.ofList ((s.toList.dropWhile Char.isWhitespace).reverse.dropWhile Char.isWhitespace).reverse

/-- The lines of `s` (core `String.lines`): split on `\n`, a `\r` directly before a `\n`
dropped, and no empty line after a final newline. -/
def splitLines (s : String) : List String :=
  let parts := s.splitOn "\n"
  let ended := parts.dropLast.map fun line =>
    if line.hasSuffix "\r" then String.ofList line.toList.dropLast else line
  match parts.getLast? with
  | some "" | none => ended
  | some last => ended ++ [last]

/-- The words of `s`: maximal runs of non-whitespace scalars. -/
def splitWords (s : String) : List String :=
  (s.splitToList Char.isWhitespace).filter (!·.isEmpty)

end String

namespace Nat

/-- Decimal digits in groups of three: `262144` is `262,144`. -/
def formatGrouped (n : Nat) (separator : String := ",") : String :=
  let digits := (toString n).toList
  let count := digits.length
  (digits.zipIdx.foldl (fun (out : List Char) (digit, i) =>
    let lead := if i != 0 && (count - i) % 3 == 0 then separator.toList.reverse else []
    digit :: (lead ++ out)) []).reverse |> String.ofList

/-- `num / den` rounded half up to `digits` decimals, without `Float`: `formatRatio 2520 200 2`
is `12.60`. A zero denominator gives `"—"`. -/
def formatRatio (num den : Nat) (digits : Nat) : String :=
  if den == 0 then "—" else
  let scale := 10 ^ digits
  let scaled := (2 * num * scale + den) / (2 * den)
  let whole := toString (scaled / scale)
  if digits == 0 then whole else
  let fraction := toString (scaled % scale)
  whole ++ "." ++ String.ofList (List.replicate (digits - fraction.length) '0') ++ fraction

/-- `num / den` as a percentage with `digits` decimals: `formatPercent 1 3 1` is `33.3%`. -/
def formatPercent (num den : Nat) (digits : Nat) : String :=
  if den == 0 then "—" else formatRatio (100 * num) den digits ++ "%"

end Nat

namespace Int

/-- `Nat.formatGrouped` with a leading `-` for negative values. -/
def formatGrouped (n : Int) (separator : String := ",") : String :=
  (if n < 0 then "-" else "") ++ n.natAbs.formatGrouped separator

end Int

namespace List

/-- Insert `x` before the first element it does not follow (`le y x` false); in a list sorted
by `le` the result stays sorted, after any elements equal to `x`. Iterative. -/
def insertSorted (le : α → α → Bool) (x : α) (xs : List α) : List α :=
  let (before, after, placed) := xs.foldl (fun (before, after, placed) y =>
    if placed then (before, y :: after, true)
    else if le y x then (y :: before, after, false)
    else (before, y :: x :: after, true)) ([], [], false)
  if placed then before.reverse ++ after.reverse else (x :: before).reverse

end List
