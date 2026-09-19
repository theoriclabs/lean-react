import LeanDb.Runtime
import Std.Sync.Mutex

/-! The runtime the native adapters consume. LeanDB 0.4.0's `Runtime.Service` (LDB-01) owns the
one writer connection and its lifecycle; this module adds what the hosts, jobs and lifecycle rely
on: a bounded writer queue (`overloaded`), `drain` with pending-work accounting, typed
`AdmissionError`s, readiness that never waits on the database, and an exclusive read-only
connection pool (LDB-09) for query lanes (LA-07) and reader-lane jobs (LA-16). -/
namespace LeanAppNative.Runtime
open LeanDb

/-- Admission failures stay typed for native application integrations. Callback results
(including their own `Except` errors) are not erased; host exceptions keep an `IO.Error`. -/
inductive AdmissionError where
  | shuttingDown
  | draining
  | closed
  | notVerified (error : DbError)
  | inspectionOnly
  | overloaded
  | drainRequired
  | host (error : IO.Error)

def AdmissionError.message : AdmissionError → String
  | .shuttingDown => "runtime is shutting down"
  | .draining => "runtime is draining"
  | .closed => "runtime is closed"
  | .notVerified e => s!"instance verification failed: {e.message}"
  | .inspectionOnly => "inspection sessions cannot admit application callbacks"
  | .overloaded => "runtime request queue is full"
  | .drainRequired => "drain the runtime and wait for pending work before changing the instance"
  | .host e => s!"runtime operation failed: {e}"

instance : ToString AdmissionError := ⟨AdmissionError.message⟩

/-- Writer-queue and reader-pool accounting, sampled by metrics and the lifecycle. -/
structure State where
  accepting : Bool := true
  stopping : Bool := false
  closed : Bool := false
  changing : Bool := false
  /-- Writer callbacks running / waiting for the writer. -/
  active : Nat := 0
  queued : Nat := 0
  completed : Nat := 0
  readersActive : Nat := 0
  readersCompleted : Nat := 0
  deriving Repr

structure Config where
  /-- Pooled read-only connections (`LEANAPP_DB_READERS`). `0` sends every read to the writer. -/
  readers : Nat := 0
  readerBusyTimeoutMs : Nat := 5000
  /-- Writer callbacks admitted (active plus queued) before `overloaded`. -/
  maxPending : Nat := 128
  deriving Repr

structure Service where
  private mk ::
  private inner : LeanDb.Runtime.Service
  base : Base
  inst : Instance
  config : Config
  private state : Std.Mutex State
  private idle : Std.Condvar
  private gateRef : IO.Ref (Option DbError)
  private pool : IO.Ref (Array (Std.Mutex Conn))
  private next : IO.Ref Nat

/-- The verification gate as LeanDB reports it; a cheap probe on the writer. -/
private def probeGate (inner : LeanDb.Runtime.Service) : IO (Option DbError) := do
  match ← inner.withConnection fun _ => pure () with
  | .error (.gated e) => return some e
  | _ => return none

private def openPool (base : Base) (inst : Instance) (config : Config) : IO (Array (Std.Mutex Conn)) := do
  let mut pool := #[]
  for _ in [0:config.readers] do
    match ← openDbRaw inst.path base.log
        { base.openConfig with busyTimeoutMs := config.readerBusyTimeoutMs } (readOnly := true) with
    | .ok conn => pool := pool.push (← Std.Mutex.new conn)
    | .error e => throw (IO.userError e.message)
  return pool

/-- Open the instance (creating the file when absent), verify the base's schema and open
`config.readers` read-only connections. Failures are returned, never thrown. An `.inspect`
session is read-only and never ready. -/
def Service.new (base : Base) (inst : Instance) (mode : LeanDb.Runtime.SessionMode := .serve)
    (config : Config := {}) (verify : Bool := true) : IO (Except DbError Service) := do
  try
    let inner ← LeanDb.Runtime.Service.new base inst mode verify
    let gate ← probeGate inner
    let pool ← openPool base inst config
    return .ok ⟨inner, base, inst, config, ← Std.Mutex.new {}, ← Std.Condvar.new,
      ← IO.mkRef gate, ← IO.mkRef pool, ← IO.mkRef 0⟩
  catch e => return .error (.sqlite (toString e))

def Service.snapshot (s : Service) : IO State := s.state.atomically fun ref => ref.get

def Service.readOnly (s : Service) : Bool := s.inner.session.readOnly

/-- The schema gate: `some` while the instance fails verification and verbs are refused. -/
def Service.gate (s : Service) : IO (Option DbError) := s.gateRef.get

/-- Pooled read-only connections available to `withReader`. -/
def Service.readers (s : Service) : Nat := s.config.readers

/-- Admitting application work? Takes only the small state lock, never the database. -/
def Service.ready (s : Service) : IO Bool := do
  let st ← s.snapshot
  return st.accepting && !st.stopping && !st.changing && !st.closed && !s.readOnly &&
    (← s.gateRef.get).isNone

/-- No identity, path, fingerprint or database errors in an unauthenticated probe. -/
def Service.readiness (s : Service) : IO Lean.Json := do
  let ready ← s.ready
  return Lean.Json.mkObj [("ok", .bool ready), ("ready", .bool ready)]

private def Service.admitWriter (s : Service) : IO (Option AdmissionError) :=
  s.state.atomically fun ref => do
    let st ← ref.get
    if st.closed then return some AdmissionError.closed
    if st.stopping then return some AdmissionError.shuttingDown
    if !st.accepting || st.changing then return some AdmissionError.draining
    if s.readOnly then return some AdmissionError.inspectionOnly
    if let some e ← s.gateRef.get then return some (AdmissionError.notVerified e)
    if st.active + st.queued ≥ s.config.maxPending then return some AdmissionError.overloaded
    ref.set { st with queued := st.queued + 1 }
    return none

private def mapRuntimeError : LeanDb.Runtime.RuntimeError → AdmissionError
  | .host m => .host (IO.userError m)
  | .notReady .closed => .closed
  | .notReady _ => .draining
  | .reentrant => .host (IO.userError "withConnection called reentrantly from its own callback")
  | .gated e => .notVerified e

/-- Admit public application data work and run `callback` on the writer, serialized. `α` may
itself be an `Except ε β`, preserving the application's domain result independently of admission.

The callback is synchronous: do not retain the connection, return a task that uses it later,
or re-enter this service while holding its lock (LeanDB refuses that reentrantly). This does
not begin a transaction; use `DbM.run conn (transaction ...)` when required. -/
def Service.withConnection (s : Service) (callback : Conn → IO α) : IO (Except AdmissionError α) := do
  if let some e ← s.admitWriter then return .error e
  let entered ← IO.mkRef false
  try
    let result ← s.inner.withConnection fun conn => do
      entered.set true
      s.state.atomically <| modify fun st => { st with queued := st.queued - 1, active := st.active + 1 }
      callback conn
    return result.mapError mapRuntimeError
  finally
    s.state.atomically fun ref => do
      let st ← ref.get
      if ← entered.get then ref.set { st with active := st.active - 1, completed := st.completed + 1 }
      else ref.set { st with queued := st.queued - 1 }
    s.idle.notifyAll

/-- Host exceptions from a reader callback become `AdmissionError.host`, as on the writer. -/
private def guarded (act : IO α) : IO (Except AdmissionError α) := do
  try return .ok (← act)
  catch e => return .error (.host e)

private def Service.admitReader (s : Service) : IO (Option AdmissionError) :=
  s.state.atomically fun ref => do
    let st ← ref.get
    if st.closed then return some AdmissionError.closed
    if st.stopping then return some AdmissionError.shuttingDown
    if !st.accepting || st.changing then return some AdmissionError.draining
    if s.readOnly then return some AdmissionError.inspectionOnly
    if let some e ← s.gateRef.get then return some (AdmissionError.notVerified e)
    ref.set { st with readersActive := st.readersActive + 1 }
    return none

/-- Admit and run `callback` on a pooled read-only connection (LDB-09), held exclusively for the
call so two readers never interleave statements on one handle. Never queues on the writer; a
write verb on this connection fails with `DbError.readOnly`. With `readers := 0` this is the
writer. -/
def Service.withReader (s : Service) (callback : Conn → IO α) : IO (Except AdmissionError α) := do
  let pool ← s.pool.get
  if pool.isEmpty then return ← s.withConnection callback
  if let some e ← s.admitReader then return .error e
  try
    let i ← s.next.modifyGet fun n => (n % pool.size, n + 1)
    let some reader := pool[i]? | return .error (.host (IO.userError "reader pool index"))
    reader.atomically fun ref => do
      let conn ← ref.get
      guarded (callback conn)
  finally
    s.state.atomically <| modify fun st =>
      { st with readersActive := st.readersActive - 1, readersCompleted := st.readersCompleted + 1 }
    s.idle.notifyAll

/-- A consistent copy of the instance at `dest` (`VACUUM INTO`) on a dedicated connection opened
for the call, so the writer keeps committing meanwhile (LDB-13's snapshot runs under the
writer lock; a pooled read-only connection cannot run `VACUUM INTO`). Accounted as reader
work: `drain`/`restore` wait for it and refuse a new one. -/
def Service.snapshotTo (s : Service) (dest : System.FilePath) : IO (Except AdmissionError Unit) := do
  if let some e ← s.admitReader then return .error e
  try
    match ← openDbRaw s.inst.path s.base.log s.base.openConfig with
    | .error e => return .error (.notVerified e)
    | .ok conn => guarded (backupTo conn dest)
  finally
    s.state.atomically <| modify fun st =>
      { st with readersActive := st.readersActive - 1, readersCompleted := st.readersCompleted + 1 }
    s.idle.notifyAll

/-- Stop admitting work. Already admitted work finishes; `stopping` is terminal for admission. -/
def Service.drain (s : Service) (stopping : Bool := false) : IO Unit :=
  s.state.atomically <| modify fun st => { st with accepting := false, stopping := st.stopping || stopping }

/-- Admit work again after `drain`. Refused while stopping, closed, gated or with pending work. -/
def Service.resume (s : Service) : IO Bool := do
  if (← s.gateRef.get).isSome then return false
  s.state.atomically fun ref => do
    let st ← ref.get
    if st.closed || st.stopping || st.changing || st.active != 0 || st.queued != 0 then return false
    ref.set { st with accepting := true }
    return true

private def Service.waitIdle (s : Service) : IO Unit :=
  s.state.atomicallyOnce s.idle
    (fun ref => do
      let st ← ref.get
      return st.active == 0 && st.queued == 0 && st.readersActive == 0)
    (pure ())

/-- Stop admission, wait for admitted work (including queued work that has not yet acquired
the writer), checkpoint the WAL and close every connection. Idempotent. -/
def Service.close (s : Service) : IO Unit := do
  s.drain true
  s.waitIdle
  let already ← s.state.atomically fun ref => do
    let st ← ref.get
    ref.set { st with closed := true }
    return st.closed
  if already then return
  discard <| s.inner.withConnection fun conn => conn.raw.exec "PRAGMA wal_checkpoint(TRUNCATE)"
  s.inner.close
  s.pool.set #[]

/-- Replace the instance file with `src` (LeanDB validates the source before touching the
instance) and reopen the writer and every pooled reader. Requires a drained, idle service;
call `resume` afterwards. -/
def Service.restore (s : Service) (src : System.FilePath) : IO (Except AdmissionError Unit) := do
  let admitted ← s.state.atomically fun ref => do
    let st ← ref.get
    if st.closed then return some AdmissionError.closed
    if st.accepting || st.changing || st.active != 0 || st.queued != 0 || st.readersActive != 0 then
      return some AdmissionError.drainRequired
    ref.set { st with changing := true }
    return none
  if let some e := admitted then return .error e
  try
    let result ← s.inner.restore src
    s.gateRef.set (← probeGate s.inner)
    match result with
    | .error e => return .error (mapRuntimeError e)
    | .ok () =>
      s.pool.set (← openPool s.base s.inst s.config)
      return .ok ()
  catch e => return .error (.host e)
  finally
    s.state.atomically <| modify fun st => { st with changing := false }

end LeanAppNative.Runtime
