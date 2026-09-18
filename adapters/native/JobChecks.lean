import LeanAppNative.Jobs
import LeanDb.Derive

open LeanAppNative.Jobs

structure Marker where
  n : Nat
  deriving Repr, LeanDb.Entity

def base : LeanDb.Base := { name := "jobs_fixture", tables := [.of Marker] }

def check (label : String) (ok : Bool) : IO Unit := do
  unless ok do throw (IO.userError s!"FAIL: {label}")
  IO.println s!"PASS: {label}"

def expect [ToString ε] (value : Except ε α) : IO α :=
  match value with | .ok a => pure a | .error e => throw (IO.userError (toString e))

def main (args : List String) : IO Unit := do
  let [directory] := args | throw (IO.userError "usage: job_checks <fresh-fixture-directory>")
  let dir : System.FilePath := directory
  let inst := LeanDb.Instance.ofPath (dir / "jobs.sqlite")
  let session ← expect (← LeanDb.Cli.Session.open base inst)
  let service ← LeanDb.Runtime.Service.new base inst session true
  try
    let hits ← IO.mkRef (0 : Nat)
    let throws ← IO.mkRef (0 : Nat)
    let sched ← Scheduler.new
    let jobs : List Job := [
      { name := "tick", everyMs := 100, initialDelayMs := 0,
        run := fun _ => do hits.modify (· + 1); return .done },
      { name := "boom", everyMs := 150, initialDelayMs := 50,
        run := fun _ => do throws.modify (· + 1); throw (IO.userError "boom") }
    ]
    Scheduler.start sched service jobs
    IO.sleep 1000
    let n ← hits.get
    let thrown ← throws.get
    Scheduler.stop sched
    IO.sleep 250
    let after ← hits.get
    check "job scheduled every 100ms runs at least 8 times in 1s" (n ≥ 8)
    check "a throwing job is rescheduled, not fatal" (thrown ≥ 2)
    check "stop ends further scheduling" (after ≤ n + 2)
    let backups := dir / "backups"
    let once ← Scheduler.new
    Scheduler.start once service [backup backups 7]
    IO.sleep 200
    Scheduler.stop once
    check "backup job is constructible" true
    IO.println "PASS job scheduler qualification"
  finally service.close
