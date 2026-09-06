import LeanJS
import LeanReact
open Lean LeanReact

namespace HookTests

def useCounter (initial : Nat) : Hook (State Nat) := useState initial "counter"
def usePair (initial : Nat) : Hook Nat := do
  let a ← useCounter initial
  let b ← useState (a.value + 1) "second"
  pure (a.value + b.value)

def Good : Component Nat := component fun initial => do
  let n ← usePair initial
  pure (if n > 5 then text "large" else text "small")

def ValueBranch (flag : Bool) : Hook Nat := do
  let initial := if flag then 1 else 9
  let value ← useState initial "value-branch"
  pure (if flag then value.value else value.value + 1)

def SameBranches (flag : Bool) : Hook Nat :=
  if flag then do
    let x ← useState 1 "same"
    pure x.value
  else do
    let x ← useState 9 "same"
    pure (x.value + 1)

def BadBranch (flag : Bool) : Hook Nat :=
  if flag then do
    let x ← useState 0 "conditional"
    pure x.value
  else pure 0

def BadComponent : Component Bool := component fun flag => do
  let n ← BadBranch flag
  pure (text (toString n))

def ParentWithBadChild : Component Unit := component fun _ => pure (element BadComponent true)

def BadSites (flag : Bool) : Hook Nat :=
  if flag then do
    let x ← useState 0 "left"
    pure x.value
  else do
    let x ← useState 0 "right"
    pure x.value

def BadLoop (items : List Nat) : Hook Unit := do
  for n in items do
    let _ ← useState n "loop"
    pure ()

def BadRec : Nat → Hook Nat
  | 0 => pure 0
  | n+1 => do
    let _ ← useState n "recursive"
    BadRec n

def BadHigherOrder (work : Nat → Hook Nat) (n : Nat) : Hook Nat := work n

def BadDynamicSite (site : String) : Hook Nat := do
  let n ← useState 0 site
  pure n.value

-- A conditional choice of deferred child elements is an independent render boundary.
def ChildA : Component Nat := component fun n => do
  let a ← useState n "child-a"
  pure (text (toString a.value))
def ChildB : Component Nat := component fun n => do
  let a ← usePair n
  pure (text (toString a))
def ConditionalChildren : Component Bool := component fun flag =>
  pure (if flag then element ChildA 1 else element ChildB 2)

run_meta do
  for n in #[`HookTests.usePair, `HookTests.Good, `HookTests.ValueBranch, `HookTests.SameBranches, `HookTests.ConditionalChildren] do
    let some plan ← LeanJS.HookCheck.validate n | throwError "Missing hook plan for {n}"
    logInfo plan.compress
  for (n,needle) in #[
      (`HookTests.BadBranch, "inconsistent sequences"),
      (`HookTests.BadComponent, "inconsistent sequences"),
      (`HookTests.BadSites, "inconsistent sequences"),
      (`HookTests.ParentWithBadChild, "inconsistent sequences"),
      (`HookTests.BadLoop, "loop"),
      (`HookTests.BadRec, "recursive Hook"),
      (`HookTests.BadHigherOrder, "higher-order"),
      (`HookTests.BadDynamicSite, "dynamic hook site")
    ] do
    let result ← try
      let _ ← LeanJS.compile #[n]
      pure (none : Option String)
    catch e => pure (some (← e.toMessageData.toString))
    let some message := result | throwError "Expected hook rejection for {n}"
    unless (message.splitOn needle).length > 1 && (message.splitOn "Hook dependency path:").length > 1 do
      throwError "Wrong rejection for {n}: {message}"
    logInfo message
end HookTests
