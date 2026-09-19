import LeanAppNative.Auth.Store
import LeanAppNative.Server
import LeanAppNative.Capabilities

namespace LeanAppNative.Auth
open LeanApp Contract Ontology

structure Request where
  method : String
  path : String
  headers : List (String × String) := []
  body : String := ""

structure Response where
  reply : HttpReply
  cookie : Option String := none
  retryAfter : Option Nat := none

private def errorReply (error : Error) : HttpReply :=
  let (status, code) := match error with
    | .invalidUsername => (400, "auth.invalid_username")
    | .invalidPassword => (400, "auth.invalid_password")
    | .usernameUnavailable => (409, "auth.username_unavailable")
    | .invalidCredentials => (401, "auth.invalid_credentials")
    | .unauthenticated => (401, "auth.required")
    | .forbidden => (403, "auth.forbidden")
    | .throttled => (429, "auth.throttled")
    | .unavailable => (503, "auth.unavailable")
    | .internal => (500, "auth.failed")
    | .inviteRequired => (403, "auth.invite_required")
    | .sessionNotFound => (404, "auth.session_not_found")
  ⟨status, .mkObj [("error", .str code)]⟩

private def header (request : Request) (name : String) : Option String :=
  match request.headers.filter (fun pair => pair.1.toLower == name) with
  | [(_, value)] => some value
  | _ => none

structure Host where
  private mk ::
  private auth : Service
  private approved : List PublicOperation
  private codecs : Http.Codecs
  private config : ServerConfig
  private manifest : Lean.Json
  private factory : Factory
  /-- With a `lanes` factory, still run each authenticated request under the writer. -/
  private serializeRequests : Bool
  origin : String
  private development : Bool
  private snapshotFactory : Option (LeanDb.Conn → User → Nat → Nat → IO.Ref Bool → Validation (Application IO))

/-- HTTPS is mandatory except an explicit loopback-only development origin. No forwarded
identity, Host or X-Forwarded-* header is trusted to select origin or issue authority. -/
def Host.create (auth : Service) (template : Server)
    (factory : LeanDb.Conn → Validation (Application IO)) (origin : String)
    (development : Bool := false) : Validation Host := do
  let some uri := Std.Http.URI.parse? origin | Validation.fail "auth.invalid_origin"
  let some authority := uri.authority | Validation.fail "auth.invalid_origin"
  if authority.userInfo.isSome || origin.contains "?" || origin.contains "#" ||
      toString uri.path != "" || (toString authority.host).isEmpty then
    Validation.fail "auth.invalid_origin"
  if development then
    if toString uri.scheme != "http" ||
        !["localhost", "127.0.0.1", "[::1]"].contains (toString authority.host) then
      Validation.fail "auth.development_requires_loopback"
  else if toString uri.scheme != "https" then Validation.fail "auth.https_required"
  let reserved := fun path => path == "/health/ready" || path == "/auth" || path.startsWith "/auth/"
  if reserved template.config.manifestPath || template.app.manifest.any (fun op => reserved op.http.path) then
    Validation.fail "auth.reserved_path_collision"
  pure ⟨auth, template.app.manifest, template.codecs,
    { template.config with failureCode := "application.failed" },
    template.config.manifest template.app.manifest, .serialized factory, true, origin, development, none⟩

/-- LA-07: the factory receives request-scoped lanes. The session resolves from the cache or a
pooled reader (`Service.resolve`), then assembly, policy and handler run outside the writer;
each `write` holds the writer for that one call. `serializeRequests := true` keeps every
request under the writer as `Host.create` does. -/
def Host.createWith (auth : Service) (template : Server)
    (factory : Capabilities → Validation (Application IO)) (origin : String)
    (development : Bool := false) (serializeRequests : Bool := false) : Validation Host := do
  let host ← Host.create auth template (fun _ => .ok template.app) origin development
  pure { host with factory := .lanes factory, serializeRequests }

/-- Additive example host: carries authenticated snapshot facts to application assembly.
The request lease is invalidated before returning from the transaction callback. -/
def Host.createSnapshot (auth : Service) (template : Server)
    (factory : LeanDb.Conn → User → Nat → Nat → IO.Ref Bool → Validation (Application IO))
    (origin : String) (development : Bool := false) : Validation Host := do
  let host ← Host.create auth template (fun _ => .ok template.app) origin development
  pure { host with snapshotFactory := some factory }

private def Host.cookieName (host : Host) : String :=
  if host.development then "leanapp_session" else "__Host-leanapp_session"

private def Host.cookie (host : Host) (token : String) (clear : Bool := false) : String :=
  s!"{host.cookieName}={token}; Path=/; HttpOnly; SameSite=Strict; Max-Age={if clear then 0 else host.auth.ttl}" ++
    (if host.development then "" else "; Secure")

private def Host.sessionToken (host : Host) (request : Request) : Option String := do
  let value ← header request "cookie"
  let fields := value.splitOn ";" |>.map (fun item => item.trimAscii.toString.splitOn "=")
  let [entry] := fields.filter (fun item => item.head? == some host.cookieName) | none
  let [_, token] := entry | none
  if tokenShape token then some token else none

private structure Credentials where
  name : String
  password : String
  invite : Option String := none
  label : Option String := none

/-- Exactly the `required` string fields, plus only the listed `optional` string fields. -/
private def exactFields (body : String) (required : List String) (optional : List String := []) :
    Except Error (List String × (String → Option String)) := do
  let .ok json := Lean.Json.parse body | throw .invalidCredentials
  let .ok fields := json.getObj? | throw .invalidCredentials
  let present := optional.filter fun key => (json.getObjVal? key).isOk
  if fields.size != required.length + present.length then throw .invalidCredentials
  let values ← required.mapM fun key => do
    let .ok value := json.getObjValAs? String key | throw Error.invalidCredentials
    pure value
  let extras ← present.mapM fun key => do
    let .ok value := json.getObjValAs? String key | throw Error.invalidCredentials
    pure (key, value)
  pure (values, fun key => (extras.find? (·.1 == key)).map (·.2))

private def credentials (body : String) (optional : List String := []) : Except Error Credentials := do
  let ([name, password], field) ← exactFields body ["username", "password"] ("label" :: optional)
    | throw .invalidCredentials
  pure ⟨name, password, field "invite", field "label"⟩

private def sessionBody (user : User) (csrf : String) : Lean.Json :=
  .mkObj [("user", user.toJson), ("csrf", .str csrf)]

private def Host.issued (host : Host) (result : Except Error Issued) : Response :=
  match result with
  | .error e => ⟨errorReply e, none, none⟩
  | .ok session => ⟨⟨200, sessionBody session.user session.csrf⟩, some (host.cookie session.token), none⟩

/-- Loopback-only operator endpoint: counters plus live writer-queue and session-cache gauges. -/
def Host.metrics (host : Host) : IO String := do
  let queue ← host.auth.queue
  let cache ← host.auth.cacheStats
  Metrics.render [("leanapp_writer_queue_depth", queue.queued), ("leanapp_writer_active", queue.active),
    ("leanapp_writer_completed_total", queue.completed),
    ("leanapp_reader_active", queue.readersActive), ("leanapp_reader_completed_total", queue.readersCompleted),
    ("leanapp_reader_pool_size", host.auth.database.readers),
    ("leanapp_auth_session_cache_hits_total", cache.hits), ("leanapp_auth_session_cache_misses_total", cache.misses),
    ("leanapp_auth_session_cache_invalidations_total", cache.invalidations), ("leanapp_auth_session_cache_size", cache.size)]

/-- LA-07 authenticated request path: the principal resolves from the cache or a pooled reader
(`Service.resolve`); assembly, policy and handler then run outside the writer and acquire a
lane per call. Denied admission never reaches the factory or a handler; a refusal that lands
mid-request is answered 503 by `Server.dispatch`. -/
private def Host.lanesRequest (host : Host) (assemble : Capabilities → Validation (Application IO))
    (token csrf requestId : String) (trace : Log.TraceRef)
    (dispatch : Nat → RequestContext → Application IO → IO Response) : IO (Except Error Response) := do
  match ← host.auth.resolve token (some csrf) requestId (trace := trace) with
  | .error e => return .error e
  | .ok (context, _) =>
    unless ← host.auth.ready do
      trace.update fun t => { t with outcome := some .unavailable }
      return .error .unavailable
    let clock ← LaneClock.new
    let .ok app := assemble (Capabilities.request host.auth.database clock)
      | return .ok ⟨errorReply .internal, none, none⟩
    let response ← dispatch (← IO.monoMsNow) context app
    clock.settle trace
    return .ok response

/-- The optional trace collects the request id, operation, principal hash, phase timings and
outcome for the request line written by `Host.handler`. -/
def Host.dispatch (host : Host) (request : Request) (trace : Log.TraceRef := none) : IO Response := do
  let requestId ← match trace with
    | some ref => do
      let current := (← ref.get).requestId
      if current.isEmpty then Log.requestId (header request "x-request-id") else pure current
    | none => Log.requestId (header request "x-request-id")
  trace.update fun t => { t with requestId }
  try
    if request.path == "/health/ready" && request.method == "GET" then
      let ready ← host.auth.ready
      return ⟨⟨if ready then 200 else 503, .mkObj [("ready", .bool ready)]⟩, none, none⟩
    if request.path == host.config.manifestPath && request.method == "GET" then
      return ⟨⟨200, host.manifest⟩, none, none⟩
    if request.body.utf8ByteSize > bodyLimitFor host.approved host.config request.path then
      return ⟨⟨413, Http.protocolResponse "request.body_too_large"⟩, none, none⟩
    -- Custom header plus no CORS support protects even pre-login JSON endpoints.
    -- Authenticated POSTs additionally require the unpredictable session CSRF token.
    if header request "x-leanapp-request" != some "1" then return ⟨errorReply .forbidden, none, none⟩
    if request.method == "POST" then
      if header request "origin" != some host.origin ||
          ((header request "content-type").map (fun v => (v.splitOn ";").head!.trimAscii.toString.toLower)) != some "application/json" then
        return ⟨errorReply .forbidden, none, none⟩
    else if let some origin := header request "origin" then
      if origin != host.origin then return ⟨errorReply .forbidden, none, none⟩
    if request.path == "/auth/signup" || request.path == "/auth/login" then
      if request.method != "POST" then return ⟨⟨405, Http.protocolResponse "method.not_allowed"⟩, none, none⟩
      if request.body.utf8ByteSize > 4096 then return ⟨⟨413, Http.protocolResponse "request.body_too_large"⟩, none, none⟩
      let signup := request.path == "/auth/signup"
      let optional := if signup && host.auth.config.tenantPolicy == .invite then ["invite"] else []
      let .ok input := credentials request.body optional | return ⟨errorReply .invalidCredentials, none, none⟩
      let started ← IO.monoMsNow
      let issued ← if signup then host.auth.signup input.name input.password input.invite input.label
        else host.auth.login input.name input.password input.label
      trace.phase (fun t n => { t with auth := t.auth + n }) started
      if let .ok session := issued then
        trace.update fun t => { t with principalHash := some (Log.principalHash session.user.actor) }
      return host.issued issued
    let some token := host.sessionToken request | return ⟨errorReply .unauthenticated, none, none⟩
    if request.path == "/auth/session" then
      if request.method != "GET" then return ⟨⟨405, Http.protocolResponse "method.not_allowed"⟩, none, none⟩
      match ← host.auth.session token with
      | .ok (user, csrf) => return ⟨⟨200, sessionBody user csrf⟩, none, none⟩
      | .error e => return ⟨errorReply e, none, none⟩
    let csrf := (header request "x-csrf-token").getD ""
    if ["/auth/logout", "/auth/logout-all", "/auth/sessions", "/auth/sessions/revoke", "/auth/password"].contains request.path then
      if request.method != "POST" then return ⟨⟨405, Http.protocolResponse "method.not_allowed"⟩, none, none⟩
      if request.body.utf8ByteSize > 4096 then return ⟨⟨413, Http.protocolResponse "request.body_too_large"⟩, none, none⟩
    let cleared := some (host.cookie "" true)
    if request.path == "/auth/logout" then
      match ← host.auth.logout token csrf with
      | .ok () => return ⟨⟨200, .mkObj [("ok", .bool true)]⟩, cleared, none⟩
      | .error e => return ⟨errorReply e, none, none⟩
    if request.path == "/auth/logout-all" then
      match ← host.auth.logoutAll token csrf with
      | .ok () => return ⟨⟨200, .mkObj [("ok", .bool true)]⟩, cleared, none⟩
      | .error e => return ⟨errorReply e, none, none⟩
    if request.path == "/auth/sessions" then
      match ← host.auth.sessions token csrf with
      | .ok sessions => return ⟨⟨200, .mkObj [("sessions", .arr (sessions.map (·.toJson)).toArray)]⟩, none, none⟩
      | .error e => return ⟨errorReply e, none, none⟩
    if request.path == "/auth/sessions/revoke" then
      let .ok ([id], _) := exactFields request.body ["id"] | return ⟨errorReply .sessionNotFound, none, none⟩
      match ← host.auth.revokeSession token csrf id with
      | .ok current => return ⟨⟨200, .mkObj [("ok", .bool true), ("current", .bool current)]⟩, if current then cleared else none, none⟩
      | .error e => return ⟨errorReply e, none, none⟩
    if request.path == "/auth/password" then
      let .ok ([current, next], _) := exactFields request.body ["currentPassword", "newPassword"]
        | return ⟨errorReply .invalidCredentials, none, none⟩
      let started ← IO.monoMsNow
      let issued ← host.auth.changePassword token csrf current next
      trace.phase (fun t n => { t with auth := t.auth + n }) started
      if let .ok session := issued then
        trace.update fun t => { t with principalHash := some (Log.principalHash session.user.actor) }
      return host.issued issued
    -- Declared per-principal limits are enforced after authentication and before the handler;
    -- anonymous traffic is the gateway's business. The limiter state never enters the DB queue.
    let limited := fun (context : RequestContext) => do
      let some limit := (host.approved.find? (·.http.path == request.path)).bind (·.http.rateLimit) | return none
      let some principal := context.principal | return none
      host.auth.admitRate principal.actor request.path limit
    let dispatch := fun (entered : Nat) (context : RequestContext) (app : Application IO) => do
      trace.principal context
      let assembled := trace.phase (fun t n => { t with db := t.db + n }) entered
      if app.manifest != host.approved then assembled; return (⟨errorReply .internal, none, none⟩ : Response)
      if let some retryAfter ← limited context then
        assembled
        Metrics.countRateLimited
        return ⟨⟨429, Http.protocolResponse "request.rate_limited"⟩, none, some retryAfter⟩
      let .ok server := Server.create app host.codecs host.config | assembled; return ⟨errorReply .internal, none, none⟩
      assembled
      return ⟨← server.dispatch context request.method request.path request.body trace, none, none⟩
    let serialized := fun (assemble : LeanDb.Conn → Validation (Application IO)) =>
      host.auth.withAuthenticated token (some csrf) requestId (trace := trace) fun conn context _ => do
        let entered ← IO.monoMsNow
        let .ok app := assemble conn | return ⟨errorReply .internal, none, none⟩
        dispatch entered context app
    let result ← match host.snapshotFactory, host.factory with
      | some factory, _ => host.auth.withAuthenticatedTransaction token csrf requestId (trace := trace) <|
          fun conn context user now expiresAt => do
            let entered ← IO.monoMsNow
            let alive ← IO.mkRef true
            try
              let .ok app := factory conn user now expiresAt alive | return ⟨errorReply .internal, none, none⟩
              dispatch entered context app
            finally alive.set false
      | none, .serialized assemble => serialized assemble
      | none, .lanes assemble =>
        if host.serializeRequests then serialized (fun conn => assemble (Capabilities.held conn))
        else host.lanesRequest assemble token csrf requestId trace dispatch
    return match result with | .ok response => response | .error e => ⟨errorReply e, none, none⟩
  catch e =>
    trace.failure "auth-host" "auth.failed" e
    return ⟨errorReply .internal, none, none⟩

private def respond (response : Response) : Std.Async.ContextAsync (Std.Http.Response Std.Http.Body.Any) := do
  let status := (Std.Http.Status.ofCode none response.reply.status.toUInt16).getD .internalServerError
  let base ← (Std.Http.Response.withStatus status).json response.reply.body.compress
  let mut headers := base.line.headers
  for (name, value) in [("cache-control", "no-store"), ("x-content-type-options", "nosniff")] do
    headers := headers.insert (Std.Http.Header.Name.ofString! name) (Std.Http.Header.Value.ofString! value)
  if let some cookie := response.cookie then
    headers := headers.insert (Std.Http.Header.Name.ofString! "set-cookie") (Std.Http.Header.Value.ofString! cookie)
  if let some seconds := response.retryAfter then
    headers := headers.insert (Std.Http.Header.Name.ofString! "retry-after") (Std.Http.Header.Value.ofString! (toString seconds))
  pure { line := { base.line with headers }, body := Std.Http.Body.Any.ofBody base.body, extensions := base.extensions }

private def isLoopback : Std.Net.SocketAddress → Bool
  | .v4 addr => addr.addr == Std.Net.IPv4Addr.ofParts 127 0 0 1
  | .v6 addr => toString addr.addr == "::1"

private def metricsResponse (host : Host) : Std.Async.ContextAsync (Std.Http.Response Std.Http.Body.Any) := do
  let base ← (Std.Http.Response.withStatus .ok).text (← host.metrics)
  let headers := base.line.headers.insert (Std.Http.Header.Name.ofString! "cache-control") (Std.Http.Header.Value.ofString! "no-store")
  pure { line := { base.line with headers }, body := Std.Http.Body.Any.ofBody base.body, extensions := base.extensions }

/-- `GET /internal/metrics` is answered only for loopback peers and never proxied by the gateway;
every other request is dispatched off the event loop and logged as one JSON line. -/
def Host.handler (host : Host) (request : Std.Http.Request Std.Http.Body.Stream) :
    Std.Async.ContextAsync (Std.Http.Response Std.Http.Body.Any) := do
  let started ← IO.monoMsNow
  let path := literalPath request.line.uri
  let method := toString request.line.method
  let trace ← IO.mkRef ({ requestId := ← Log.requestId (requestHeader request "x-request-id") } : Log.Trace)
  let finish := fun (response : Response) (bodyBytes : Nat) => do
    logRequest trace method path response.reply.status started bodyBytes response.reply.body.compress.utf8ByteSize
    respond response
  if path == "/internal/metrics" && method == "GET" then
    let peer := (request.extensions.get Std.Http.Server.RemoteAddr).map (·.addr)
    -- Loopback scrapes are not logged; a refused scrape is, since it names an unexpected peer.
    if peer.any isLoopback then return ← metricsResponse host
    return ← finish ⟨⟨404, Http.protocolResponse "route.not_found"⟩, none, none⟩ 0
  let bytes ← try Std.Http.Body.Stream.readAll request.body (some (bodyLimitFor host.approved host.config path).toUInt64)
    catch _ => return ← finish ⟨⟨413, Http.protocolResponse "request.body_too_large"⟩, none, none⟩ 0
  let some body := String.fromUTF8? bytes | return ← finish ⟨errorReply .invalidCredentials, none, none⟩ bytes.size
  let input : Request := ⟨method, path,
    request.line.headers.toList.map (fun (name, value) => (toString name, toString value)), body⟩
  let task ← IO.asTask (host.dispatch input (some trace)) (prio := .dedicated)
  finish (← Std.Async.Async.ofAsyncTask task) bytes.size

/-- TLS must terminate at a configured trusted ingress. Development is loopback-only. -/
def Host.serve (host : Host) (address : Std.Net.SocketAddress) : Std.Async.Async Std.Http.Server := do
  if host.development && !isLoopback address then throw (IO.userError "development auth requires loopback binding")
  Std.Http.Server.serve address (Std.Http.Server.Handler.ofFn (host.handler ·))
    { generateDate := false, maxBodySize := wireBodyLimitFor host.approved host.config
      maxConnections := host.config.maxConnections }

end LeanAppNative.Auth
