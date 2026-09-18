import LeanAppNative.Log
import Std.Data.HashMap

/-! In-memory counters, reset on restart, rendered in Prometheus text format for a loopback-only
`GET /internal/metrics`. Hosts add live gauges (writer queue, session cache) at scrape time. -/
namespace LeanAppNative.Metrics
open LeanApp Contract

/-- Cumulative `le` buckets in milliseconds. -/
def bounds : Array Nat := #[1, 2, 5, 10, 25, 50, 100, 250, 500, 1000, 2500, 5000]

structure Histogram where
  buckets : Array Nat := Array.replicate bounds.size 0
  sum : Nat := 0
  count : Nat := 0
  deriving Inhabited

def Histogram.observe (h : Histogram) (value : Nat) : Histogram :=
  { buckets := (Array.range bounds.size).map fun i => h.buckets[i]! + (if value ≤ bounds[i]! then 1 else 0)
    sum := h.sum + value, count := h.count + 1 }

structure Registry where
  requests : Std.HashMap (String × String) Nat := {}
  latencyTotal : Histogram := {}
  latencyDb : Histogram := {}
  queueWait : Histogram := {}
  authThrottles : Nat := 0
  rateLimited : Nat := 0
  bodyBytes : Nat := 0
  replyBytes : Nat := 0
  /-- Hook point for later subsystems (hot state sizes, jobs, channels): `setGauge name value`. -/
  gauges : Std.HashMap String Nat := {}
  deriving Inhabited

initialize registry : IO.Ref Registry ← IO.mkRef {}

def operationLabel : Option OperationId → String
  | some id => s!"{id.namespaceName}/{id.name}/{id.version}"
  | none => "-"

/-- Record one finished request. The `db` histogram is connection-held time outside authentication
(`db + handler`); authentication time stays in the log line because for credential routes it is
KDF work outside the writer lock. -/
def observe (entry : Log.Entry) : IO Unit :=
  registry.modify fun r =>
    let key := (operationLabel entry.operation, entry.outcome.name)
    { r with
      requests := r.requests.insert key (r.requests.getD key 0 + 1)
      latencyTotal := r.latencyTotal.observe entry.total
      latencyDb := r.latencyDb.observe (entry.durations.db + entry.durations.handler)
      queueWait := r.queueWait.observe entry.durations.queueWait
      bodyBytes := r.bodyBytes + entry.bodyBytes, replyBytes := r.replyBytes + entry.replyBytes }

def countAuthThrottle : IO Unit := registry.modify fun r => { r with authThrottles := r.authThrottles + 1 }
def countRateLimited : IO Unit := registry.modify fun r => { r with rateLimited := r.rateLimited + 1 }

/-- Later gauges (LA-08 state, LA-09 jobs, channels) register here by name. -/
def setGauge (name : String) (value : Nat) : IO Unit :=
  registry.modify fun r => { r with gauges := r.gauges.insert name value }

def reset : IO Unit := registry.set {}

private def escape (value : String) : String :=
  value.replace "\\" "\\\\" |>.replace "\"" "\\\"" |>.replace "\n" "\\n"

private def histogram (name : String) (h : Histogram) : List String :=
  [s!"# TYPE {name} histogram"] ++
  (List.range bounds.size).map (fun i => s!"{name}_bucket\{le=\"{bounds[i]!}\"} {h.buckets[i]!}") ++
  [s!"{name}_bucket\{le=\"+Inf\"} {h.count}", s!"{name}_sum {h.sum}", s!"{name}_count {h.count}"]

/-- Prometheus text exposition. `live` gauges are sampled by the host at scrape time, e.g.
`leanapp_writer_queue_depth` and the session cache counters. -/
def render (live : List (String × Nat) := []) : IO String := do
  let r ← registry.get
  let requests := r.requests.toList.map fun ((operation, outcome), n) =>
    s!"leanapp_requests_total\{operation=\"{escape operation}\",outcome=\"{outcome}\"} {n}"
  let lines := ["# TYPE leanapp_requests_total counter"] ++ (requests.toArray.qsort (· < ·)).toList ++
    histogram "leanapp_request_duration_ms" r.latencyTotal ++
    histogram "leanapp_request_db_ms" r.latencyDb ++
    histogram "leanapp_request_queue_wait_ms" r.queueWait ++
    ["# TYPE leanapp_auth_throttles_total counter", s!"leanapp_auth_throttles_total {r.authThrottles}",
     "# TYPE leanapp_rate_limited_total counter", s!"leanapp_rate_limited_total {r.rateLimited}",
     "# TYPE leanapp_request_body_bytes_total counter", s!"leanapp_request_body_bytes_total {r.bodyBytes}",
     "# TYPE leanapp_reply_bytes_total counter", s!"leanapp_reply_bytes_total {r.replyBytes}"] ++
    (live ++ (r.gauges.toList.toArray.qsort (·.1 < ·.1)).toList).flatMap fun (name, value) =>
      [s!"# TYPE {name} gauge", s!"{name} {value}"]
  return String.intercalate "\n" lines ++ "\n"

end LeanAppNative.Metrics
