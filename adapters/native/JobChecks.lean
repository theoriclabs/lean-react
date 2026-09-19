import LeanAppNative.Jobs
import LeanDb.Derive

open LeanAppNative.Jobs

structure Marker where
  n : Nat
  deriving Repr, LeanDb.Entity

/-- 4 KiB per row, so a few thousand rows make a backup that takes real time. -/
structure Blob where
  body : String
  deriving Repr, LeanDb.Entity

def base : LeanDb.Base := { name := "jobs_fixture", tables := [.of Marker] }
def bigBase : LeanDb.Base := { name := "jobs_big", tables := [.of Marker, .of Blob] }

def check (label : String) (ok : Bool) : IO Unit := do
  unless ok do throw (IO.userError s!"FAIL: {label}")
  IO.println s!"PASS: {label}"

def expect [ToString ε] (value : Except ε α) : IO α :=
  match value with | .ok a => pure a | .error e => throw (IO.userError (toString e))

def openService (base : LeanDb.Base) (inst : LeanDb.Instance)
    (config : LeanAppNative.Runtime.Config := {}) : IO LeanAppNative.Runtime.Service := do
  match ← LeanAppNative.Runtime.Service.new base inst (config := config) with
  | .ok service => pure service
  | .error e => throw (IO.userError s!"open failed: {e.message}")

def backupFile (dir : System.FilePath) : IO System.FilePath := do
  let produced ← dir.readDir
  let some file := produced.toList.find? (fun e => e.fileName.startsWith "backup-" && e.fileName.endsWith ".sqlite")
    | throw (IO.userError "FAIL: backup produced no file")
  pure file.path

def main (args : List String) : IO Unit := do
  let [directory] := args | throw (IO.userError "usage: job_checks <fresh-fixture-directory>")
  let dir : System.FilePath := directory
  let inst := LeanDb.Instance.ofPath (dir / "jobs.sqlite")
  let service ← openService base inst
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
    check "readers := 0 warns that a reader-lane job's reads use the writer" warned
    let restored := LeanDb.Instance.ofPath (← backupFile backups)
    let rservice ← openService base restored
    try
      let rows ← match ← rservice.withConnection fun conn =>
          LeanDb.DbM.run conn (LeanDb.fetchAll Marker) with
      | .ok (.ok rows) => pure rows
      | _ => throw (IO.userError "FAIL: restore read")
      check "backup file restores Marker rows" (rows.any (fun r => r.val.n == 7))
    finally rservice.close
    check "backup job is constructible" true
  finally service.close

  -- LA-16: a backup on the reader lane runs while commits keep landing on the writer.
  let big ← openService bigBase (LeanDb.Instance.ofPath (dir / "big.sqlite")) { readers := 1 }
  try
    let body := String.ofList (List.replicate 4096 'x')
    match ← big.withConnection fun conn => LeanDb.DbM.run conn (LeanDb.withTransaction do
        for _ in [:5000] do discard <| LeanDb.insert Blob ⟨body⟩) with
    | .ok (.ok _) => pure ()
    | _ => throw (IO.userError "FAIL: seed blobs")
    let sched ← Scheduler.new
    let waits ← IO.mkRef (#[] : Array Nat)
    let bigBackups := dir / "big-backups"
    Scheduler.start sched big [backup bigBackups 7]
    let storm ← IO.asTask (prio := .dedicated) do
      for i in [:200] do
        let queued ← IO.monoMsNow
        discard <| big.withConnection fun conn => do
          waits.modify (·.push ((← IO.monoMsNow) - queued))
          LeanDb.DbM.run conn (LeanDb.withTransaction (discard <| LeanDb.insert Marker ⟨i⟩))
        IO.sleep 5
    IO.ofExcept storm.get
    for _ in [:1000] do
      if (← sched.runs.get) ≥ 1 then break
      IO.sleep 10
    Scheduler.stop sched
    let sorted := (← waits.get).qsort (· < ·)
    let p95 := sorted[sorted.size * 95 / 100]?.getD 0
    IO.println s!"backup storm: {sorted.size} commits; writer admission wait p95 {p95} ms, max {sorted.back?.getD 0} ms"
    check "LA-16: the backup ran on the reader lane while the writer kept committing" ((← sched.runs.get) ≥ 1)
    check "LA-16: no commit waited more than 50 ms on admission during the backup (p95)" (p95 < 50)
    check "LA-16: with a reader pool no warning is emitted" ((← sched.warnings.get).isEmpty)
    let copy ← openService bigBase (LeanDb.Instance.ofPath (← backupFile bigBackups))
    try
      let rows ← match ← copy.withConnection fun conn => LeanDb.DbM.run conn (LeanDb.fetchAll Blob) with
      | .ok (.ok rows) => pure rows
      | _ => throw (IO.userError "FAIL: read the reader-lane backup")
      check "LA-16: the reader-lane backup restores every seeded row" (rows.size == 5000)
    finally copy.close
  finally big.close
  IO.println "PASS job scheduler qualification"
