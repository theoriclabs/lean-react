import LeanJS
open Lean

namespace Rejected
@[extern "lean_nat_gcd"] def nativeOnly (a b : Nat) : Nat := Nat.gcd a b
def middle (n : Nat) := nativeOnly n 6
def root (n : Nat) := middle n + 1

unsafe def unsafeBody (n : Nat) := n + 1
@[implemented_by unsafeBody] def replaced (n : Nat) := n + 1
partial def partialLoop (n : Nat) : Nat := if n = 0 then 0 else partialLoop (n-1)

def badIO (path : String) := IO.FS.readFile path

run_meta do
  for (root, needle) in #[
      (`Rejected.root, "Rejected.root -> Rejected.middle -> Rejected.nativeOnly"),
      (`Rejected.replaced, "implemented_by"),
      (`Rejected.unsafeBody, "unsafe declaration"),
      (`Rejected.partialLoop, "partial or unsafe recursive"),
      (`Rejected.badIO, "Dependency path: Rejected.badIO ->")
    ] do
    let result ← try
      let _ ← LeanJS.compile #[root]
      pure (none : Option String)
    catch e => pure (some (← e.toMessageData.toString))
    let some message := result | throwError "Expected {root} to be rejected"
    unless (message.splitOn needle).length > 1 do
      throwError "Missing diagnostic {needle}: {message}"
    logInfo message
  let wrong : LeanJS.Options := {intrinsics := #[⟨`Rejected.nativeOnly, "./unused.mjs", "nativeOnly", 1⟩]}
  let result ← try
    let _ ← LeanJS.compile #[`Rejected.root] wrong
    pure (none : Option String)
  catch e => pure (some (← e.toMessageData.toString))
  let some message := result | throwError "Expected intrinsic arity mismatch"
  unless (message.splitOn "arity mismatch").length > 1 do throwError message
  logInfo message
end Rejected

namespace Rejected
def nonTail : List Nat → Nat
  | [] => 0
  | x :: xs => x + nonTail xs

def tailSum : List Nat → Nat → Nat
  | [], acc => acc
  | x :: xs, acc => tailSum xs (acc + x)
end Rejected

-- Non-tail self-recursion is reported with its call sites; the options escalate the note.
/--
info: LeanJS: Rejected.nonTail (42:0) recurses on the JavaScript stack; 1 self call is not a tail call:
  case List.cons > fun _f.12 > let _x.10 (generated variable v13)
Type: List Nat → Nat
Dependency path: Rejected.nonTail
Prefer the iterative List/Array/String builtins (engine/LeanJS/ABI.md), or an accumulator so that every self call is a tail call and compiles to a loop; otherwise chunk the input. set_option leanjs.recursion.warn or leanjs.recursion.error escalates this note.
-/
#guard_msgs in
run_meta do let _ ← LeanJS.compile #[`Rejected.nonTail]

/--
warning: LeanJS: Rejected.nonTail (42:0) recurses on the JavaScript stack; 1 self call is not a tail call:
  case List.cons > fun _f.12 > let _x.10 (generated variable v13)
Type: List Nat → Nat
Dependency path: Rejected.nonTail
Prefer the iterative List/Array/String builtins (engine/LeanJS/ABI.md), or an accumulator so that every self call is a tail call and compiles to a loop; otherwise chunk the input. set_option leanjs.recursion.warn or leanjs.recursion.error escalates this note.
-/
#guard_msgs in
set_option leanjs.recursion.warn true in
run_meta do let _ ← LeanJS.compile #[`Rejected.nonTail]

/--
error: LeanJS: Rejected.nonTail (42:0) recurses on the JavaScript stack; 1 self call is not a tail call:
  case List.cons > fun _f.12 > let _x.10 (generated variable v13)
Type: List Nat → Nat
Dependency path: Rejected.nonTail
Prefer the iterative List/Array/String builtins (engine/LeanJS/ABI.md), or an accumulator so that every self call is a tail call and compiles to a loop; otherwise chunk the input. set_option leanjs.recursion.warn or leanjs.recursion.error escalates this note.
-/
#guard_msgs in
set_option leanjs.recursion.error true in
run_meta do let _ ← LeanJS.compile #[`Rejected.nonTail]

-- Accumulator recursion compiles to a loop without a note, even under the error option.
#guard_msgs in
set_option leanjs.recursion.error true in
run_meta do let _ ← LeanJS.compile #[`Rejected.tailSum]

-- Reference-body support does not admit the unsafe native replacement itself.
run_meta do
  let result ← try
    let _ ← LeanJS.compile #[`Array.foldlMUnsafe]
    pure (none : Option String)
  catch e => pure (some (← e.toMessageData.toString))
  let some message := result | throwError "Expected unsafe native fold to be rejected"
  unless (message.splitOn "Array.foldlMUnsafe").length > 1 && (message.splitOn "unsafe declaration").length > 1 do
    throwError "Wrong native fold diagnostic: {message}"
  logInfo message

/-! ## Build-time checks (`#leanjs_check`, `@[leanjs_portable]`)

The check generation runs, during elaboration: a module that reaches native-only code fails
`lake build` with the dependency path `writeModule` would report. -/
namespace Rejected
def readsUInt (a b : UInt32) : Bool := a ≤ b
def portableRoot (a b : UInt32) := readsUInt a b
def sortedDesc (xs : List Nat) : List Nat := xs.mergeSort (fun a b => b ≤ a)
end Rejected

/--
error: LeanJS: unsupported native extern operation
Dependency path: Rejected.portableRoot -> Rejected.readsUInt -> UInt32.decLe
Supply a named intrinsic adapter or move this dependency outside portable code.
-/
#guard_msgs in
#leanjs_check Rejected.portableRoot

/--
error: LeanJS: unsupported native extern operation
Dependency path: Rejected.shout -> Rejected.readsUInt -> UInt32.decLe
Supply a named intrinsic adapter or move this dependency outside portable code.
-/
#guard_msgs in
@[leanjs_portable] def Rejected.shout (a : UInt32) : Bool := Rejected.readsUInt a a

-- Portable code passes silently, and `List.mergeSort` (log-depth recursion in core) is an
-- iterative builtin: no stack note, even under the error option.
#guard_msgs in
set_option leanjs.recursion.error true in
#leanjs_check Rejected.tailSum, Rejected.sortedDesc

#guard_msgs in
@[leanjs_portable] def Rejected.portableSum (xs : List Nat) : Nat := Rejected.tailSum xs 0

-- The recursion note is reported at build time too.
/--
error: LeanJS: Rejected.nonTail (42:0) recurses on the JavaScript stack; 1 self call is not a tail call:
  case List.cons > fun _f.12 > let _x.10 (generated variable v13)
Type: List Nat → Nat
Dependency path: Rejected.nonTail
Prefer the iterative List/Array/String builtins (engine/LeanJS/ABI.md), or an accumulator so that every self call is a tail call and compiles to a loop; otherwise chunk the input. set_option leanjs.recursion.warn or leanjs.recursion.error escalates this note.
-/
#guard_msgs in
set_option leanjs.recursion.error true in
#leanjs_check Rejected.nonTail

-- `using` supplies options, e.g. a UI library's intrinsics (here: none, so `Nat.gcd`'s extern
-- is replaced by a trusted adapter and the check passes).
#guard_msgs in
#leanjs_check Rejected.root using { intrinsics := #[{ leanName := `Rejected.nativeOnly, module := "./gcd.mjs", exportName := "gcd", arity := 2 }] }

-- `@[leanjs_stack_safe]` marks recursion bounded by the data's shape: no note, even as an error.
namespace Rejected
@[leanjs_stack_safe] def treeDepth : List Nat → Nat
  | [] => 0
  | _ :: rest => treeDepth rest + 1
end Rejected

#guard_msgs in
set_option leanjs.recursion.error true in
#leanjs_check Rejected.treeDepth
