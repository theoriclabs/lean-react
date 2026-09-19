import LeanAppNative.Auth.Demo
import LeanDb.Migrate

open LeanAppNative LeanAppNative.Auth LeanApp

/-! The session table before LA-02, under the same table name, for the migration check. -/
namespace Legacy
structure Session where
  tokenDigest : String
  csrf : String
  actor : String
  generation : Int64
  expiresAt : Int64
  deriving LeanDb.Entity

def base : LeanDb.Base := { Auth.Demo.base with tables := [.of Auth.Account, .of Session, .of Auth.Invite] }
end Legacy

private def Except.isError (value : Except ε α) : Bool := !value.isOk
private instance [BEq ε] [BEq α] : BEq (Except ε α) where
  beq a b := match a, b with
    | .ok x, .ok y => x == y
    | .error x, .error y => x == y
    | _, _ => false

private def check (label : String) (test : Bool) : IO Unit := do
  unless test do throw (IO.userError s!"FAIL: {label}")
  IO.println s!"PASS auth: {label}"

private def ok (result : Except Auth.Error α) : IO α :=
  match result with | .ok v => pure v | .error e => throw (IO.userError s!"unexpected auth failure: {repr e}")

private def failure (result : Except Auth.Error α) (expected : Auth.Error) : Bool :=
  match result with | .error e => e == expected | .ok _ => false

private def password := "a sufficiently long password 🔐"

private def zeros : String := String.ofList (List.replicate 64 '0')

/-- A fresh runtime and authentication service over a temporary database. -/
private def withService (config : Auth.Service.Config)
    (body : Auth.Service → LeanAppNative.Runtime.Service → IO.Ref Nat → IO Unit) : IO Unit :=
  IO.FS.withTempDir fun dir => do
    let inst := LeanDb.Instance.ofPath (dir / "auth.sqlite")
    let .ok runtime ← LeanAppNative.Runtime.Service.new Auth.Demo.base inst | throw (IO.userError "session")
    let now ← IO.mkRef 1000
    let service ← ok (← Auth.Service.new runtime now.get config)
    try body service runtime now finally runtime.close

private def post (path body cookie csrf : String) : Auth.Request := Auth.Request.mk "POST" path [
  ("origin", "https://example.test"), ("content-type", "application/json"),
  ("x-leanapp-request", "1"), ("cookie", cookie), ("x-csrf-token", csrf)] body

private def signupBody (name : String) (extra : List (String × Lean.Json) := []) : String :=
  (Lean.Json.mkObj ([("username", .str name), ("password", .str password)] ++ extra)).compress

private def tenantPolicies : IO Unit := do
  withService { tenantPolicy := .fixed "ws" } fun service runtime _ => do
    check "fixed tenant must be nonempty and at most 64 characters"
      ((← Auth.Service.new runtime (config := { tenantPolicy := .fixed "" })).isError &&
        (← Auth.Service.new runtime (config := { tenantPolicy := .fixed (String.ofList (List.replicate 65 'w')) })).isError)
    let a ← ok (← service.signup "fixed_a" password)
    let b ← ok (← service.signup "fixed_b" password)
    check "fixed policy shares one workspace" (a.user.tenant == "ws" && b.user.tenant == "ws" && a.user.actor != b.user.actor)
    let visible ← ok (← service.withAuthenticated a.token (some a.csrf) "scope" fun conn context _ => do
      let some p := context.principal | throw (IO.userError "principal")
      let .ok byTenant ← LeanDb.DbM.run conn (LeanDb.selectP [Auth.Account] (.eq (.here Auth.Account.Field.tenant) .eq p.tenant))
        | throw (IO.userError "tenant read")
      let .ok owned ← LeanDb.DbM.run conn (LeanDb.selectP [Auth.Account] (.and
        (.eq (.here Auth.Account.Field.tenant) .eq p.tenant) (.eq (.here Auth.Account.Field.actor) .eq p.actor)))
        | throw (IO.userError "owner read")
      pure (byTenant.size, owned.size))
    check "shared tenant exposes another account's row only past the application's owner check" (visible == (2, 1))
    let host ← Auth.Demo.host service "https://example.test"
    let session ← host.dispatch { post "/auth/session" "" s!"__Host-leanapp_session={a.token}" "" with method := "GET" }
    check "session response names the shared workspace"
      (session.reply.status == 200 && ((session.reply.body.getObjVal? "user").bind (·.getObjValAs? String "tenant")).toOption == some "ws")
    check "invite field refused outside the invite policy"
      ((← host.dispatch (post "/auth/signup" (signupBody "fixed_c" [("invite", .str zeros)]) "" "")).reply.status == 401 &&
        failure (← service.signup "fixed_c" password (some zeros)) .invalidCredentials)
  withService { tenantPolicy := .invite } fun service _ now => do
    check "invite policy refuses signup without a token" (failure (← service.signup "inv_a" password) .inviteRequired)
    check "invite issuance validates tenant and lifetime"
      ((← service.createInvite "" 60).isError && (← service.createInvite "team" 0).isError)
    let token ← ok (← service.createInvite "team" 600)
    check "invite tokens have the bearer token shape" (tokenShape token)
    check "malformed and unknown invites are refused before password work"
      (failure (← service.signup "inv_a" password (some "nope")) .inviteRequired &&
        failure (← service.signup "inv_a" password (some zeros)) .inviteRequired)
    let a ← ok (← service.signup "inv_a" password (some token))
    check "invite places the account in the invite's tenant" (a.user.tenant == "team" && a.user.actor != a.user.tenant)
    check "invite tokens are single use" (failure (← service.signup "inv_b" password (some token)) .inviteRequired)
    let expiring ← ok (← service.createInvite "team" 10)
    now.modify (· + 10)
    check "invite expiry is exclusive" (failure (← service.signup "inv_b" password (some expiring)) .inviteRequired)
    let fresh ← ok (← service.createInvite "team" 600)
    check "invalid invite hides username availability" (failure (← service.signup "inv_a" password (some zeros)) .inviteRequired)
    check "taken name under invite policy" (failure (← service.signup "inv_a" password (some fresh)) .usernameUnavailable)
    let c ← ok (← service.signup "inv_c" password (some fresh))
    check "aborted signup leaves the invite unused" (c.user.tenant == "team")
    let host ← Auth.Demo.host service "https://example.test"
    let denied ← host.dispatch (post "/auth/signup" (signupBody "inv_http") "" "")
    check "HTTP signup without invite is 403 auth.invite_required"
      (denied.reply.status == 403 && (denied.reply.body.getObjValAs? String "error").toOption == some "auth.invite_required")
    let http ← ok (← service.createInvite "team" 600)
    check "HTTP signup rejects an extra field beside the invite"
      ((← host.dispatch (post "/auth/signup" (signupBody "inv_http" [("invite", .str http), ("role", .str "admin")]) "" "")).reply.status == 401)
    let accepted ← host.dispatch (post "/auth/signup" (signupBody "inv_http" [("invite", .str http)]) "" "")
    check "HTTP signup with a valid invite joins the invite's tenant"
      (accepted.reply.status == 200 && accepted.cookie.isSome &&
        ((accepted.reply.body.getObjVal? "user").bind (·.getObjValAs? String "tenant")).toOption == some "team")
    check "HTTP login refuses the invite field"
      ((← host.dispatch (post "/auth/login" (signupBody "inv_http" [("invite", .str http)]) "" "")).reply.status == 401)

private def resolves (service : Auth.Service) (issued : Auth.Issued) : IO Bool :=
  return (← service.session issued.token).isOk

private def sessions : IO Unit := do
  withService { maxSessions := 3 } fun service runtime now => do
    check "zero concurrent sessions is refused" ((← Auth.Service.new runtime (config := { maxSessions := 0 })).isError)
    let a ← ok (← service.signup "multi" password (label := some "Laptop"))
    let b ← ok (← service.login "multi" password (label := some " \tPhone 📱 (home)\x01  "))
    check "login beyond one session keeps the generation and earlier sessions"
      (b.user.generation == a.user.generation && (← resolves service a) && (← resolves service b))
    now.modify (· + 1)
    let c ← ok (← service.login "multi" password)
    now.modify (· + 1)
    let d ← ok (← service.login "multi" password)
    check "four logins keep the three newest and evict the oldest"
      (!(← resolves service a) && (← resolves service b) && (← resolves service c) && (← resolves service d))
    let listed ← ok (← service.sessions d.token d.csrf)
    let digests ← [b, c, d].mapM fun s => Auth.Crypto.digestToken s.token
    check "session list is newest first with one current entry and opaque ids"
      (listed.length == 3 && (listed.filter (·.current)).length == 1 && (listed.head?.map (·.current)) == some true &&
        listed.all (fun s => tokenShape s.id && !digests.contains s.id && ![b.token, c.token, d.token].contains s.id))
    check "labels are sanitized to printable ASCII and stamps are recorded"
      (listed.any (fun s => s.label == some "Phone  (home)") &&
        listed.all (fun s => s.createdAt.isSome && s.lastSeenAt == s.createdAt))
    check "session listing needs the CSRF token" ((← service.sessions d.token c.csrf) == .error .forbidden)
    let phone := (listed.find? (·.label == some "Phone  (home)")).get!.id
    check "revoking another device from the current one"
      ((← service.revokeSession d.token d.csrf phone) == .ok false && !(← resolves service b) && (← resolves service d))
    check "unknown or malformed session ids are not found"
      (failure (← service.revokeSession d.token d.csrf zeros) .sessionNotFound &&
        failure (← service.revokeSession d.token d.csrf "short") .sessionNotFound)
    let other ← ok (← service.signup "other" password)
    let current := (listed.find? (·.current)).get!.id
    check "another account cannot revoke a guessed id"
      (failure (← service.revokeSession other.token other.csrf current) .sessionNotFound && (← resolves service d))
    let own := ((← ok (← service.sessions c.token c.csrf)).find? (·.current)).get!.id
    check "revoking the current session behaves like logout"
      ((← service.revokeSession c.token c.csrf own) == .ok true && !(← resolves service c) && (← resolves service d))
    let e ← ok (← service.login "multi" password (label := some "Tablet"))
    let renewed := "a brand new password that is long"
    check "password change refuses weak passwords and wrong CSRF"
      (failure (← service.changePassword e.token e.csrf password "short") .invalidPassword &&
        failure (← service.changePassword e.token d.csrf password renewed) .forbidden && (← resolves service d))
    let f ← ok (← service.changePassword e.token e.csrf password renewed)
    check "password change re-issues the caller and revokes every other session"
      (f.token != e.token && f.csrf != e.csrf && (← resolves service f) && !(← resolves service e) &&
        !(← resolves service d) && f.user.generation > e.user.generation)
    check "re-issued session keeps its label"
      (((← ok (← service.sessions f.token f.csrf)).map (·.label)) == [some "Tablet"])
    check "old password no longer logs in" (failure (← service.login "multi" password) .invalidCredentials)
    let g ← ok (← service.login "multi" renewed)
    let mut throttled := false
    for _ in [:12] do
      match ← service.changePassword f.token f.csrf "not the current password" renewed with
      | .error .throttled => throttled := true; break
      | .error .invalidCredentials => pure ()
      | other => throw (IO.userError s!"unexpected password change outcome {repr (other.map (·.user))}")
    check "wrong current password counts against the credential throttle" (throttled && (← resolves service f))
    discard <| ok (← service.logoutAll f.token f.csrf)
    check "logout-all revokes every session" (!(← resolves service f) && !(← resolves service g))
  withService { maxSessions := 2 } fun service _ now => do
    let a ← ok (← service.signup "seen" password)
    let stamp := fun (list : List Auth.SessionInfo) => list.head!.lastSeenAt
    check "lastSeenAt starts at creation" (stamp (← ok (← service.sessions a.token a.csrf)) == some 1000)
    now.set 1299
    discard <| ok (← service.session a.token)
    check "lastSeenAt is not rewritten within five minutes" (stamp (← ok (← service.sessions a.token a.csrf)) == some 1000)
    now.set 1300
    discard <| ok (← service.session a.token)
    check "lastSeenAt refreshes after five minutes" (stamp (← ok (← service.sessions a.token a.csrf)) == some 1300)
    let quiet ← ok (← service.login "seen" password (label := some "\x01\x02"))
    check "labels reduced to nothing are stored as none"
      ((← ok (← service.sessions quiet.token quiet.csrf)).all (·.label.isNone))
  withService { maxSessions := 2, sessionLabel := false } fun service _ _ => do
    let a ← ok (← service.signup "unlabeled" password (label := some "Laptop"))
    check "labels are dropped when disabled" ((← ok (← service.sessions a.token a.csrf)).all (·.label.isNone))
  IO.FS.withTempDir fun dir => do
    let inst := LeanDb.Instance.ofPath (dir / "legacy.sqlite")
    let hash ← Auth.Crypto.hashPassword password
    let token ← Auth.Crypto.randomToken
    let csrf ← Auth.Crypto.randomToken
    let digest ← Auth.Crypto.digestToken token
    let .ok legacy ← LeanAppNative.Runtime.Service.new Legacy.base inst | throw (IO.userError "legacy session")
    let .ok (.ok _) ← legacy.withConnection fun conn => LeanDb.DbM.run conn (do
        discard <| LeanDb.insert Auth.Account ⟨"legacy", hash, "legacy-actor", "legacy-actor", 1, true⟩
        LeanDb.insert Legacy.Session ⟨digest, csrf, "legacy-actor", 1, 4000⟩)
      | throw (IO.userError "legacy rows")
    legacy.close
    let .ok drifted ← LeanAppNative.Runtime.Service.new Auth.Demo.base inst | throw (IO.userError "drifted session")
    check "old schema is gated until migrated" ((← drifted.gate).isSome)
    drifted.close
    let .ok (some plan, some report) ← LeanDb.migrate inst.path Auth.Demo.base.specs (apply := true)
      | throw (IO.userError "migration failed")
    check "session columns migrate additively"
      (!plan.isDestructive && report.applied == ["add column \"session\".\"createdAt\"",
        "add column \"session\".\"lastSeenAt\"", "add column \"session\".\"label\""])
    let .ok runtime ← LeanAppNative.Runtime.Service.new Auth.Demo.base inst | throw (IO.userError "migrated session")
    try
      check "migrated instance is admitted" ((← runtime.gate).isNone)
      let service ← ok (← Auth.Service.new runtime (pure 1000) { maxSessions := 3 })
      let (user, _) ← ok (← service.session token)
      check "legacy session still resolves" (user.username == "legacy")
      let listed ← ok (← service.sessions token csrf)
      check "legacy session lists with an opaque id and absent stamps"
        (listed.length == 1 && tokenShape listed.head!.id && listed.head!.createdAt.isNone && listed.head!.lastSeenAt == some 1000)
      check "legacy session can be revoked" ((← service.revokeSession token csrf listed.head!.id) == .ok true)
    finally runtime.close

/-- Session-table selects recorded in LeanDB's query log: the statement trace of the auth step. -/
private def sessionReads (runtime : LeanAppNative.Runtime.Service) : IO Nat := do
  let .ok count ← runtime.withConnection fun conn => do
      let stmt ← conn.raw.prepare "SELECT count(*) FROM _leandb_log WHERE verb = 'select' AND detail LIKE 'session |%'"
      discard stmt.step
      return (← stmt.columnInt64 0).toInt.toNat
    | throw (IO.userError "query log unavailable")
  return count

private def authenticated (service : Auth.Service) (issued : Auth.Issued) (csrf : Option String := some issued.csrf) :
    IO (Except Auth.Error Unit) :=
  service.withAuthenticated issued.token csrf "cached" fun _ _ _ => pure ()

private def sessionCache : IO Unit := do
  withService { sessionCacheTtlMs := 30000, maxSessions := 3 } fun service runtime now => do
    let a ← ok (← service.signup "cached" password)
    discard <| ok (← authenticated service a)
    let before ← sessionReads runtime
    let stats ← service.cacheStats
    let context ← ok (← service.withAuthenticated a.token (some a.csrf) "hit" fun _ context _ => pure context)
    check "second authenticated call performs no session read and issues the same principal"
      ((← sessionReads runtime) == before && (← service.cacheStats).hits == stats.hits + 1 &&
        context.principal == some ⟨a.user.actor, a.user.tenant, a.user.generation⟩)
    check "cache hits still enforce the CSRF token"
      (failure (← authenticated service a (some zeros)) .forbidden && (← service.cacheStats).hits == stats.hits + 2)
    check "cache misses are counted for unknown tokens"
      (failure (← service.session zeros) .unauthenticated && (← service.cacheStats).misses > stats.misses)
    let b ← ok (← service.login "cached" password)
    discard <| ok (← authenticated service b)
    discard <| ok (← service.logout b.token b.csrf)
    check "logout invalidates the cache immediately" (failure (← authenticated service b) .unauthenticated)
    let c ← ok (← service.login "cached" password)
    let d ← ok (← service.login "cached" password)
    discard <| ok (← authenticated service c)
    discard <| ok (← authenticated service d)
    let evicted ← ok (← service.login "cached" password)
    check "session eviction invalidates the evicted entry only"
      (failure (← authenticated service a) .unauthenticated && (← authenticated service c).isOk && (← authenticated service d).isOk)
    let ownId := ((← ok (← service.sessions d.token d.csrf)).find? (·.current)).get!.id
    discard <| ok (← service.revokeSession d.token d.csrf ownId)
    check "revocation invalidates the cache immediately" (failure (← authenticated service d) .unauthenticated)
    discard <| ok (← service.logoutAll c.token c.csrf)
    check "generation bump invalidates every cached session of the actor"
      (failure (← authenticated service c) .unauthenticated && failure (← authenticated service evicted) .unauthenticated)
    let e ← ok (← service.login "cached" password)
    let f ← ok (← service.login "cached" password)
    discard <| ok (← authenticated service e)
    discard <| ok (← authenticated service f)
    let g ← ok (← service.changePassword e.token e.csrf password "a changed password for the cache")
    check "password change invalidates cached sessions and admits the re-issued one"
      (failure (← authenticated service e) .unauthenticated && failure (← authenticated service f) .unauthenticated &&
        (← authenticated service g).isOk)
    discard <| ok (← authenticated service g)
    discard <| ok (← service.setAccess g.user.actor "moved" true)
    check "setAccess invalidates cached sessions" (failure (← authenticated service g) .unauthenticated)
    let h ← ok (← service.login "cached" "a changed password for the cache")
    discard <| ok (← authenticated service h)
    now.set (1000 + 86400)
    check "expiry is checked on every hit" (failure (← authenticated service h) .unauthenticated)
    let final ← service.cacheStats
    check "cache statistics are exposed" (final.hits > 0 && final.misses > 0 && final.invalidations > 0)
  withService { sessionCacheTtlMs := 1 } fun service runtime _ => do
    let a ← ok (← service.signup "stale" password)
    discard <| ok (← authenticated service a)
    let before ← sessionReads runtime
    IO.sleep 5
    discard <| ok (← authenticated service a)
    check "a stale entry misses and re-reads the session" ((← sessionReads runtime) == before + 1)
  withService { sessionCacheTtlMs := 30000, sessionCacheMax := 2, maxSessions := 5 } fun service _ _ => do
    let a ← ok (← service.signup "bounded" password)
    let b ← ok (← service.login "bounded" password)
    let c ← ok (← service.login "bounded" password)
    for s in [a, b, c] do discard <| ok (← authenticated service s)
    check "cache size stays within its bound" ((← service.cacheStats).size ≤ 2)
  withService {} fun service runtime _ => do
    let a ← ok (← service.signup "uncached" password)
    discard <| ok (← authenticated service a)
    let before ← sessionReads runtime
    discard <| ok (← authenticated service a)
    check "a disabled cache reads the session on every call"
      ((← sessionReads runtime) == before + 1 && (← service.cacheStats) == ⟨0, 0, 0, 0⟩)

/-- A host with one rate-limited and one unlimited operation. -/
private def limitedHost (service : Auth.Service) : IO Auth.Host := do
  let .ok codecs := Contract.Http.codecs | throw (IO.userError "codecs")
  let make := fun (name path : String) (limit : Option RateLimit) => do
    let op : Contract.Operation .query Unit Nat String ← Contract.Operation.canonical .query ⟨"limited", name, "1"⟩
    let binding : Binding IO Option Option op := {
      http := { path, rateLimit := limit }
      policy := fun context _ _ => pure <| if context.principal.isSome then .ok () else .error .unauthenticated
      handler := fun _ _ _ => return .ok 1 }
    pure (binding.approve fun _ => { read := fun value => match value with
      | some value => pure value | none => throw (IO.userError "unused") })
  let .ok app := (do
      Application.create "limited" [{ name := "limited", exports := [
        ← make "ping" "/api/limited" (some { perPrincipalPerMinute := 1200, burst := 20 }),
        ← make "free" "/api/free" none] }] : Ontology.Validation (Application IO))
    | throw (IO.userError "limited application")
  let .ok template := Server.create app codecs { maxBodyBytes := 8192 } | throw (IO.userError "limited server")
  let .ok host := Auth.Host.create service template (fun _ => .ok app) "https://example.test"
    | throw (IO.userError "limited host")
  pure host

/-- Drive `Host.handler` with a real `Std.Http` request; returns status and body text. -/
private def httpRequest (host : Auth.Host) (method : Std.Http.Method) (path : String)
    (headers : List (String × String)) (body : String) (peer : Option Std.Net.SocketAddress := none) :
    IO (Nat × String) := Std.Async.Async.block do
  let stream ← Std.Http.Body.fromBytes body.toUTF8
  let named := Std.Http.Headers.ofList (headers.map fun (k, v) => (Std.Http.Header.Name.ofString! k, Std.Http.Header.Value.ofString! v))
  let extensions := match peer with
    | some addr => Std.Http.Extensions.empty.insert (Std.Http.Server.RemoteAddr.mk addr)
    | none => Std.Http.Extensions.empty
  let request : Std.Http.Request Std.Http.Body.Stream := {
    line := { method, version := .v11, uri := Std.Http.RequestTarget.parse! path, headers := named }
    body := stream, extensions }
  let response ← Std.Async.ContextAsync.run (host.handler request)
  let mut bytes := ByteArray.empty
  repeat
    match ← response.body.recv with
    | some chunk => bytes := bytes ++ chunk.data
    | none => break
  return (response.line.status.toCode.toNat, String.fromUTF8! bytes)

private def field (json : Lean.Json) (name : String) : Lean.Json := (json.getObjVal? name).toOption.getD .null
private def natField (json : Lean.Json) (name : String) : Nat := ((field json name).getNat?).toOption.getD 0

private def observability : IO Unit := withService { sessionCacheTtlMs := 30000 } fun service _ _ => do
  let lines ← IO.mkRef (#[] : Array String)
  Log.configure { sink := .buffer lines }
  Metrics.reset
  try
    let host ← Auth.Demo.host service "https://example.test"
    let base := [("origin", "https://example.test"), ("content-type", "application/json"), ("x-leanapp-request", "1")]
    let (status, signedUp) ← httpRequest host .post "/auth/signup" (("x-request-id", "check-1") :: base) (signupBody "observed")
    check "HTTP signup through the handler succeeds" (status == 200)
    let .ok signedJson := Lean.Json.parse signedUp | throw (IO.userError "signup body")
    let csrf := ((field signedJson "csrf").getStr?).toOption.getD ""
    let actor := ((field (field signedJson "user") "actor").getStr?).toOption.getD ""
    let a ← ok (← service.login "observed" password)
    let cookie := s!"__Host-leanapp_session={a.token}"
    let wire := "{\"operation\":{\"namespace\":\"auth-demo\",\"name\":\"whoami\",\"version\":\"1\"},\"kind\":\"query\",\"input\":null}"
    let authed := fun (extra : List (String × String)) => httpRequest host .post "/api/whoami"
      (extra ++ base ++ [("cookie", cookie), ("x-csrf-token", a.csrf)]) wire
    check "authenticated operations succeed through the handler"
      ((← authed [("x-request-id", "check-2")]).1 == 200 && (← authed [("x-request-id", "a b")]).1 == 200 &&
        (← authed [("x-request-id", String.ofList (List.replicate 65 'x'))]).1 == 200)
    check "wrong CSRF is logged as forbidden" ((← httpRequest host .post "/api/whoami" (base ++ [("cookie", cookie), ("x-csrf-token", zeros)]) wire).1 == 403)
    check "oversized bodies are refused before dispatch"
      ((← httpRequest host .post "/api/whoami" (base ++ [("cookie", cookie), ("x-csrf-token", a.csrf)]) (String.ofList (List.replicate 9000 'x'))).1 == 413)
    let captured ← lines.get
    let entries ← captured.toList.mapM fun line => match Lean.Json.parse line with
      | .ok json => pure json | .error e => throw (IO.userError s!"log line is not JSON: {e}")
    check "one JSON line per request" (entries.length == 6)
    let keys := ["v", "ts", "requestId", "method", "path", "operation", "status", "outcome", "principalHash", "durations", "bodyBytes", "replyBytes"]
    let hasKeys := fun (json : Lean.Json) => match json.getObj? with
      | .ok fields => keys.all (fun k => (json.getObjVal? k).isOk) && fields.size == keys.length
      | .error _ => false
    check "every line carries exactly the versioned field set" (entries.all fun e => hasKeys e && natField e "v" == 1 && natField e "ts" > 0)
    let durations := fun (e : Lean.Json) => field e "durations"
    check "durations are monotone" (entries.all fun e =>
      let d := durations e
      natField d "auth" + natField d "queueWait" + natField d "db" + natField d "handler" ≤ natField d "total")
    let signup := entries[0]!
    let hash := Log.principalHash actor
    check "signup line honours the client request id and hashes the principal"
      ((field signup "requestId").getStr? == .ok "check-1" && (field signup "path").getStr? == .ok "/auth/signup" &&
        natField signup "status" == 200 && (field signup "outcome").getStr? == .ok "success" &&
        field signup "operation" == .null && (field signup "principalHash").getStr? == .ok hash && hash.length == 16 &&
        natField signup "bodyBytes" == (signupBody "observed").utf8ByteSize && natField signup "replyBytes" == signedUp.utf8ByteSize &&
        natField (durations signup) "auth" > 0)
    let whoami := entries[1]!
    check "operation lines name the operation, outcome and principal"
      ((field whoami "requestId").getStr? == .ok "check-2" &&
        (field (field whoami "operation") "name").getStr? == .ok "whoami" &&
        (field (field whoami "operation") "namespace").getStr? == .ok "auth-demo" &&
        (field whoami "outcome").getStr? == .ok "success" && (field whoami "principalHash").getStr? == .ok hash)
    check "malformed request ids are replaced by generated ones"
      ([entries[2]!, entries[3]!].all fun e => match (field e "requestId").getStr? with
        | .ok id => id.startsWith "r" && Log.validRequestId id && id != "a b" | .error _ => false)
    check "denied and refused requests are logged with their outcome"
      ((field entries[4]! "outcome").getStr? == .ok "forbidden" && natField entries[4]! "status" == 403 &&
        (field entries[5]! "outcome").getStr? == .ok "protocol" && natField entries[5]! "status" == 413 &&
        natField entries[5]! "bodyBytes" == 0)
    let text := String.intercalate "\n" captured.toList
    check "logs never contain the username, actor, tokens, CSRF, password or cookie"
      (!text.contains "observed" && !text.contains actor && !text.contains a.token &&
        !text.contains a.csrf && !text.contains csrf && !text.contains password && !text.contains cookie)
    let loopback : Std.Net.SocketAddress := .v4 ⟨Std.Net.IPv4Addr.ofParts 127 0 0 1, 4000⟩
    let remote : Std.Net.SocketAddress := .v4 ⟨Std.Net.IPv4Addr.ofParts 10 0 0 7, 4000⟩
    let (metricsStatus, metrics) ← httpRequest host .get "/internal/metrics" [] "" (some loopback)
    -- Three hits: the second and third whoami and the CSRF-refused request, which resolved before the check.
    check "metrics are served to loopback peers in Prometheus text format"
      (metricsStatus == 200 && metrics.contains "leanapp_requests_total{operation=\"auth-demo/whoami/1\",outcome=\"success\"} 3" &&
        metrics.contains "leanapp_requests_total{operation=\"-\",outcome=\"forbidden\"} 1" &&
        metrics.contains "leanapp_request_duration_ms_count 6" && metrics.contains "leanapp_auth_session_cache_hits_total 3" &&
        metrics.contains "leanapp_auth_session_cache_misses_total 1" &&
        metrics.contains "leanapp_writer_queue_depth 0" && metrics.contains "leanapp_request_queue_wait_ms_bucket{le=\"+Inf\"} 6")
    check "metrics are refused for non-loopback or unknown peers"
      ((← httpRequest host .get "/internal/metrics" [] "" (some remote)).1 == 404 && (← httpRequest host .get "/internal/metrics" [] "").1 == 404)
    check "metrics scrapes are not logged as requests" ((← lines.get).size == 8)
    -- Three admitted credential attempts so far; the per-name quota of ten leaves five throttled.
    discard <| ok (← service.login "observed" password)
    for _ in [:12] do discard <| service.login "observed" "not the password at all"
    check "auth throttles are counted" ((← httpRequest host .get "/internal/metrics" [] "" (some loopback)).2.contains "leanapp_auth_throttles_total 5")
    Metrics.setGauge "leanapp_hot_state_entries" 7
    check "later subsystems can register gauges by name"
      ((← httpRequest host .get "/internal/metrics" [] "" (some loopback)).2.contains "leanapp_hot_state_entries 7")
    check "request id validation" (Log.validRequestId "abc-DEF_0.9~" && !Log.validRequestId "" &&
      !Log.validRequestId (String.ofList (List.replicate 65 'a')) && !Log.validRequestId "a/b" && !Log.validRequestId "é")
  finally Log.configure {}

private def rateLimits : IO Unit := withService {} fun service _ now => do
  let host ← limitedHost service
  let a ← ok (← service.signup "limited_a" password)
  let b ← ok (← service.signup "limited_b" password)
  let call := fun (issued : Auth.Issued) (name path : String) => host.dispatch (post path
    (Lean.Json.mkObj [("operation", .mkObj [("namespace", .str "limited"), ("name", .str name), ("version", .str "1")]),
      ("kind", .str "query"), ("input", .null)]).compress s!"__Host-leanapp_session={issued.token}" issued.csrf)
  let mut statuses : List (Nat × Option Nat) := []
  for _ in [:25] do
    let response ← call a "ping" "/api/limited"
    statuses := statuses ++ [(response.reply.status, response.retryAfter)]
  check "a burst of 25 admits exactly 20 and refuses 5 with Retry-After"
    ((statuses.filter (·.1 == 200)).length == 20 && (statuses.filter (· == (429, some 1))).length == 5 &&
      (statuses.take 20).all (·.1 == 200))
  check "the refusal is a protocol envelope"
    (((← call a "ping" "/api/limited").reply.body.getObjValAs? String "code").toOption == some "request.rate_limited")
  check "another principal is unaffected" ((← call b "ping" "/api/limited").reply.status == 200)
  check "the same principal is unaffected on an unlimited operation" ((← call a "free" "/api/free").reply.status == 200)
  now.modify (· + 1)
  check "one second refills the per-minute rate in whole tokens"
    ((← call a "ping" "/api/limited").reply.status == 200 &&
      (← (List.range 19).mapM fun _ => call a "ping" "/api/limited").all (·.reply.status == 200) &&
      (← call a "ping" "/api/limited").reply.status == 429)
  now.modify (· + 120)
  check "the bucket never exceeds its burst"
    ((← (List.range 20).mapM fun _ => call a "ping" "/api/limited").all (·.reply.status == 200) &&
      (← call a "ping" "/api/limited").reply.status == 429)

private def run : IO Unit := IO.FS.withTempDir fun dir => do
  let inst := LeanDb.Instance.ofPath (dir / "auth.sqlite")
  let .ok runtime ← LeanAppNative.Runtime.Service.new Auth.Demo.base inst | throw (IO.userError "session")
  let now ← IO.mkRef 1000
  let service ← ok (← Auth.Service.new runtime now.get { ttl := 60 })
  try
    check "username canonicalization" (username "Alice_01" == .ok "alice_01")
    check "username bounds and alphabet" ((username "a").isError && (username "ali ce").isError && (username "álîce").isError)
    check "password length policy without composition rules" (!validPassword "short" && validPassword "               ")
    let alice ← ok (← service.signup "Alice_01" password)
    check "server assigns actor and private tenant" (tokenShape alice.user.actor && alice.user.tenant == alice.user.actor)
    check "independent random session and CSRF" (tokenShape alice.token && tokenShape alice.csrf && alice.token != alice.csrf)
    check "duplicate canonical name rejected" ((← service.signup "ALICE_01" password).isError)
    check "wrong password rejected" ((← service.login "Alice_01" "a completely wrong password").isError)
    check "unknown login has same typed error" ((← service.login "nobody" password).map (fun _ => ()) == .error .invalidCredentials)
    let bob ← ok (← service.signup "bob_02" password)
    check "signup tenants are isolated" (alice.user.tenant != bob.user.tenant)
    let logged ← ok (← service.login "ALICE_01" password)
    check "login replaces session and increases generation" (logged.token != alice.token && logged.user.generation > alice.user.generation)
    check "replaced session rejected" ((← service.session alice.token).isError)
    let current ← ok (← service.session logged.token)
    check "session reload recovers user and CSRF" (current.1 == logged.user && current.2 == logged.csrf)
    check "forged token rejected" ((← service.session (String.ofList (List.replicate 64 '0'))).isError)
    let called ← IO.mkRef false
    let denied ← service.withAuthenticated logged.token (some bob.csrf) "test" fun _ _ _ => called.set true
    check "wrong CSRF never invokes operation" (denied == .error .forbidden && !(← called.get))
    let context ← ok (← service.withAuthenticated logged.token (some logged.csrf) "request" fun _ context _ => pure context)
    check "principal comes from current authoritative membership" (context.principal == some ⟨logged.user.actor, logged.user.tenant, logged.user.generation⟩)
    let host ← Auth.Demo.host service "https://example.test"
    let request := fun path body cookie csrf => Auth.Request.mk "POST" path [
      ("origin", "https://example.test"), ("content-type", "application/json"),
      ("x-leanapp-request", "1"), ("cookie", cookie), ("x-csrf-token", csrf)] body
    let cookie := s!"__Host-leanapp_session={logged.token}"
    let body := "{\"operation\":{\"namespace\":\"auth-demo\",\"name\":\"whoami\",\"version\":\"1\"},\"kind\":\"query\",\"input\":null}"
    let reply ← host.dispatch (request "/api/whoami" body cookie logged.csrf)
    check "authenticated operation uses current principal" (reply.reply.status == 200 && (reply.reply.body.getObjValAs? String "value").toOption == some "alice_01")
    check "missing csrf rejected" ((← host.dispatch (request "/api/whoami" body cookie "")).reply.status == 403)
    let cross := { request "/auth/login" "{}" "" "" with headers := [("origin", "https://evil.test"), ("content-type", "application/json"), ("x-leanapp-request", "1")] }
    check "cross-origin login refused" ((← host.dispatch cross).reply.status == 403)
    let duplicate := { request "/api/whoami" body cookie logged.csrf with headers := ("origin", "https://evil.test") :: (request "" "" cookie logged.csrf).headers }
    check "ambiguous origin headers refused" ((← host.dispatch duplicate).reply.status == 403)
    check "duplicate session cookies refused" ((← host.dispatch (request "/api/whoami" body (cookie ++ "; " ++ cookie) logged.csrf)).reply.status == 401)
    let credentials := (Lean.Json.mkObj [("username", .str "charlie_03"), ("password", .str password)]).compress
    let signed ← host.dispatch (request "/auth/signup" credentials "" "")
    check "HTTP signup succeeds" (signed.reply.status == 200)
    let setCookie := signed.cookie.getD ""
    check "production cookie attributes" (setCookie.startsWith "__Host-leanapp_session=" && setCookie.contains "HttpOnly" && setCookie.contains "SameSite=Strict" && setCookie.contains "Secure" && setCookie.contains "Path=/" && !setCookie.contains "Domain=")
    check "bearer is absent from public response" ((signed.reply.body.getObjVal? "token").isError)
    check "logout wrong csrf does not revoke" ((← service.logout logged.token bob.csrf).isError && (← service.session logged.token).isOk)
    discard <| ok (← service.logout logged.token logged.csrf)
    check "logout revokes session" ((← service.session logged.token).isError)
    discard <| ok (← service.setAccess bob.user.actor "new-private-tenant" true)
    check "membership change revokes old session" ((← service.session bob.token).isError)
    let bob2 ← ok (← service.login "bob_02" password)
    check "new login resolves updated membership" (bob2.user.tenant == "new-private-tenant")
    discard <| ok (← service.setAccess bob.user.actor bob2.user.tenant false)
    check "disabled account cannot log in" ((← service.login "bob_02" password).isError)
    now.set 1060
    let charlieToken := ((setCookie.splitOn ";").head!.splitOn "=")[1]!
    check "expiry is exclusive and persisted" ((← service.session charlieToken).isError)
    -- Deterministically keep one password operation inside the KDF admission gate:
    -- its hash finishes, then issuance queues behind the held database lock.
    let entered ← IO.Promise.new (α := Except IO.Error Unit)
    let release ← IO.Promise.new (α := Except IO.Error Unit)
    let held ← IO.asTask (runtime.withConnection fun _ => do
      entered.resolve (.ok ())
      IO.ofExcept release.result!.get) Task.Priority.dedicated
    IO.ofExcept entered.result!.get
    let signing ← IO.asTask (service.signup "holder" password) Task.Priority.dedicated
    try
      let mut queued := false
      for _ in [:500] do
        if (← runtime.snapshot).queued == 1 then queued := true; break
        IO.sleep 10
      check "password issuance queued while KDF capacity remains reserved" queued
      for i in [:60] do
        let rejected ← service.login s!"busy_{i / 10}" password
        check "unadmitted KDF burst rejected" (rejected.map (fun _ => ()) == .error .throttled)
    finally release.resolve (.ok ())
    discard <| IO.ofExcept held.get
    discard <| ok (← IO.ofExcept signing.get)
    check "unadmitted burst did not exhaust global login quota" ((← service.login "holder" password).isOk)
    for _ in [:11] do discard <| service.login "throttled" password
    check "credential attempts are rate limited" ((← service.login "throttled" password).map (fun _ => ()) == .error .throttled)
    runtime.drain
    check "auth sessions respect runtime drain" ((← service.session bob2.token).map (fun _ => ()) == .error .unavailable)
    runtime.close
    check "closed runtime refuses authentication" ((← service.session bob2.token).map (fun _ => ()) == .error .unavailable)
  finally runtime.close

/-- LA-07: an authenticated operation on a `lanes` host resolves the session and runs its read
on the reader pool, never entering the writer; a cache hit needs no database work at all. -/
private def lanes : IO Unit := IO.FS.withTempDir fun dir => do
  let inst := LeanDb.Instance.ofPath (dir / "lanes.sqlite")
  let .ok runtime ← LeanAppNative.Runtime.Service.new Auth.Demo.base inst (config := { readers := 1 })
    | throw (IO.userError "runtime")
  let now ← IO.mkRef 1000
  let service ← ok (← Auth.Service.new runtime now.get { sessionCacheTtlMs := 30000 })
  try
    let alice ← ok (← service.signup "lane_alice" password)
    let host ← Auth.Demo.host service "https://example.test"
    let body := "{\"operation\":{\"namespace\":\"auth-demo\",\"name\":\"whoami\",\"version\":\"1\"},\"kind\":\"query\",\"input\":null}"
    let whoami := fun (issued : Auth.Issued) (h : Auth.Host) =>
      h.dispatch (post "/api/whoami" body s!"__Host-leanapp_session={issued.token}" issued.csrf)
    let before ← service.queue
    let reply ← whoami alice host
    let after ← service.queue
    check "lanes: an authenticated query resolves and reads on the pool, never the writer"
      (reply.reply.status == 200 && (reply.reply.body.getObjValAs? String "value").toOption == some "lane_alice" &&
        after.completed == before.completed && after.readersCompleted == before.readersCompleted + 2)
    let again ← whoami alice host
    let cached ← service.queue
    check "lanes: a session cache hit costs only the handler's read"
      (again.reply.status == 200 && cached.readersCompleted == after.readersCompleted + 1 && cached.completed == after.completed)
    check "lanes: wrong CSRF is refused before any lane" ((← host.dispatch (post "/api/whoami" body s!"__Host-leanapp_session={alice.token}" zeros)).reply.status == 403)
    discard <| ok (← service.logout alice.token alice.csrf)
    check "lanes: logout is visible to reader-lane resolution immediately" ((← whoami alice host).reply.status == 401)
    let bob ← ok (← service.signup "lane_bob" password)
    let serial ← Auth.Demo.host service "https://example.test" (serializeRequests := true)
    let before ← service.queue
    let reply ← whoami bob serial
    let after ← service.queue
    check "lanes: serializeRequests keeps the request under one writer admission"
      (reply.reply.status == 200 && after.completed == before.completed + 1 && after.readersCompleted == before.readersCompleted)
    runtime.drain
    check "lanes: a drained runtime is 503 before the handler" ((← whoami bob host).reply.status == 503)
  finally runtime.close

def main : IO Unit := do
  run
  tenantPolicies
  sessions
  sessionCache
  rateLimits
  observability
  lanes
