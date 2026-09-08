import LeanAppNative.Auth.Demo

open LeanAppNative LeanAppNative.Auth LeanApp

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

private def run : IO Unit := IO.FS.withTempDir fun dir => do
  let inst := LeanDb.Instance.ofPath (dir / "auth.sqlite")
  let .ok session ← LeanDb.Cli.Session.open Auth.Demo.base inst | throw (IO.userError "session")
  let runtime ← LeanDb.Runtime.Service.new Auth.Demo.base inst session true
  let now ← IO.mkRef 1000
  let service ← ok (← Auth.Service.new runtime now.get 60)
  let password := "a sufficiently long password 🔐"
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
    let held ← IO.asTask (runtime.database.atomically fun _ => do
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
    IO.ofExcept held.get
    discard <| ok (← IO.ofExcept signing.get)
    check "unadmitted burst did not exhaust global login quota" ((← service.login "holder" password).isOk)
    for _ in [:11] do discard <| service.login "throttled" password
    check "credential attempts are rate limited" ((← service.login "throttled" password).map (fun _ => ()) == .error .throttled)
    runtime.drain
    check "auth sessions respect runtime drain" ((← service.session bob2.token).map (fun _ => ()) == .error .unavailable)
    runtime.close
    check "closed runtime refuses authentication" ((← service.session bob2.token).map (fun _ => ()) == .error .unavailable)
  finally runtime.close

def main : IO Unit := run
