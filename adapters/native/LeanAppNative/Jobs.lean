import LeanDb.Runtime
import Std.Data.HashMap

namespace LeanAppNative.Jobs

inductive Outcome where
  | done
  | continue (state : Lean.Json)
  | failed (code : String)
  deriving BEq

/-- Writer jobs stay serial and inside `budgetPerSliceMs`. Reader jobs (backup,
    reports) may run concurrently, bounded by the reader pool; they are exempt
    from the slice budget because `VACUUM INTO` cannot be sliced. -/
inductive Lane where
  | writer
  | reader
  deriving BEq, Repr

structure Context where
  withWriter : {α : Type} → (LeanDb.Conn → IO α) → IO (Except LeanDb.Runtime.AdmissionError α)
  withReader : {α : Type} → (LeanDb.Conn → IO α) → IO (Except LeanDb.Runtime.AdmissionError α)
  deadline : Nat
  log : String → IO Unit

abbrev JobContext := Context

structure Job where
  name : String
  everyMs : Nat
  initialDelayMs : Nat := everyMs
  run : Context → IO Outcome
  budgetPerSliceMs : Nat := 50
  singleFlight : Bool := true
  lane : Lane := .writer

structure Scheduler where
  private stopping : IO.Ref Bool
  private last : IO.Ref (Std.HashMap String Nat)
  private readerActive : IO.Ref Nat
  runs : IO.Ref Nat
  /-- Warnings emitted at start (reader jobs with `readers := 0`). -/
  warnings : IO.Ref (Array String)

def Scheduler.new : IO Scheduler :=
  return ⟨← IO.mkRef false, ← IO.mkRef {}, ← IO.mkRef 0, ← IO.mkRef 0, ← IO.mkRef #[]⟩

def Scheduler.stop (s : Scheduler) : IO Unit := s.stopping.set true

private def runJob (s : Scheduler) (ctx : Context) (job : Job) : IO Unit := do
  try
    match ← job.run ctx with
    | .done | .failed _ =>
      s.last.modify (·.insert job.name ((← IO.monoMsNow) + job.everyMs))
    | .continue _ =>
      s.last.modify (·.insert job.name (← IO.monoMsNow))
    s.runs.modify (· + 1)
  catch _ =>
    ctx.log s!"threw; rescheduling"
    s.last.modify (·.insert job.name ((← IO.monoMsNow) + job.everyMs))

/-- Cooperative loop: one writer job at a time; reader jobs run concurrently
    up to `readers`. With `readers := 0`, `withReader` is the writer (LeanDB's
    fallback) and reader-lane jobs log a warning at start. -/
def Scheduler.start (s : Scheduler) (service : LeanDb.Runtime.Service) (jobs : List Job)
    (readers : Nat := 0) : IO Unit := do
  let started ← IO.monoMsNow
  for job in jobs do
    s.last.modify (·.insert job.name (started + job.initialDelayMs))
    if job.lane == .reader && readers == 0 then
      let msg := s!"job {job.name}: withReader is the writer (readers := 0); this job will block writes"
      s.warnings.modify (·.push msg)
      IO.println msg
  discard <| IO.asTask (prio := .dedicated) do
    repeat
      if ← s.stopping.get then break
      let now ← IO.monoMsNow
      let last ← s.last.get
      match jobs.find? (fun j => last.getD j.name now ≤ now) with
      | none => IO.sleep 20
      | some job =>
        if job.lane == .reader && readers > 0 then
          let active ← s.readerActive.get
          if active ≥ readers then
            IO.sleep 5
          else
            s.readerActive.modify (· + 1)
            -- Claim the slot so the loop does not pick the same due job again
            -- before the task records its next run time.
            s.last.modify (·.insert job.name (now + job.everyMs))
            discard <| IO.asTask (prio := .dedicated) do
              let ctx : Context := {
                withWriter := service.withConnection
                withReader := service.withConnection
                deadline := now + job.budgetPerSliceMs
                log := fun msg => IO.println s!"job {job.name}: {msg}"
              }
              try runJob s ctx job
              finally s.readerActive.modify (fun n => n - 1)
        else
          let ctx : Context := {
            withWriter := service.withConnection
            withReader := service.withConnection
            deadline := now + job.budgetPerSliceMs
            log := fun msg => IO.println s!"job {job.name}: {msg}"
          }
          runJob s ctx job
        IO.sleep 1

def walCheckpoint : Job where
  name := "wal-checkpoint"
  everyMs := 300000
  run := fun ctx => do
    match ← ctx.withWriter fun conn => conn.raw.exec "PRAGMA wal_checkpoint(TRUNCATE)" with
    | .ok _ => return .done
    | .error _ => return .failed "checkpoint"

def pruneSessions : Job where
  name := "prune-sessions"
  everyMs := 3600000
  run := fun ctx => do
    match ← ctx.withWriter fun conn =>
      conn.raw.exec "DELETE FROM sessions WHERE expiresAt < CAST(strftime('%s','now') AS INTEGER)" with
    | .ok _ => return .done
    | .error _ => return .failed "prune"

/-- Daily backup on the reader lane. Exempt from `budgetPerSliceMs` because
    `VACUUM INTO` cannot be sliced. With `readers := 0` this blocks writes. -/
def backup (dir : System.FilePath) (retainDays : Nat) : Job where
  name := "backup"
  everyMs := 86400000
  initialDelayMs := 0
  lane := .reader
  budgetPerSliceMs := 0
  run := fun ctx => do
    let now ← IO.monoMsNow
    IO.FS.createDirAll dir
    let dest := dir / s!"backup-{now}.sqlite"
    match ← ctx.withReader fun conn => LeanDb.backupTo conn dest with
    | .error _ =>
      try IO.FS.removeFile dest catch _ => pure ()
      return .failed "backup"
    | .ok _ =>
      let cutoff := now - retainDays * 86400000
      for entry in ← dir.readDir do
        let name := entry.fileName
        if name.startsWith "backup-" && name.endsWith ".sqlite" then
          if let some stamp := ((name.drop "backup-".length).dropEnd ".sqlite".length).toNat? then
            if stamp < cutoff then
              try IO.FS.removeFile entry.path catch _ => pure ()
      return .done

end LeanAppNative.Jobs
