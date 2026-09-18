/-!
Scalar-indexed string operations that are portable through LeanJS.

Core `String.take`/`drop`/`extract` and `Substring` work on byte positions and
`String.Slice`, which the LeanJS ABI does not represent. These definitions
index by Unicode scalar and are the native reference; the compiler recognises
them by name and substitutes a code-point loop (`engine/LeanJS/Runtime.js`).
Import only this module from portable code: it has no compiler dependency.
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

end String
