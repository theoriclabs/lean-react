import LeanDb.Runtime
import Std.Data.HashMap

namespace LeanAppNative.Jobs

inductive Outcome where
  | done
  | continue (state : Lean.Json)
  | failed (code : String)
  deriving BEq

structure Context where
  withWriter : {α : Type} → (LeanDb.Conn → IO α) → IO (Except LeanDb.Runtime.AdmissionError α)
  deadline : Nat
  log : String → IO Unit

structure Job where
  name : String
  everyMs : Nat
  initialDelayMs : Nat := everyMs
  run : Context → IO Outcome
  budgetPerSliceMs : Nat := 50
  singleFlight : Bool := true

structure Scheduler where
  private stopping : IO.Ref Bool
  private last : IO.Ref (Std.HashMap String Nat)
  runs : IO.Ref Nat

def Scheduler.new : IO Scheduler :=
  return ⟨← IO.mkRef false, ← IO.mkRef {}, ← IO.mkRef 0⟩

def Scheduler.stop (s : Scheduler) : IO Unit := s.stopping.set true

/-- Cooperative loop: one job at a time, yields between slices, honours `stop`. -/
def Scheduler.start (s : Scheduler) (service : LeanDb.Runtime.Service) (jobs : List Job) : IO Unit := do
  let started ← IO.monoMsNow
  for job in jobs do
    s.last.modify (·.insert job.name (started + job.initialDelayMs))
  discard <| IO.asTask (prio := .dedicated) do
    repeat
      if ← s.stopping.get then break
      let now ← IO.monoMsNow
      let last ← s.last.get
      match jobs.find? (fun j => last.getD j.name now ≤ now) with
      | none => IO.sleep 20
      | some job =>
        let ctx : Context := {
          withWriter := service.withConnection
          deadline := now + job.budgetPerSliceMs
          log := fun msg => IO.println s!"job {job.name}: {msg}"
        }
        try
          match ← job.run ctx with
          | .done | .failed _ =>
            s.last.modify (·.insert job.name ((← IO.monoMsNow) + job.everyMs))
          | .continue _ =>
            s.last.modify (·.insert job.name (← IO.monoMsNow))
          s.runs.modify (· + 1)
        catch _ =>
          s.last.modify (·.insert job.name ((← IO.monoMsNow) + job.everyMs))
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

def backup (dir : System.FilePath) (retainDays : Nat) : Job where
  name := "backup"
  everyMs := 86400000
  run := fun ctx => do
    let now ← IO.monoMsNow
    IO.FS.createDirAll dir
    let dest := dir / s!"backup-{now}.sqlite"
    match ← ctx.withWriter fun conn => LeanDb.backupTo conn dest with
    | .error _ => return .failed "backup"
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
