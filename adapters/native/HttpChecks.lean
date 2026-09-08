import LeanAppNative.Client

open LeanAppNative LeanApp Contract Ontology

private def check (label : String) (condition : Bool) : IO Unit := do
  unless condition do throw (IO.userError s!"FAIL: {label}")
  IO.println s!"PASS: {label}"

private def require [Repr ε] (value : Except ε α) : IO α :=
  match value with | .ok value => pure value | .error e => throw (IO.userError (reprStr e))

private def rejected (code : String) (value : Validation α) : Bool :=
  match value with | .error errors => errors.first.code == code | _ => false

private def binding (op : Operation .query Nat Nat String) (path : String) (calls : IO.Ref Nat) :
    Binding IO Option Option op where
  http := { path }
  policy := fun ctx _ input => pure <|
    if ctx.principal.isNone || input == 401 then .error .unauthenticated
    else if input == 403 then .error .forbidden else .ok ()
  handler _ _ input := do
    calls.modify (· + 1)
    if input == 500 then throw (IO.userError "private host detail")
    if input == 9 then return .error "third-domain-error"
    return .ok (input + 10)

private def noReads : ReadCapability IO Option where
  read value := match value with
    | some value => pure value
    | none => throw (IO.userError "unused read")

private def response (status : Nat) (body : Lean.Json) : LeanHttp.Response := {
  status := (Std.Http.Status.ofCode none status.toUInt16).getD .internalServerError
  headers := .empty, body := body.compress.toUTF8
  effectiveUri := Std.Http.URI.parse! "http://fixture.invalid/third" }

def main : IO Unit := do
  let codecs ← require Http.codecs
  let calls ← IO.mkRef 0
  let exchanges ← IO.mkRef 0
  let first ← require (Operation.canonical .query (Input := Nat) (Output := Nat) (Error := String) ⟨"fixture", "one", "1"⟩)
  let second ← require (Operation.canonical .query (Input := Nat) (Output := Nat) (Error := String) ⟨"fixture", "two", "1"⟩)
  let third ← require (Operation.canonical .query (Input := Nat) (Output := Nat) (Error := String) ⟨"fixture", "three", "1"⟩)
  let exports := [(binding first "/first" calls).approve (fun _ => noReads),
    (binding second "/second" calls).approve (fun _ => noReads),
    (binding third "/third" calls).approve (fun _ => noReads)]
  let app ← require (Application.create "generic" [{ name := "fixture", exports }])
  let statuses := [Http.ErrorStatus.ofOperation third (fun _ => 422)]
  let server ← require (Server.create app codecs { errorStatuses := statuses, maxBodyBytes := 512 })
  let context := TrustedNative.issueContext ⟨"fixture", "fixture", 0⟩ "fixture"
  let client ← require (Client.create "https://arbitrary.example:8443/" app.manifest codecs statuses)
  let request : WireRequest := ⟨third.identity, .query, third.inputCodec.encode 2⟩
  let prepared ← require (client.prepare request)
  check "third operation selects approved route and arbitrary origin"
    (toString prepared.uri == "https://arbitrary.example:8443/third")
  check "native request disables redirects" (match prepared.redirects with | .never => true | _ => false)
  let transport := client.transportWith fun http => do
    exchanges.modify (· + 1)
    let body := match http.body with | .json json => json.compress | _ => ""
    let reply ← server.dispatch context (toString http.method) (toString http.uri.path) body
    pure ((response reply.status reply.body).decodeAs (α := Lean.Json))
  for op in [first, second, third] do
    let result ← transport.interpreter.call op 2
    check s!"generic typed dispatch {op.identity.name}" (match result with | .ok 12 => true | _ => false)
  let result ← transport.interpreter.call third 9
  check "native non2xx outcome preserves third domain error" (match result with
    | .error (.domain "third-domain-error") => true | _ => false)
  let before ← calls.get
  for status in [401, 403] do
    let result ← transport.interpreter.call third status
    check s!"native policy denial {status}" (match result with
      | .error .unauthenticated => status == 401
      | .error .forbidden => status == 403
      | _ => false)
  check "policy denial never calls handler" ((← calls.get) == before)
  let old := { request with operation := { third.identity with version := "old" } }
  let beforeExchange ← exchanges.get
  let result ← transport.send old
  check "unsupported version returns typed incompatibility without exchange" (match result with
    | .error (.incompatible mismatch) => mismatch.expected == third.identity && (mismatch.received == old.operation)
    | _ => false)
  check "incompatible request did not perform native exchange" ((← exchanges.get) == beforeExchange)
  let unknown := { request with operation := { third.identity with name := "private" } }
  check "unknown client identity rejected" (match client.prepare unknown with
    | .error (.protocol e) => e.code == "operation.not_found" | _ => false)
  check "wrong client kind rejected" (match client.prepare { request with kind := .command } with
    | .error (.protocol e) => e.code == "operation.kind_mismatch" | _ => false)
  for (req, expected) in [(old, 409), (unknown, 409), ({ request with kind := .command }, 400),
      ({ request with input := .str "bad" }, 400)] do
    let reply ← server.dispatch context "POST" "/third" (Http.encodeRequest codecs req).compress
    check s!"server rejects identity/kind/input with {expected}" (reply.status == expected)
  check "invalid requests never call handler" ((← calls.get) == before)
  let anon ← server.dispatch (.anonymous "anonymous") "POST" "/third" (Http.encodeRequest codecs request).compress
  check "host context required separately from JSON" (anon.status == 401 && (← calls.get) == before)
  let goodJson := Http.encodeRequest codecs request
  let fields ← require goodJson.getObj?
  let forged := Lean.Json.obj (fields.insert "principal" (.str "admin"))
  let reply ← server.dispatch context "POST" "/third" forged.compress
  check "client principal field rejected" (reply.status == 400 && (← calls.get) == before)
  for path in ["/missing", "/%74hird", "//third", "/third/", "/third//"] do
    let reply ← server.dispatch context "POST" path goodJson.compress
    check s!"literal routing rejects {path}" (reply.status == 404)
    let uri := Std.Http.URI.parse! ("http://localhost" ++ path)
    check s!"Std URI preserves literal path {path}" (toString uri.path == path)
  let reply ← server.dispatch context "GET" "/third" ""
  check "known operation wrong method is 405" (reply.status == 405)
  let reply ← server.dispatch context "POST" "/api/manifest" ""
  check "reserved manifest wrong method is 405" (reply.status == 405)
  let reply ← server.dispatch context "GET" "/api/manifest" ""
  check "manifest uses approved registry" (reply.status == 200 && reply.body == publicManifest app.manifest)
  let reply ← server.dispatch context "POST" "/third" "{"
  check "malformed JSON is 400" (reply.status == 400)
  let unknownKind := Lean.Json.obj (fields.insert "kind" (.str "private-admin"))
  let reply ← server.dispatch context "POST" "/third" unknownKind.compress
  check "unknown wire kind rejected before handler" (reply.status == 400 && (← calls.get) == before)
  let reply ← server.dispatch context "POST" "/third" (String.ofList (List.replicate 257 'é'))
  check "body limit counts UTF8 bytes before parsing" (reply.status == 413)
  let issued ← IO.mkRef 0
  let streamStatus := fun (bytes : ByteArray) => Std.Async.Async.block do
    let body ← Std.Http.Body.fromBytes bytes
    let request : Std.Http.Request Std.Http.Body.Stream := {
      line := { method := .post, version := .v11, uri := Std.Http.RequestTarget.parse! "/third" }
      body }
    let result ← Std.Async.ContextAsync.run (server.handler (fun _ => do
      issued.modify (· + 1)
      pure context) request)
    return result.line.status.toCode.toNat
  check "streaming body bound enforced before context issuance"
    ((← streamStatus (String.ofList (List.replicate 513 'x')).toUTF8) == 413 && (← issued.get) == 0)
  check "invalid UTF8 rejected before context issuance"
    ((← streamStatus ⟨#[255]⟩) == 400 && (← issued.get) == 0)
  let result ← transport.interpreter.call third 500
  check "host exception hides details in protocol envelope" (match result with
    | .error (.protocol e) => e.code == "handler.failed" && e.status == some 500 | _ => false)
  let domain := Http.domainResponse codecs third.identity (third.errorCodec.encode "third-domain-error")
  check "wrong domain status rejected" (match client.decodeOutcome request (.status (response 409 domain)) with
    | .error (.protocol e) => e.code == "response.status_mismatch" | _ => false)
  let success := Http.successResponse codecs third.identity (third.outputCodec.encode 12)
  check "wrong success status rejected" (match client.decodeOutcome request (.status (response 201 success)) with
    | .error (.protocol e) => e.code == "response.status_mismatch" | _ => false)
  let incompatible := Http.incompatibleResponse codecs first.identity third.identity
  check "non2xx incompatible envelope decoded" (match client.decodeOutcome request (.status (response 409 incompatible)) with
    | .error (.incompatible _) => true | _ => false)
  let tiny ← require (Client.create "http://fixture.invalid" app.manifest codecs statuses 1)
  check "buffered native response decoding bounded" (match tiny.decodeOutcome request (.status (response 422 domain)) with
    | .error (.protocol e) => e.code == "response.body_too_large" | _ => false)
  check "status policy must refer to approved identity" (rejected "http.status_not_exported"
    (Server.create app codecs { errorStatuses := [⟨unknown.operation, fun _ => .ok 400⟩] }))
  check "duplicate status policies rejected" (rejected "http.duplicate_status_policy"
    (Server.create app codecs { errorStatuses := statuses ++ statuses }))
  check "reserved manifest path collision rejected" (rejected "http.manifest_path_collision"
    (Server.create app codecs { manifestPath := "/third" }))
  check "route conflict rejected before adapter construction" (rejected "http.ambiguous_path"
    (Application.create "bad" [{ name := "bad", exports := [(binding first "/first" calls).approve (fun _ => noReads),
      (binding third "/first" calls).approve (fun _ => noReads)] }]))
  check "client duplicate route metadata rejected" (rejected "http.ambiguous_path"
    (Client.create "http://fixture.invalid" [⟨first.describe, { path := "/first" }, {}⟩,
      ⟨third.describe, { path := "/first" }, {}⟩] codecs))
  for origin in ["ftp://example.com", "http://user:pass@example.com", "http://example.com/base", "http://example.com?q=1"] do
    check s!"invalid base origin rejected {origin}" (rejected "http.invalid_origin" (Client.create origin app.manifest codecs))
  IO.println "PASS generic native HTTP checks (no sockets opened)"
