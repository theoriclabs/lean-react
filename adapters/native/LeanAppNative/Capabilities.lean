import LeanApp.Application
import LeanAppNative.Runtime
import LeanAppNative.Server

namespace LeanAppNative
open LeanApp Ontology

/-- Connection-per-call lanes (LA-07). A policy or handler never sees a bare `Conn` except
inside one of these closures, so no application can retain a connection past the call.

The lanes are stored erased (`Unit`-returning callbacks) so that `Capabilities`, and every host
that holds a factory over it, stays in `Type`; `withWriter`/`withReader` restore the result type. -/
structure Capabilities where
  private writerErased : (LeanDb.Conn → IO Unit) → IO (Option Runtime.AdmissionError)
  private readerErased : (LeanDb.Conn → IO Unit) → IO (Option Runtime.AdmissionError)

private def erase (lane : (LeanDb.Conn → IO Unit) → IO (Except Runtime.AdmissionError Unit))
    (f : LeanDb.Conn → IO Unit) : IO (Option Runtime.AdmissionError) := do
  match ← lane f with
  | .ok () => return none
  | .error e => return some e

private def restore (lane : (LeanDb.Conn → IO Unit) → IO (Option Runtime.AdmissionError))
    (f : LeanDb.Conn → IO α) : IO (Except Runtime.AdmissionError α) := do
  let box ← IO.mkRef (none : Option α)
  match ← lane (fun conn => do box.set (some (← f conn))) with
  | some e => return .error e
  | none =>
    match ← box.get with
    | some value => return .ok value
    | none => return .error (.host (IO.userError "lane completed without a result"))

/-- Run `f` on the writer lane. -/
def Capabilities.withWriter (caps : Capabilities) (f : LeanDb.Conn → IO α) :
    IO (Except Runtime.AdmissionError α) := restore caps.writerErased f

/-- Run `f` on the reader lane (the writer when the pool is empty or after this request wrote). -/
def Capabilities.withReader (caps : Capabilities) (f : LeanDb.Conn → IO α) :
    IO (Except Runtime.AdmissionError α) := restore caps.readerErased f

/-- How a host assembles the application for a request. -/
inductive Factory where
  /-- Handlers are rebuilt from the writer connection and the whole request runs under it:
      session resolution, assembly, policy and handler are serialized end to end. -/
  | serialized (assemble : LeanDb.Conn → Validation (Application IO))
  /-- Handlers take lanes (LA-07): assembly, policy and handler run outside the writer lock and
      acquire a pooled reader or the writer per `read`/`write` call. -/
  | lanes (assemble : Capabilities → Validation (Application IO))

/-- Both lanes are the connection the caller already holds: the serialized request path. -/
def Capabilities.held (conn : LeanDb.Conn) : Capabilities where
  writerErased f := do f conn; return none
  readerErased f := do f conn; return none

/-- Lanes straight on the service, without request-local tracking (jobs, trusted callers). -/
def Capabilities.ofService (service : Runtime.Service) : Capabilities where
  writerErased := erase service.withConnection
  readerErased := erase service.withReader

/-- Run `f` on the reader lane. An admission refusal becomes `unavailableError`, which
`Server.dispatch` answers with `503 application.unavailable`; a host exception is rethrown. -/
def Capabilities.reader (caps : Capabilities) (f : LeanDb.Conn → IO α) : IO α := do
  match ← caps.withReader f with
  | .ok value => pure value
  | .error (.host e) => throw e
  | .error _ => throw unavailableError

/-- `Capabilities.reader` for the writer lane. -/
def Capabilities.writer (caps : Capabilities) (f : LeanDb.Conn → IO α) : IO α := do
  match ← caps.withWriter f with
  | .ok value => pure value
  | .error (.host e) => throw e
  | .error _ => throw unavailableError

/-- Request-local lane state: whether this request has written yet, and the connection time its
lanes accumulated, so the request log keeps `queueWait`, `db` and `handler` disjoint. -/
structure LaneClock where
  wrote : IO.Ref Bool
  /-- Milliseconds spent waiting for admission on either lane. -/
  waited : IO.Ref Nat
  /-- Milliseconds a connection was held on either lane. -/
  held : IO.Ref Nat

def LaneClock.new : IO LaneClock :=
  return ⟨← IO.mkRef false, ← IO.mkRef 0, ← IO.mkRef 0⟩

private def timed (clock : LaneClock)
    (lane : (LeanDb.Conn → IO Unit) → IO (Except Runtime.AdmissionError Unit))
    (f : LeanDb.Conn → IO Unit) : IO (Option Runtime.AdmissionError) := do
  let queued ← IO.monoMsNow
  erase lane fun conn => do
    let entered ← IO.monoMsNow
    clock.waited.modify (· + (entered - queued))
    try f conn
    finally clock.held.modify (· + ((← IO.monoMsNow) - entered))

/-- Request-scoped lanes: a read before this request's first write may use a pooled reader;
after the first write every read goes to the writer, so a handler observes its own state.
Each `withWriter` holds the writer for that one call only; the application's explicit
`transaction` lives inside it. -/
def Capabilities.request (service : Runtime.Service) (clock : LaneClock) : Capabilities where
  writerErased f := do
    clock.wrote.set true
    timed clock service.withConnection f
  readerErased f := do
    if ← clock.wrote.get then timed clock service.withConnection f
    else timed clock service.withReader f

/-- Move lane waits and held time out of `handler`, so `auth + queueWait + db + handler ≤ total`
keeps holding when lanes are acquired inside the handler. -/
def LaneClock.settle (clock : LaneClock) (trace : Log.TraceRef) : IO Unit := do
  let waited ← clock.waited.get
  let held ← clock.held.get
  trace.update fun t => { t with timings := { t.timings with
    handler := t.timings.handler - (waited + held)
    queueWait := t.timings.queueWait + waited
    db := t.timings.db + held } }

end LeanAppNative
