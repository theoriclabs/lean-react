import LeanApp
import LeanDb.Runtime
import LeanDb.Derive
import LeanAppNative.Auth.Crypto
import LeanAppNative.Metrics
import Std.Time

namespace LeanAppNative.Auth
open LeanDb LeanApp

inductive Error where
  | invalidUsername | invalidPassword | usernameUnavailable | invalidCredentials
  | unauthenticated | forbidden | throttled | unavailable | internal | inviteRequired
  | sessionNotFound
  deriving BEq, Repr

/-- How signup assigns a tenant. `.fixed` lets any signup share the workspace, so pair it with
ingress abuse controls; `.invite` admits only holders of a token issued by trusted native code. -/
inductive TenantPolicy where
  | privatePerAccount
  | fixed (tenant : String)
  | invite
  deriving Repr, BEq

/-- `maxSessions := 1` keeps one session per account and lets login bump the generation, as before.
With more, login only evicts the oldest sessions beyond the cap; the generation stays the
revoke-everything switch (password change, logout-all, `setAccess`). -/
structure Service.Config where
  ttl : Nat := 86400
  tenantPolicy : TenantPolicy := .privatePerAccount
  maxSessions : Nat := 1
  sessionLabel : Bool := true
  /-- Session cache lifetime in milliseconds; 0 disables it. 30 s is the recommended setting. -/
  sessionCacheTtlMs : Nat := 0
  sessionCacheMax : Nat := 10000
  deriving Repr

def username (input : String) : Except Error String := do
  if input.length < 3 || input.length > 32 ||
      !input.toList.all (fun c => c.toNat < 128 && (c.isAlphanum || c == '_' || c == '-')) then
    throw .invalidUsername
  pure input.toLower

/-- Passwords are never trimmed or normalized. No composition rules or silent truncation. -/
def validPassword (input : String) : Bool :=
  input.length ≥ 15 && input.length ≤ 128 && input.utf8ByteSize ≤ 1024

def tokenShape (input : String) : Bool := input.length == 64 &&
  input.toList.all (fun c => ('0' ≤ c && c ≤ '9') || ('a' ≤ c && c ≤ 'f'))

/-- Native-only storage records. Never register these as public CRUD tables. -/
structure Account where
  username : String
  passwordHash : String
  actor : String
  tenant : String
  generation : Int64
  enabled : Bool
  deriving LeanDb.Entity

/-- The three trailing columns are `Option` so an existing instance migrates additively. -/
structure Session where
  tokenDigest : String
  csrf : String
  actor : String
  generation : Int64
  expiresAt : Int64
  createdAt : Option Int64
  lastSeenAt : Option Int64
  label : Option String
  deriving LeanDb.Entity

/-- Single-use signup invitation under `TenantPolicy.invite`. Only the token digest is stored. -/
structure Invite where
  tokenDigest : String
  tenant : String
  role : Option String
  expiresAt : Int64
  usedBy : Option String
  deriving LeanDb.Entity

/-- Include these in the authoritative Base so schema drift remains managed. -/
def tables : List CliTable := [.of Account, .of Session, .of Invite]

structure User where
  username : String
  actor : String
  tenant : String
  generation : Nat
  deriving BEq, Repr

def User.toJson (user : User) : Lean.Json := .mkObj [
  ("username", .str user.username), ("actor", .str user.actor),
  ("tenant", .str user.tenant), ("generation", .str (toString user.generation))]

/-- Returned only to the native HTTP adapter. Do not log or serialize the bearer token. -/
structure Issued where
  token : String
  csrf : String
  user : User

/-- Public view of one session. `id` is a salted digest, never the bearer digest. -/
structure SessionInfo where
  id : String
  label : Option String
  createdAt : Option Nat
  lastSeenAt : Option Nat
  current : Bool
  deriving BEq, Repr, Inhabited

def SessionInfo.toJson (info : SessionInfo) : Lean.Json :=
  let stamp := fun (value : Option Nat) => (value.map fun n => Lean.Json.str (toString n)).getD .null
  .mkObj [("id", .str info.id), ("label", (info.label.map .str).getD .null),
    ("createdAt", stamp info.createdAt), ("lastSeenAt", stamp info.lastSeenAt), ("current", .bool info.current)]

private structure Throttle where
  window : Nat := 0
  total : Nat := 0
  names : List (String × Nat) := []

/-- A resolved session keyed by token digest. `cachedAt` is monotonic milliseconds; `expiresAt`
is the session's own expiry in clock seconds and is rechecked on every hit. -/
private structure CacheEntry where
  user : User
  csrf : String
  expiresAt : Nat
  cachedAt : Nat

/-- Process-local; every event that changes session validity happens in this process. -/
private structure Cache where
  entries : Std.HashMap String CacheEntry := {}
  actors : Std.HashMap String (List String) := {}
  hits : Nat := 0
  misses : Nat := 0
  invalidations : Nat := 0

/-- Socket hosts subscribe so a logout or generation bump can close live sessions. -/
inductive InvalidationEvent where
  | digest (tokenDigest : String)
  | actor (actor : String)
  deriving Repr, BEq

structure CacheStats where
  hits : Nat
  misses : Nat
  invalidations : Nat
  size : Nat
  deriving Repr, BEq

/-- Token bucket in sixtieths of a token, so a per-minute rate refills whole units per second. -/
private structure Bucket where
  level : Nat
  updatedAt : Nat

structure Service where
  private mk ::
  private runtime : Runtime.Service
  private dummyHash : String
  private kdf : Std.BaseMutex
  private throttle : Std.Mutex Throttle
  private cache : Std.Mutex Cache
  private buckets : Std.Mutex (Std.HashMap String Bucket)
  private invalidation : Std.Mutex (Array (InvalidationEvent → IO Unit))
  private clock : IO Nat
  config : Service.Config

def Service.ttl (service : Service) : Nat := service.config.ttl

def wallSeconds : IO Nat := do
  return (← Std.Time.Timestamp.now).toMillisecondsSinceUnixEpoch.toInt.toNat / 1000

private def runDb (conn : Conn) (action : DbM α) : IO (Except Error α) := do
  match ← DbM.run conn action with
  | .ok value => return .ok value
  | .error _ => return .error .internal

private def admitted (service : Service) (action : Conn → IO (Except Error α)) : IO (Except Error α) := do
  match ← service.runtime.withConnection action with
  | .ok result => return result
  | .error (.host _) => return .error .internal
  | .error _ => return .error .unavailable

private def flatten (result : Except Error (Except Error α)) : Except Error α := result.bind id

private def accountByName (name : String) : DbM (Option (Stored Account)) := do
  return (← selectP [Account] (.eq (.here Account.Field.username) .eq name))[0]?

private def accountByActor (actor : String) : DbM (Option (Stored Account)) := do
  return (← selectP [Account] (.eq (.here Account.Field.actor) .eq actor))[0]?

private def sessionByDigest (digest : String) : DbM (Option (Stored Session)) := do
  return (← selectP [Session] (.eq (.here Session.Field.tokenDigest) .eq digest))[0]?

private def inviteByDigest (digest : String) : DbM (Option (Stored Invite)) := do
  return (← selectP [Invite] (.eq (.here Invite.Field.tokenDigest) .eq digest))[0]?

private def userOf (account : Account) : User :=
  ⟨account.username, account.actor, account.tenant, account.generation.toInt.toNat⟩

private def validTenant (tenant : String) : Bool := !tenant.isEmpty && tenant.length ≤ 64

def Service.new (runtime : Runtime.Service) (clock : IO Nat := wallSeconds)
    (config : Service.Config := {}) : IO (Except Error Service) := do
  if config.ttl == 0 || config.ttl > 604800 || config.maxSessions == 0 then return .error .internal
  if let .fixed tenant := config.tenantPolicy then
    unless validTenant tenant do return .error .internal
  try
    let dummy ← Crypto.hashPassword "leanapp-unknown-user-dummy-password"
    let service := Service.mk runtime dummy (← Std.BaseMutex.new) (← Std.Mutex.new {}) (← Std.Mutex.new {})
      (← Std.Mutex.new {}) (← Std.Mutex.new #[]) clock config
    let result ← admitted service fun conn => runDb conn <| withTransaction do
      untrackedSqlite fun db => do
        db.exec s!"CREATE UNIQUE INDEX IF NOT EXISTS leanapp_auth_username ON {quoteIdent (Entity.tableName Account)} (username)"
        db.exec s!"CREATE UNIQUE INDEX IF NOT EXISTS leanapp_auth_actor ON {quoteIdent (Entity.tableName Account)} (actor)"
        db.exec s!"CREATE UNIQUE INDEX IF NOT EXISTS leanapp_auth_session ON {quoteIdent (Entity.tableName Session)} (tokenDigest)"
        db.exec s!"CREATE UNIQUE INDEX IF NOT EXISTS leanapp_auth_invite ON {quoteIdent (Entity.tableName Invite)} (tokenDigest)"
    return result.map (fun _ => service)
  catch _ => return .error .internal

private def Cache.remove (cache : Cache) (digests : List String) : Cache := Id.run do
  let mut entries := cache.entries
  let mut actors := cache.actors
  let mut removed := 0
  for digest in digests do
    if let some entry := entries.get? digest then
      entries := entries.erase digest
      removed := removed + 1
      let rest := (actors.getD entry.user.actor []).filter (· != digest)
      actors := if rest.isEmpty then actors.erase entry.user.actor else actors.insert entry.user.actor rest
  { cache with entries, actors, invalidations := cache.invalidations + removed }

/-- The cache is consulted only when enabled; a stale or expired entry counts as a miss. -/
private def Service.cacheLookup (service : Service) (digest : String) : IO (Option CacheEntry) := do
  let ttl := service.config.sessionCacheTtlMs
  if ttl == 0 then return none
  let nowMs ← IO.monoMsNow
  let now ← service.clock
  service.cache.atomically fun ref => do
    let cache ← ref.get
    match cache.entries.get? digest with
    | some entry =>
      if nowMs < entry.cachedAt + ttl && now < entry.expiresAt then
        ref.set { cache with hits := cache.hits + 1 }
        return some entry
      ref.set { cache.remove [digest] with misses := cache.misses + 1 }
      return none
    | none =>
      ref.set { cache with misses := cache.misses + 1 }
      return none

private def Service.emitInvalidation (service : Service) (event : InvalidationEvent) : IO Unit := do
  let cbs ← service.invalidation.atomically fun ref => ref.get
  for cb in cbs do
    try cb event catch _ => pure ()

/-- Channel hosts register here; logout, revocation and generation bumps notify every listener. -/
def Service.onInvalidation (service : Service) (callback : InvalidationEvent → IO Unit) : IO Unit :=
  service.invalidation.atomically fun ref => ref.modify (·.push callback)

/-- Bounded by `sessionCacheMax`: a full cache is cleared rather than evicted selectively. -/
private def Service.cacheStore (service : Service) (digest : String) (entry : CacheEntry) : IO Unit := do
  if service.config.sessionCacheTtlMs == 0 then return
  service.cache.atomically fun ref => do
    let cache ← ref.get
    let cache := if cache.entries.size ≥ service.config.sessionCacheMax then { cache with entries := {}, actors := {} } else cache
    let owned := digest :: (cache.actors.getD entry.user.actor []).filter (· != digest)
    ref.set { cache with entries := cache.entries.insert digest entry, actors := cache.actors.insert entry.user.actor owned }

private def Service.cacheEvict (service : Service) (digests : List String) : IO Unit := do
  for d in digests do service.emitInvalidation (.digest d)
  if service.config.sessionCacheTtlMs == 0 || digests.isEmpty then return
  service.cache.atomically fun ref => ref.modify (·.remove digests)

private def Service.cacheEvictActor (service : Service) (actor : String) : IO Unit := do
  service.emitInvalidation (.actor actor)
  if service.config.sessionCacheTtlMs == 0 then return
  service.cache.atomically fun ref => do
    let cache ← ref.get
    ref.set (cache.remove (cache.actors.getD actor []))

def Service.cacheStats (service : Service) : IO CacheStats :=
  service.cache.atomically fun ref => do
    let cache ← ref.get
    return ⟨cache.hits, cache.misses, cache.invalidations, cache.entries.size⟩

/-- Per-(principal, operation) token bucket for a binding's declared `RateLimit`. Returns the
`Retry-After` seconds when the request is refused. Process-local like the credential throttles;
the service clock has second resolution, so refills land in whole seconds. -/
def Service.admitRate (service : Service) (actor path : String) (limit : RateLimit) : IO (Option Nat) := do
  let now ← service.clock
  let capacity := max limit.burst 1 * 60
  service.buckets.atomically fun ref => do
    let buckets ← ref.get
    let buckets := if buckets.size ≥ 100000 then {} else buckets
    let key := actor ++ "\n" ++ path
    let bucket := (buckets.get? key).getD ⟨capacity, now⟩
    let level := min capacity (bucket.level + (now - bucket.updatedAt) * limit.perPrincipalPerMinute)
    if level ≥ 60 then
      ref.set (buckets.insert key ⟨level - 60, now⟩)
      return none
    ref.set (buckets.insert key ⟨level, now⟩)
    let rate := limit.perPrincipalPerMinute
    return some (if rate == 0 then 60 else max 1 ((60 - level + rate - 1) / rate))

/-- One KDF at a time, no waiting queue. Throttles are bounded, process-local defense;
deployments also need ingress/IP limits. Restart does not preserve these counters. -/
private def withPasswordWork (service : Service) (name : String)
    (action : IO (Except Error α)) : IO (Except Error α) := do
  unless ← service.kdf.tryLock do
    Metrics.countAuthThrottle
    return .error .throttled
  try
    let now ← IO.monoMsNow
    let allowed ← service.throttle.atomically fun ref => do
      let old ← ref.get
      let state : Throttle := if now ≥ old.window + 60000 then { window := now } else old
      let count := ((state.names.find? (·.1 == name)).map (·.2)).getD 0
      if state.total ≥ 60 || count ≥ 10 then return false
      ref.set { state with
        total := state.total + 1
        names := (name, count + 1) :: state.names.filter (·.1 != name) }
      return true
    unless allowed do
      Metrics.countAuthThrottle
      return .error .throttled
    action
  catch _ => return .error .internal
  finally service.kdf.unlock

private def deleteSessions (actor : String) : DbM Unit :=
  untrackedSqlite fun db => do
    let stmt ← db.prepare s!"DELETE FROM {quoteIdent (Entity.tableName Session)} WHERE actor = ?"
    stmt.bindText 1 actor
    discard stmt.step

private def deleteSession (digest : String) : DbM Unit :=
  untrackedSqlite fun db => do
    let stmt ← db.prepare s!"DELETE FROM {quoteIdent (Entity.tableName Session)} WHERE tokenDigest = ?"
    stmt.bindText 1 digest
    discard stmt.step

private def sessionsByActor (actor : String) : DbM (Array (Stored Session)) :=
  selectP [Session] (.eq (.here Session.Field.actor) .eq actor)

private def createdAt (session : Stored Session) : Int :=
  (session.val.createdAt.map (·.toInt)).getD 0

/-- Client-supplied device label: printable ASCII only, trimmed, at most 64 characters. -/
def sanitizeLabel (label : Option String) : Option String := do
  let clean := (String.ofList ((← label).toList.filter fun c => ' ' ≤ c && c ≤ '~')).trimAscii.toString
  if clean.isEmpty then none else some (clean.take 64).toString

/-- The public session id: a digest salted with the session's own CSRF secret, so it neither equals
nor reveals the stored bearer digest. Legacy rows without new columns get an id the same way. -/
def sessionId (session : Session) : IO String :=
  Crypto.digestToken (session.tokenDigest ++ "." ++ session.csrf)

/-- Keep the newest `maxSessions - 1` sessions by `createdAt`, evict the rest, insert the new one.
Returns the evicted digests so a caller can invalidate caches. -/
private def addSession (service : Service) (account : Account)
    (digest csrf : String) (now : Nat) (label : Option String := none) : DbM (List String) := do
  if now + service.ttl > 9223372036854775807 then throw (.sqlite "invalid authentication clock")
  let existing ← sessionsByActor account.actor
  let ordered := existing.qsort fun a b => createdAt a > createdAt b ||
    (createdAt a == createdAt b && a.id.toInt64.toInt > b.id.toInt64.toInt)
  let evicted := (ordered.toList.drop (service.config.maxSessions - 1)).map (·.val.tokenDigest)
  for old in evicted do deleteSession old
  let label := if service.config.sessionLabel then sanitizeLabel label else none
  discard <| insert Session ⟨digest, csrf, account.actor, account.generation, Int64.ofInt (now + service.ttl),
    some (Int64.ofNat now), some (Int64.ofNat now), label⟩
  return evicted

/-- Trusted native issuance only; there is no public endpoint. The token is returned once. -/
def Service.createInvite (service : Service) (tenant : String) (ttl : Nat)
    (role : Option String := none) : IO (Except Error String) := do
  unless validTenant tenant && ttl > 0 do return .error .internal
  try
    let token ← Crypto.randomToken
    let digest ← Crypto.digestToken token
    let result ← admitted service fun conn => do
      let now ← service.clock
      if now + ttl > 9223372036854775807 then return .error .internal
      runDb conn <| withTransaction do
        discard <| insert Invite ⟨digest, tenant, role, Int64.ofInt (now + ttl), none⟩
    return result.map fun _ => token
  catch _ => return .error .internal

/-- Tenant assignment runs inside the signup transaction, so an invite is spent at most once and an
aborted signup (name taken) leaves it unused. Checked before name availability: without a valid
invite, signup reveals nothing about existing usernames. -/
private def assignTenant (service : Service) (actor : String) (inviteDigest : Option String)
    (now : Nat) : DbM (Except Error String) := do
  match service.config.tenantPolicy, inviteDigest with
  | .privatePerAccount, _ => return .ok actor
  | .fixed tenant, _ => return .ok tenant
  | .invite, none => return .error .inviteRequired
  | .invite, some digest =>
    let some stored ← inviteByDigest digest | return .error .inviteRequired
    if stored.val.usedBy.isSome || stored.val.expiresAt.toInt ≤ now then return .error .inviteRequired
    discard <| update stored { stored.val with usedBy := some actor }
    return .ok stored.val.tenant

/-- `invite` is accepted only under `TenantPolicy.invite`; malformed or missing tokens fail before
password work so they cannot spend the KDF budget. -/
def Service.signup (service : Service) (input password : String)
    (invite : Option String := none) (label : Option String := none) : IO (Except Error Issued) := do
  let .ok name := username input | return .error .invalidUsername
  unless validPassword password do return .error .invalidPassword
  let inviteDigest ← match service.config.tenantPolicy, invite with
    | .invite, some token =>
      unless tokenShape token do return .error .inviteRequired
      some <$> Crypto.digestToken token
    | .invite, none => return .error .inviteRequired
    | _, none => pure none
    | _, some _ => return .error .invalidCredentials
  withPasswordWork service name do
    let hash ← Crypto.hashPassword password
    let actor ← Crypto.randomToken
    let token ← Crypto.randomToken
    let csrf ← Crypto.randomToken
    let digest ← Crypto.digestToken token
    let result ← admitted service fun conn => do
      let now ← service.clock
      runDb conn <| transaction do
        let tenant ← match ← assignTenant service actor inviteDigest now with
          | .ok tenant => pure tenant
          | .error e => return .abort e
        if (← accountByName name).isSome then return .abort Error.usernameUnavailable
        let account : Account := ⟨name, hash, actor, tenant, 1, true⟩
        discard <| insert Account account
        discard <| addSession service account digest csrf now label
        return .commit (Issued.mk token csrf (userOf account))
    return flatten result

/-- Verify a password for a stored account outside the database lock, then run `issue` under one
admitted transaction against the rechecked account row. Unknown names cost one dummy KDF. -/
private def verifiedThen (service : Service) (name password : String)
    (issue : Stored Account → Nat → DbM (TransactionDecision Error β)) : IO (Except Error β) := do
  let loaded ← admitted service fun conn => runDb conn (accountByName name)
  let candidate ← match loaded with
    | .ok candidate => pure candidate
    | .error e => return .error e
  let hash := (candidate.map (·.val.passwordHash)).getD service.dummyHash
  let verified ← Crypto.verifyPassword password hash
  let some old := candidate | return .error .invalidCredentials
  unless verified do return .error .invalidCredentials
  let result ← admitted service fun conn => do
    let now ← service.clock
    runDb conn <| transaction do
      let some current ← accountByActor old.val.actor | return .abort Error.invalidCredentials
      if !current.val.enabled || current.val.passwordHash != hash ||
          current.val.generation.toInt < 0 || current.val.generation.toInt ≥ 9223372036854775807 then
        return .abort Error.invalidCredentials
      issue current now
  return flatten result

/-- With one allowed session, login replaces it and bumps the generation. Otherwise it evicts only
sessions beyond the cap. Account state is rechecked after the KDF inside the issuing transaction. -/
def Service.login (service : Service) (input password : String)
    (label : Option String := none) : IO (Except Error Issued) := do
  let .ok name := username input | return .error .invalidCredentials
  unless validPassword password do return .error .invalidCredentials
  withPasswordWork service name do
    let token ← Crypto.randomToken
    let csrf ← Crypto.randomToken
    let digest ← Crypto.digestToken token
    let issued ← verifiedThen service name password fun current now => do
      let next := if service.config.maxSessions == 1
        then { current.val with generation := current.val.generation + 1 } else current.val
      if service.config.maxSessions == 1 then discard <| update current next
      let evicted ← addSession service next digest csrf now label
      return .commit (Issued.mk token csrf (userOf next), evicted)
    let .ok (issued, evicted) := issued | return issued.map (·.1)
    -- A generation bump invalidates every cached session of the actor; otherwise only the evicted.
    if service.config.maxSessions == 1 then service.cacheEvictActor issued.user.actor else service.cacheEvict evicted
    return .ok issued

/-- `lastSeenAt` is refreshed at most once per five minutes to avoid a write per request. -/
private def touchSession (session : Stored Session) (now : Nat) : DbM Unit := do
  let seen : Int := (session.val.lastSeenAt.map (·.toInt)).getD 0
  if seen + 300 ≤ (now : Int) then
    untrackedSqlite fun db => do
      let stmt ← db.prepare s!"UPDATE {quoteIdent (Entity.tableName Session)} SET lastSeenAt = ? WHERE tokenDigest = ?"
      stmt.bindInt64 1 (Int64.ofNat now)
      stmt.bindText 2 session.val.tokenDigest
      discard stmt.step

private def resolveSession (digest : String) (now : Nat) : DbM (Except Error (Stored Session × User)) := do
  let some session ← sessionByDigest digest | return .error .unauthenticated
  let some account ← accountByActor session.val.actor | return .error .unauthenticated
  if !account.val.enabled || session.val.expiresAt.toInt ≤ now ||
      account.val.generation != session.val.generation || account.val.generation.toInt < 0 then
    return .error .unauthenticated
  touchSession session now
  return .ok (session, userOf account.val)

private def csrfAccepted (csrf : Option String) (expected : String) : IO Bool := do
  let some supplied := csrf | return true
  return tokenShape supplied && (← Crypto.constantTimeEqual supplied expected)

/-- Verification, current membership and application policy execute within one admitted
callback. Trusted callback must not retain conn or recursively enter this service.
A session cache hit skips the database work of the authentication step only; the callback still
runs under `withConnection`. Cache entries are only ever written inside that same queue, so an
invalidation issued after a committed change removes every entry that predates it. -/
def Service.withAuthenticated (service : Service) (token : String) (csrf : Option String)
    (requestId : String) (action : Conn → RequestContext → User → IO α)
    (trace : Log.TraceRef := none) : IO (Except Error α) := do
  unless tokenShape token do return .error .unauthenticated
  try
    let started ← IO.monoMsNow
    let auth := fun (t : Log.Timings) (n : Nat) => { t with auth := t.auth + n }
    let queue := fun (t : Log.Timings) (n : Nat) => { t with queueWait := t.queueWait + n }
    let digest ← Crypto.digestToken token
    if let some entry ← service.cacheLookup digest then
      unless ← csrfAccepted csrf entry.csrf do return .error .forbidden
      trace.phase auth started
      let context := TrustedNative.issueContext ⟨entry.user.actor, entry.user.tenant, entry.user.generation⟩ requestId
      trace.principal context
      let queued ← IO.monoMsNow
      return ← admitted service fun conn => do
        trace.phase queue queued
        .ok <$> action conn context entry.user
    admitted service fun conn => do
      let entered ← IO.monoMsNow
      trace.phase queue started
      let now ← service.clock
      let checked ← runDb conn (resolveSession digest now)
      match flatten checked with
      | .error e => trace.phase auth entered; return .error e
      | .ok (session, user) =>
        unless ← csrfAccepted csrf session.val.csrf do trace.phase auth entered; return .error .forbidden
        service.cacheStore digest ⟨user, session.val.csrf, session.val.expiresAt.toInt.toNat, ← IO.monoMsNow⟩
        let context := TrustedNative.issueContext ⟨user.actor, user.tenant, user.generation⟩ requestId
        trace.principal context
        trace.phase auth entered
        return .ok (← action conn context user)
  catch _ => return .error .internal

def Service.session (service : Service) (token : String) : IO (Except Error (User × String)) := do
  service.withAuthenticated token none "session" fun conn _ user => do
    let digest ← Crypto.digestToken token
    let .ok (some session) ← runDb conn (sessionByDigest digest)
      | throw (IO.userError "session unavailable")
    pure (user, session.val.csrf)

/-- Conservative transaction-bound authority for the private-notes experiment.
The existing managed transaction uses BEGIN IMMEDIATE: other writers wait until this
bounded callback finishes. Session validation and application reads share that transaction.
The callback is trusted, synchronous host code, not a general untrusted-code sandbox. -/
def Service.withAuthenticatedTransaction (service : Service) (token csrf : String)
    (requestId : String)
    (action : Conn → RequestContext → User → Nat → Nat → IO α)
    (trace : Log.TraceRef := none) : IO (Except Error α) := do
  unless tokenShape token && tokenShape csrf do return .error .unauthenticated
  try
    let started ← IO.monoMsNow
    let digest ← Crypto.digestToken token
    admitted service fun conn => do
      let entered ← IO.monoMsNow
      trace.phase (fun t n => { t with queueWait := t.queueWait + n }) started
      let auth := trace.phase (fun t n => { t with auth := t.auth + n }) entered
      let result ← runDb conn <| withTransaction do
        let now ← service.clock
        match ← resolveSession digest now with
        | .error e => auth; return .error e
        | .ok (session, user) =>
          unless ← Crypto.constantTimeEqual csrf session.val.csrf do auth; return .error .forbidden
          let context := TrustedNative.issueContext ⟨user.actor, user.tenant, user.generation⟩ requestId
          trace.principal context
          auth
          return .ok (← action conn context user now session.val.expiresAt.toInt.toNat)
      return flatten result
  catch _ => return .error .internal

def Service.logout (service : Service) (token csrf : String) : IO (Except Error Unit) := do
  let result ← service.withAuthenticated token (some csrf) "logout" fun conn _ _ => do
    let digest ← Crypto.digestToken token
    let deleted ← runDb conn <| withTransaction <| deleteSession digest
    service.cacheEvict [digest]
    pure deleted
  return flatten result

/-- The caller's live sessions (current generation, unexpired), newest first. -/
def Service.sessions (service : Service) (token csrf : String) : IO (Except Error (List SessionInfo)) := do
  let result ← service.withAuthenticated token (some csrf) "sessions" fun conn _ user => do
    let digest ← Crypto.digestToken token
    let now ← service.clock
    let .ok rows ← runDb conn (sessionsByActor user.actor) | throw (IO.userError "sessions unavailable")
    let live := rows.filter fun s => s.val.generation.toInt == (user.generation : Int) && (now : Int) < s.val.expiresAt.toInt
    let ordered := live.qsort fun a b => createdAt a > createdAt b
    ordered.toList.mapM fun s => do
      let stamp := fun (value : Option Int64) => value.map (·.toInt.toNat)
      pure (SessionInfo.mk (← sessionId s.val) s.val.label (stamp s.val.createdAt) (stamp s.val.lastSeenAt)
        (s.val.tokenDigest == digest))
  return result

/-- Revoke one of the caller's sessions by public id. Returns whether it was the current session,
which the HTTP host turns into a cookie clear. -/
def Service.revokeSession (service : Service) (token csrf id : String) : IO (Except Error Bool) := do
  unless tokenShape id do return .error .sessionNotFound
  let result ← service.withAuthenticated token (some csrf) "revoke" fun conn _ user => do
    let digest ← Crypto.digestToken token
    let .ok rows ← runDb conn (sessionsByActor user.actor) | throw (IO.userError "sessions unavailable")
    let mut target : Option String := none
    for s in rows do
      if ← Crypto.constantTimeEqual (← sessionId s.val) id then target := some s.val.tokenDigest
    let some victim := target | return .error Error.sessionNotFound
    let .ok () ← runDb conn (withTransaction (deleteSession victim)) | throw (IO.userError "revoke failed")
    service.cacheEvict [victim]
    return .ok (victim == digest)
  return flatten result

/-- Sign out everywhere: bump the generation and delete every session of the caller. -/
def Service.logoutAll (service : Service) (token csrf : String) : IO (Except Error Unit) := do
  let result ← service.withAuthenticated token (some csrf) "logout-all" fun conn _ user => do
    let cleared ← runDb conn <| withTransaction do
      let some account ← accountByActor user.actor | throw (.sqlite "account unavailable")
      if account.val.generation.toInt ≥ 9223372036854775807 then throw (.sqlite "invalid account state")
      discard <| update account { account.val with generation := account.val.generation + 1 }
      deleteSessions user.actor
    service.cacheEvictActor user.actor
    pure cleared
  return flatten result

/-- Verify the current password under the KDF gate (same throttles as login), store the new hash,
bump the generation so every other session dies, and re-issue the caller's session with a new token
and CSRF so it stays signed in. The session's label carries over. -/
def Service.changePassword (service : Service) (token csrf current next : String) : IO (Except Error Issued) := do
  unless tokenShape token do return .error .unauthenticated
  unless validPassword current do return .error .invalidCredentials
  unless validPassword next do return .error .invalidPassword
  let identified ← service.withAuthenticated token (some csrf) "password" fun conn _ user => do
    let digest ← Crypto.digestToken token
    let .ok (some session) ← runDb conn (sessionByDigest digest) | throw (IO.userError "session unavailable")
    pure (user, session.val.label)
  let (user, label) ← match identified with
    | .ok value => pure value
    | .error e => return .error e
  let changed ← withPasswordWork service user.username do
    let hash ← Crypto.hashPassword next
    let fresh ← Crypto.randomToken
    let freshCsrf ← Crypto.randomToken
    let freshDigest ← Crypto.digestToken fresh
    let digest ← Crypto.digestToken token
    verifiedThen service user.username current fun account now => do
      -- The caller's session must still be live under the generation checked at the start.
      let some session ← sessionByDigest digest | return .abort Error.unauthenticated
      if session.val.generation != account.val.generation || session.val.expiresAt.toInt ≤ now then
        return .abort Error.unauthenticated
      let updated := { account.val with passwordHash := hash, generation := account.val.generation + 1 }
      discard <| update account updated
      deleteSessions account.val.actor
      discard <| addSession service updated freshDigest freshCsrf now label
      return .commit (Issued.mk fresh freshCsrf (userOf updated))
  if changed.isOk then service.cacheEvictActor user.actor
  return changed

/-- Private administration only. Account disable or tenant changes revoke all sessions. -/
def Service.setAccess (service : Service) (actor tenant : String) (enabled : Bool) : IO (Except Error Unit) := do
  let result ← admitted service fun conn => runDb conn <| withTransaction do
    let some old ← accountByActor actor | throw (.sqlite "account unavailable")
    if tenant.isEmpty || old.val.generation.toInt ≥ 9223372036854775807 then throw (.sqlite "invalid account state")
    discard <| update old { old.val with tenant, enabled, generation := old.val.generation + 1 }
    deleteSessions actor
  service.cacheEvictActor actor
  return result

def Service.ready (service : Service) : IO Bool := service.runtime.ready

/-- Writer queue state for metrics: active/queued/completed callbacks. -/
def Service.queue (service : Service) : IO Runtime.State := service.runtime.snapshot

end LeanAppNative.Auth
