import LeanApp
import LeanDb.Sha256
import Std.Time

/-! One JSON line per request (`v:1`). Never bodies, tokens, usernames or SQL: the principal
appears only as a truncated SHA-256 of the actor id, and error messages only in verbose mode. -/
namespace LeanAppNative.Log
open LeanApp Contract

inductive Sink where
  | none
  | stderr
  | file (path : String)
  /-- For checks: lines are appended to the array instead of being written. -/
  | buffer (lines : IO.Ref (Array String))
  deriving Inhabited

structure Config where
  sink : Sink := .none
  /-- Include caught exception messages (`LEANAPP_LOG_ERRORS=verbose`); never in production. -/
  verboseErrors : Bool := false
  deriving Inhabited

initialize configRef : IO.Ref Config ← IO.mkRef {}

def configure (config : Config) : IO Unit := configRef.set config

/-- Disjoint phases in milliseconds, so `auth + queueWait + db + handler ≤ total` always holds.
`db` is connection-held time outside authentication and the handler (factory assembly and
registry revalidation); the writer was held for `auth + db + handler`. -/
structure Timings where
  auth : Nat := 0
  queueWait : Nat := 0
  db : Nat := 0
  handler : Nat := 0
  deriving Repr, BEq

inductive Outcome where
  | success | domainError | decode | protocol | unauthenticated | forbidden | incompatible | failed | unavailable
  deriving Repr, BEq, DecidableEq, Hashable

def Outcome.name : Outcome → String
  | .success => "success" | .domainError => "domainError" | .decode => "decode" | .protocol => "protocol"
  | .unauthenticated => "unauthenticated" | .forbidden => "forbidden" | .incompatible => "incompatible"
  | .failed => "failed" | .unavailable => "unavailable"

def Outcome.all : List Outcome := [.success, .domainError, .decode, .protocol, .unauthenticated,
  .forbidden, .incompatible, .failed, .unavailable]

/-- The outcome implied by a status when the dispatcher did not record a finer one. -/
def Outcome.ofStatus (status : Nat) : Outcome :=
  if status < 300 then .success
  else if status == 401 then .unauthenticated
  else if status == 403 then .forbidden
  else if status == 409 then .incompatible
  else if status == 503 then .unavailable
  else if status ≥ 500 then .failed
  else .protocol

def Outcome.ofResult : CallResult WireResponse Empty → Outcome
  | .ok (.success _) => .success
  | .ok (.domainError _) => .domainError
  | .error .unauthenticated => .unauthenticated
  | .error .forbidden => .forbidden
  | .error (.decode _) => .decode
  | .error (.incompatible _) => .incompatible
  | .error (.protocol _) => .protocol
  | .error _ => .failed

/-- A caught exception: its `IO.Error` class and a stable adapter code; the message is optional. -/
structure ErrorInfo where
  «class» : String
  code : String
  message : Option String := none
  deriving Repr

def errorClass : IO.Error → String
  | .userError _ => "userError" | .otherError .. => "otherError" | .resourceExhausted .. => "resourceExhausted"
  | .resourceBusy .. => "resourceBusy" | .resourceVanished .. => "resourceVanished" | .timeExpired .. => "timeExpired"
  | .interrupted .. => "interrupted" | .protocolError .. => "protocolError" | .noFileOrDirectory .. => "noFileOrDirectory"
  | .permissionDenied .. => "permissionDenied" | .invalidArgument .. => "invalidArgument" | .unexpectedEof => "unexpectedEof"
  | _ => "ioError"

def errorInfo (code : String) (e : IO.Error) : IO ErrorInfo := do
  return ⟨errorClass e, code, if (← configRef.get).verboseErrors then some (toString e) else none⟩

/-- Facts recorded while a request is dispatched; the HTTP handler turns them into one line. -/
structure Trace where
  requestId : String := ""
  operation : Option OperationId := none
  outcome : Option Outcome := none
  principalHash : Option String := none
  timings : Timings := {}
  error : Option ErrorInfo := none

abbrev TraceRef := Option (IO.Ref Trace)

def TraceRef.update (trace : TraceRef) (f : Trace → Trace) : IO Unit :=
  match trace with | some ref => ref.modify f | none => pure ()

/-- Add a completed phase; phases are accumulated because a dispatcher may enter twice. -/
def TraceRef.phase (trace : TraceRef) (f : Timings → Nat → Timings) (started : Nat) : IO Unit := do
  let ended ← IO.monoMsNow
  trace.update fun t => { t with timings := f t.timings (ended - started) }

/-- Carry a validated request id into the context without exposing its private constructor. -/
def withRequestId (context : RequestContext) (requestId : String) : RequestContext :=
  match context.principal with
  | some principal => TrustedNative.issueContext principal requestId
  | none => .anonymous requestId

/-- `sha256(actor)` truncated to 16 hex characters: correlates a principal's requests without
naming it. -/
def principalHash (actor : String) : String := ((LeanDb.Sha256.string actor).take 16).toString

def TraceRef.principal (trace : TraceRef) (context : RequestContext) : IO Unit :=
  trace.update fun t => { t with principalHash := context.principal.map (principalHash ·.actor) }

/-- A client `X-Request-Id` is honoured when it is at most 64 URL-safe characters. -/
def validRequestId (value : String) : Bool :=
  !value.isEmpty && value.length ≤ 64 &&
    value.toList.all fun c => c.toNat < 128 && (c.isAlphanum || c == '-' || c == '_' || c == '.' || c == '~')

initialize counter : IO.Ref Nat ← IO.mkRef 0

/-- The header value when valid, else a fresh process-unique id. -/
def requestId (supplied : Option String) : IO String := do
  if let some value := supplied then
    if validRequestId value then return value
  let n ← counter.modifyGet fun n => (n + 1, n + 1)
  let ms := (← Std.Time.Timestamp.now).toMillisecondsSinceUnixEpoch.toInt.toNat
  return s!"r{ms}-{n}"

def OperationId.toLogJson (id : OperationId) : Lean.Json :=
  .mkObj [("namespace", .str id.namespaceName), ("name", .str id.name), ("version", .str id.version)]

/-- The request line. `bodyBytes`/`replyBytes` are sizes only. -/
structure Entry where
  ts : Nat
  requestId : String
  method : String
  path : String
  operation : Option OperationId
  status : Nat
  outcome : Outcome
  principalHash : Option String
  durations : Timings
  total : Nat
  bodyBytes : Nat
  replyBytes : Nat
  error : Option ErrorInfo

def Entry.toJson (e : Entry) : Lean.Json :=
  let opt := fun (value : Option String) => (value.map Lean.Json.str).getD .null
  .mkObj <| [("v", Lean.toJson 1), ("ts", Lean.toJson e.ts), ("requestId", .str e.requestId),
    ("method", .str e.method), ("path", .str e.path),
    ("operation", (e.operation.map OperationId.toLogJson).getD .null),
    ("status", Lean.toJson e.status), ("outcome", .str e.outcome.name),
    ("principalHash", opt e.principalHash),
    ("durations", .mkObj [("total", Lean.toJson e.total), ("auth", Lean.toJson e.durations.auth),
      ("queueWait", Lean.toJson e.durations.queueWait), ("db", Lean.toJson e.durations.db),
      ("handler", Lean.toJson e.durations.handler)]),
    ("bodyBytes", Lean.toJson e.bodyBytes), ("replyBytes", Lean.toJson e.replyBytes)] ++
    (match e.error with
      | some info => [("error", .mkObj ([("class", .str info.class), ("code", .str info.code)] ++
          (match info.message with | some m => [("message", .str m)] | none => [])))]
      | none => [])

def write (line : String) : IO Unit := do
  match (← configRef.get).sink with
  | .none => pure ()
  | .stderr => IO.eprintln line
  | .file path =>
    try
      let handle ← IO.FS.Handle.mk path .append
      handle.putStrLn line
      handle.flush
    catch _ => pure ()
  | .buffer lines => lines.modify (·.push line)

def now : IO Nat := return (← Std.Time.Timestamp.now).toMillisecondsSinceUnixEpoch.toInt.toNat

/-- Build the line from a finished trace and emit it. Returns the entry for the metrics registry. -/
def request (trace : Trace) (method path : String) (status : Nat) (started : Nat)
    (bodyBytes replyBytes : Nat) : IO Entry := do
  let ended ← IO.monoMsNow
  let entry : Entry := {
    ts := ← now, requestId := trace.requestId, method, path, operation := trace.operation, status
    outcome := trace.outcome.getD (Outcome.ofStatus status), principalHash := trace.principalHash
    durations := trace.timings, total := ended - started, bodyBytes, replyBytes, error := trace.error }
  write entry.toJson.compress
  return entry

/-- A caught exception outside any request trace (dispatch-only hosts). -/
def exception (component code : String) (e : IO.Error) : IO Unit := do
  let info ← errorInfo code e
  write (Lean.Json.mkObj ([("v", Lean.toJson 1), ("ts", Lean.toJson (← now)), ("event", .str "error"),
    ("component", .str component), ("class", .str info.class), ("code", .str info.code)] ++
    (match info.message with | some m => [("message", .str m)] | none => [])) ).compress

/-- Record a caught exception on the request trace, or emit it as an event when there is none. -/
def TraceRef.failure (trace : TraceRef) (component code : String) (e : IO.Error) : IO Unit := do
  match trace with
  | some ref =>
    let info ← errorInfo code e
    ref.modify fun t => { t with outcome := some .failed, error := some info }
  | none => exception component code e

end LeanAppNative.Log
