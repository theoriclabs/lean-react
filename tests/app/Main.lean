import LeanApp
import AclFixture

open LeanApp Contract Ontology

instance [BEq α] [BEq ε] : BEq (Except ε α) where
  beq a b := match a, b with
    | .ok x, .ok y => x == y
    | .error x, .error y => x == y
    | _, _ => false

inductive ReadOp : Type → Type where
  | value : ReadOp Nat
inductive WriteOp : Type → Type where
  | set (value : Nat) : WriteOp Unit

structure Memory where
  value : Nat := 7
  calls : Nat := 0
  policies : Nat := 0
  deriving Repr

abbrev Fixture := StateM Memory

def reads : ReadCapability Fixture ReadOp where
  read op := match op with
    | .value => return (← get).value

def commands : CommandCapability Fixture ReadOp WriteOp where
  toRead := reads
  write op := match op with
    | .set n => modify fun s => { s with value := n }

/-- Deliberately local fixture policy, not production authentication. -/
def localPolicy (op : Operation k Nat Nat String) : Policy Fixture ReadOp op :=
  fun ctx _ input => do
    modify fun s => { s with policies := s.policies + 1 }
    match ctx.principal with
    | none => pure (.error .unauthenticated)
    | some p => pure <| if p.tenant == "fixture" && input != 99 then .ok () else .error .forbidden

def queryBinding (op : Operation .query Nat Nat String) : Binding Fixture ReadOp WriteOp op where
  policy := localPolicy op
  handler _ cap input := do
    modify fun s => { s with calls := s.calls + 1 }
    if input == 42 then return .error "missing"
    return .ok ((← cap.read .value) + input)
  http := { path := "/value" }
  metadata := { title := "Read value", description := "Approved projection" }

def commandBinding (op : Operation .command Nat Nat String) : Binding Fixture ReadOp WriteOp op where
  policy := localPolicy op
  handler _ cap input := do
    modify fun s => { s with calls := s.calls + 1 }
    cap.write (.set input)
    return .ok (← cap.toRead.read .value)
  http := { path := "/set" }

def require (result : Validation α) : IO α :=
  match result with
  | .ok a => pure a
  | .error e => throw (IO.userError (reprStr e))

def check (label : String) (ok : Bool) : IO Unit := do
  unless ok do throw (IO.userError s!"FAIL: {label}")
  IO.println s!"PASS: {label}"

def reject (label code : String) (result : Validation α) : IO Unit :=
  check label (match result with | .error e => e.first.code == code | .ok _ => false)

def main : IO Unit := do
  let query ← require (Operation.canonical .query (Input := Nat) (Output := Nat)
    (Error := String) ⟨"fixture", "get", "1"⟩)
  let command ← require (Operation.canonical .command (Input := Nat) (Output := Nat)
    (Error := String) ⟨"fixture", "set", "1"⟩)
  let v2 ← require (Operation.canonical .query (Input := Nat) (Output := Nat)
    (Error := String) ⟨"fixture", "get", "2"⟩)
  let privateOp ← require (Operation.canonical .query (Input := Nat) (Output := Nat)
    (Error := String) ⟨"fixture", "private", "1"⟩)
  let _privateBinding := queryBinding privateOp
  let exported := (queryBinding query).approve (fun _ => reads)
  let writable := (commandBinding command).approve (fun _ => commands)
  let base : LeanApp.Module Fixture := {
    name := "values", exports := [exported, writable]
    storage := [⟨"main.values", "fixture.values.v1"⟩] }
  let dependent : LeanApp.Module Fixture := {
    name := "views", dependencies := ["values"]
    storage := [⟨"main.values", "fixture.values.v1"⟩] }
  let app ← require (Application.create "fixture" [dependent, base])
  check "only approved exports and their codec metadata" (app.manifest.length == 2 &&
    (app.manifest.map (·.operation)) == [query.describe, command.describe] &&
    app.manifest.any (fun info => info.metadata.title == "Read value"))
  check "execution kinds" ((queryBinding query).executionKind == .query &&
    (commandBinding command).executionKind == .command)
  let context := TrustedNative.issueContext ⟨"local", "fixture", 1⟩ "request-1"
  let interpreter := (app.transport context).interpreter
  let (result, state) := (interpreter.call query 3).run {}
  check "typed query dispatch and read capability" (result == .ok 10 && state.calls == 1 && state.policies == 1)
  let (result, state) := (interpreter.call command 20).run state
  check "typed command dispatch and write capability" (result == .ok 20 && state.value == 20 && state.calls == 2)
  let (result, state) := (interpreter.call query 42).run state
  check "domain error codec round trip" (result == .error (.domain "missing") && state.calls == 3)
  let (result, denied) := (interpreter.call command 99).run state
  check "typed input policy denial never invokes handler" (result == .error .forbidden &&
    denied.calls == state.calls && denied.value == state.value && denied.policies == state.policies + 1)
  let (result, denied) := ((app.transport (.anonymous "anon")).interpreter.call query 0).run state
  check "anonymous denial never invokes handler" (result == .error .unauthenticated && denied.calls == state.calls)
  let wrongTenant := TrustedNative.issueContext ⟨"local", "other", 1⟩ "request-2"
  let (result, denied) := ((app.transport wrongTenant).interpreter.call query 0).run state
  check "tenant denial never invokes handler" (result == .error .forbidden && denied.calls == state.calls)
  let (result, denied) := (interpreter.call privateOp 0).run state
  check "unapproved operation cannot dispatch" (match result with
    | .error (.protocol e) => e.code == "operation.not_found" && denied.calls == state.calls
    | _ => false)
  let request : WireRequest := ⟨query.identity, .query, query.inputCodec.encode 1⟩
  let (result, _) := (app.dispatchHttp context { path := "/value" } request).run state
  check "HTTP metadata dispatch" (match result with | .ok (.success _) => true | _ => false)
  let (result, unchanged) := (app.dispatchHttp context { path := "/set" } request).run state
  check "HTTP endpoint cannot invoke another export" (match result with
    | .error (.incompatible _) => unchanged.calls == state.calls
    | _ => false)
  let (result, unchanged) := ((app.transport context).send { request with kind := .command }).run state
  check "wrong kind rejected before policy" (match result with
    | .error (.protocol _) => unchanged.policies == state.policies
    | _ => false)
  let (result, unchanged) := ((app.transport context).send { request with input := .str "forged" }).run state
  check "bad input rejected before policy" (match result with
    | .error (.decode _) => unchanged.policies == state.policies
    | _ => false)
  reject "duplicate operation/version" "operation.duplicate_identity"
    (Application.create "bad" [{ base with exports := [exported, exported] }])
  reject "duplicate module" "module.duplicate_name" (Application.create "bad" [base, base])
  reject "missing dependency" "module.missing_dependency" (Application.create "bad" [dependent])
  let versionExport := ({ queryBinding v2 with http := { path := "/value-v2" } }).approve (fun _ => reads)
  let versions ← require (Application.create "versions" [{ base with exports := [exported, versionExport] }])
  check "distinct explicit versions coexist" (versions.manifest.length == 2)
  let ambiguous := (queryBinding v2).approve (fun _ => reads)
  reject "ambiguous HTTP path across versions" "http.ambiguous_path"
    (Application.create "bad" [{ base with exports := [exported, ambiguous] }])
  reject "physical table mapping collision" "storage.mapping_collision"
    (Application.create "bad" [base, { dependent with storage := [⟨"main.values", "different"⟩] }])
  reject "empty mapping ID" "storage.empty_identity"
    (Application.create "bad" [{ base with storage := [⟨"main.values", ""⟩] }])
  for path in ["value", "/value/", "/a//b", "/a/../b", "/:id", "/%76alue", "/x?q=1"] do
    reject s!"noncanonical path {path}" "http.invalid_literal_path" (HttpBinding.validate { path })
  check "shared mapping and order-independent dependencies accepted" (app.modules.length == 2)
  for cap in [0, 2^32 + 1] do
    reject s!"body cap {cap}" "http.invalid_body_limit" (HttpBinding.validate { path := "/value", maxBodyBytes := some cap })
  check "body caps within (0, 2^32] accepted" ((HttpBinding.validate { path := "/value", maxBodyBytes := some (2^32) }).isOk &&
    (HttpBinding.validate { path := "/value", maxBodyBytes := some 1 }).isOk)
  check "rate limit burst defaults to a ten-second share" (({ perPrincipalPerMinute := 1200 } : RateLimit).burst == 200 &&
    ({ perPrincipalPerMinute := 60, burst := 5 } : RateLimit).burst == 5)
  let capped := ({ queryBinding v2 with http := { path := "/value", maxBodyBytes := some 4096 } }).approve (fun _ => reads)
  reject "same path with a different cap is still ambiguous" "http.ambiguous_path"
    (Application.create "bad" [{ base with exports := [exported, capped] }])
  let published : LeanApp.Module Fixture := { name := "live", exports := [({ commandBinding command with
    http := { path := "/set", maxBodyBytes := some 262144 }
    metadata := { publish := some { topicField := "doc", topicPrefix := "doc", eventName := "ops" } } }).approve (fun _ => commands)] }
  let live ← require (Application.create "live" [published])
  check "manifest entries carry http and metadata in the agreed shape"
    ((PublicOperation.manifest live.manifest).compress ==
      "{\"operations\":[{\"error\":{\"kind\":\"string\"},\"http\":{\"maxBodyBytes\":262144,\"method\":\"POST\",\"path\":\"/set\"},\
      \"input\":{\"kind\":\"tagged-natural\"},\"kind\":\"command\",\"metadata\":{\"describePolicy\":\"\",\"description\":\"\",\
      \"issuesStreamTicket\":false,\"publish\":{\"alsoToActorField\":null,\"eventName\":\"ops\",\"topicField\":\"doc\",\
      \"topicPrefix\":\"doc\"},\"title\":\"\"},\"name\":\"set\",\"namespace\":\"fixture\",\"output\":{\"kind\":\"tagged-natural\"},\
      \"version\":\"1\"}]}")
  let defaults := (PublicOperation.manifest app.manifest).compress
  check "manifest defaults are null and false"
    ((defaults.splitOn "\"maxBodyBytes\":null").length == 3 && (defaults.splitOn "\"publish\":null,").length == 3 &&
      (defaults.splitOn "\"issuesStreamTicket\":false").length == 3)
  let acl ← require AclFixture.application
  let cases := AclFixture.matrix acl
  check "exhaustive matrix covers 3 roles × 2 operations × {anonymous, other tenant}" (cases.size == 10)
  check "role model admits exactly the declared minimums" (AclFixture.failures acl).isEmpty
  check "manifest publishes the intended rule"
    ((acl.manifest.map (·.metadata.describePolicy)) == ["role ≥ viewer", "role ≥ editor"])
  check "published rule agrees with the declared minimum" (acl.manifest.all fun info =>
    Testing.describedMinimum AclFixture.roles info == AclFixture.minimums info.operation.identity)
  let weakened ← require (AclFixture.application (weakened := true))
  let failures := AclFixture.failures weakened
  check "a removed role check fails the matrix for the viewer and the other tenant"
    (failures.size == 2 && failures.all fun f => f.case.operation == AclFixture.editIdentity &&
      f.case.expect == .forbidden && f.observed == "allow")
  check "the weakened rule is visible in the manifest"
    (weakened.manifest.any (·.metadata.describePolicy == "authenticated"))
  let combined : Rule AclFixture.Fixture AclFixture.ReadOp
      (← require (Operation.canonical .query (Input := Unit) (Output := String) (Error := String) ⟨"doc", "probe", "1"⟩)) :=
    Policy.either (Policy.requireRole .owner AclFixture.roleOf) Policy.deny
  check "combinator descriptions compose" (combined.describePolicy == "role ≥ owner or deny")
  let editor := AclFixture.contexts.context (.role .editor)
  let decide := fun (rule : Rule AclFixture.Fixture AclFixture.ReadOp _) (context : RequestContext) =>
    (Id.run ((rule.policy context AclFixture.reads ()).run' {}) : CallResult Unit Empty)
  check "either admits the first passing rule and reports the first refusal"
    (decide combined (AclFixture.contexts.context .owner) == .ok () &&
      decide combined editor == .error .forbidden &&
      decide combined (.anonymous "x") == .error .unauthenticated)
  let strict : Rule AclFixture.Fixture AclFixture.ReadOp _ :=
    Policy.both Policy.authenticated (Policy.requireRole .editor AclFixture.roleOf (onMissing := .unauthenticated))
  check "both requires every rule and onMissing is configurable"
    (decide strict editor == .ok () &&
      decide strict (AclFixture.contexts.context .otherTenant) == .error .unauthenticated)
