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

-- Supporting Array.foldl does not globally admit its native monadic implementation.
def rejectedNativeFold (xs : Array Nat) : Nat := Id.run (xs.foldlM (fun a b => pure (a+b)) 0)
run_meta do
  let result ← try
    let _ ← LeanJS.compile #[`rejectedNativeFold]
    pure (none : Option String)
  catch e => pure (some (← e.toMessageData.toString))
  let some message := result | throwError "Expected unregistered foldlM to be rejected"
  unless (message.splitOn "Array.foldlM").length > 1 && (message.splitOn "implemented_by").length > 1 do
    throwError "Wrong native fold diagnostic: {message}"
  logInfo message
