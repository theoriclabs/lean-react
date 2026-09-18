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
