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

    let readerHits ← IO.mkRef (0 : Nat)
    let writerHits ← IO.mkRef (0 : Nat)
    let concurrent ← Scheduler.new
    Scheduler.start concurrent service [
      { name := "slow-reader", everyMs := 10000, initialDelayMs := 0, lane := .reader,
        run := fun ctx => do
          match ← ctx.withReader fun _ => IO.sleep 200 with
          | .ok _ => readerHits.modify (· + 1); return .done
          | .error _ => return .failed "reader" },
      { name := "fast-writer", everyMs := 20, initialDelayMs := 0,
        run := fun _ => do writerHits.modify (· + 1); return .done }
    ] (readers := 1)
    IO.sleep 250
    Scheduler.stop concurrent
    IO.sleep 50
    let rh ← readerHits.get
    let wh ← writerHits.get
    check "reader jobs run concurrently with the writer loop" (rh ≥ 1 && wh ≥ 5)

    let isolated ← Scheduler.new
    let writerAfter ← IO.mkRef (0 : Nat)
    Scheduler.start isolated service [
      { name := "boom-reader", everyMs := 40, initialDelayMs := 0, lane := .reader,
        run := fun _ => throw (IO.userError "reader-boom") },
      { name := "writer-tick", everyMs := 30, initialDelayMs := 0,
        run := fun _ => do writerAfter.modify (· + 1); return .done }
    ] (readers := 1)
    IO.sleep 200
    Scheduler.stop isolated
    check "a throwing reader job does not stop the writer loop" ((← writerAfter.get) ≥ 3)

    match ← service.withConnection fun conn =>
        LeanDb.DbM.run conn (LeanDb.insert Marker ⟨7⟩) with
    | .ok (.ok _) => pure ()
    | _ => throw (IO.userError "FAIL: insert Marker")
    let backups := dir / "backups"
    let once ← Scheduler.new
    Scheduler.start once service [backup backups 7] (readers := 0)
    IO.sleep 400
    Scheduler.stop once
    let warned := (← once.warnings.get).any (·.contains "withReader is the writer")
    check "readers := 0 warns that backup will block writes" warned
    let produced ← backups.readDir
    let some file := produced.toList.find? (fun e => e.fileName.startsWith "backup-" && e.fileName.endsWith ".sqlite")
      | throw (IO.userError "FAIL: backup produced no file")
    let restored := LeanDb.Instance.ofPath file.path
    let rsession ← expect (← LeanDb.Cli.Session.open base restored)
    let rservice ← LeanDb.Runtime.Service.new base restored rsession true
    try
      let rows ← match ← rservice.withConnection fun conn =>
          LeanDb.DbM.run conn (LeanDb.fetchAll Marker) with
      | .ok (.ok rows) => pure rows
      | _ => throw (IO.userError "FAIL: restore read")
      check "backup file restores Marker rows" (rows.any (fun r => r.val.n == 7))
    finally rservice.close
    check "backup job is constructible" true
    IO.println "PASS job scheduler qualification"
  finally service.close
