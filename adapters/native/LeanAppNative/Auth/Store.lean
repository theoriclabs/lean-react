import LeanApp
import LeanDb.Runtime
import LeanDb.Derive
import LeanAppNative.Auth.Crypto
import Std.Time

namespace LeanAppNative.Auth
open LeanDb LeanApp

inductive Error where
  | invalidUsername | invalidPassword | usernameUnavailable | invalidCredentials
  | unauthenticated | forbidden | throttled | unavailable | internal | inviteRequired
  deriving BEq, Repr

/-- How signup assigns a tenant. `.fixed` lets any signup share the workspace, so pair it with
ingress abuse controls; `.invite` admits only holders of a token issued by trusted native code. -/
inductive TenantPolicy where
  | privatePerAccount
  | fixed (tenant : String)
  | invite
  deriving Repr, BEq

structure Service.Config where
  ttl : Nat := 86400
  tenantPolicy : TenantPolicy := .privatePerAccount
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

structure Session where
  tokenDigest : String
  csrf : String
  actor : String
  generation : Int64
  expiresAt : Int64
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

private structure Throttle where
  window : Nat := 0
  total : Nat := 0
  names : List (String × Nat) := []

structure Service where
  private mk ::
  private runtime : Runtime.Service
  private dummyHash : String
  private kdf : Std.BaseMutex
  private throttle : Std.Mutex Throttle
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
  if config.ttl == 0 || config.ttl > 604800 then return .error .internal
  if let .fixed tenant := config.tenantPolicy then
    unless validTenant tenant do return .error .internal
  try
    let dummy ← Crypto.hashPassword "leanapp-unknown-user-dummy-password"
    let service := Service.mk runtime dummy (← Std.BaseMutex.new) (← Std.Mutex.new {}) clock config
    let result ← admitted service fun conn => runDb conn <| withTransaction do
      untrackedSqlite fun db => do
        db.exec s!"CREATE UNIQUE INDEX IF NOT EXISTS leanapp_auth_username ON {quoteIdent (Entity.tableName Account)} (username)"
        db.exec s!"CREATE UNIQUE INDEX IF NOT EXISTS leanapp_auth_actor ON {quoteIdent (Entity.tableName Account)} (actor)"
        db.exec s!"CREATE UNIQUE INDEX IF NOT EXISTS leanapp_auth_session ON {quoteIdent (Entity.tableName Session)} (tokenDigest)"
        db.exec s!"CREATE UNIQUE INDEX IF NOT EXISTS leanapp_auth_invite ON {quoteIdent (Entity.tableName Invite)} (tokenDigest)"
    return result.map (fun _ => service)
  catch _ => return .error .internal

/-- One KDF at a time, no waiting queue. Throttles are bounded, process-local defense;
deployments also need ingress/IP limits. Restart does not preserve these counters. -/
private def withPasswordWork (service : Service) (name : String)
    (action : IO (Except Error α)) : IO (Except Error α) := do
  unless ← service.kdf.tryLock do return .error .throttled
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
    unless allowed do return .error .throttled
    action
  catch _ => return .error .internal
  finally service.kdf.unlock

private def deleteSessions (actor : String) : DbM Unit :=
  untrackedSqlite fun db => do
    let stmt ← db.prepare s!"DELETE FROM {quoteIdent (Entity.tableName Session)} WHERE actor = ?"
    stmt.bindText 1 actor
    discard stmt.step

private def addSession (service : Service) (account : Account)
    (digest csrf : String) (now : Nat) : DbM Unit := do
  if now + service.ttl > 9223372036854775807 then throw (.sqlite "invalid authentication clock")
  deleteSessions account.actor
  discard <| insert Session ⟨digest, csrf, account.actor, account.generation, Int64.ofInt (now + service.ttl)⟩

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
    (invite : Option String := none) : IO (Except Error Issued) := do
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
        addSession service account digest csrf now
        return .commit (Issued.mk token csrf (userOf account))
    return flatten result

/-- Login replaces the account's previous session. The password hash and account state
are rechecked after the KDF under the same transaction as generation/session issuance. -/
def Service.login (service : Service) (input password : String) : IO (Except Error Issued) := do
  let .ok name := username input | return .error .invalidCredentials
  unless validPassword password do return .error .invalidCredentials
  withPasswordWork service name do
    let loaded ← admitted service fun conn => runDb conn (accountByName name)
    let candidate ← match loaded with
      | .ok candidate => pure candidate
      | .error e => return .error e
    let hash := (candidate.map (·.val.passwordHash)).getD service.dummyHash
    let verified ← Crypto.verifyPassword password hash
    let some old := candidate | return .error .invalidCredentials
    unless verified do return .error .invalidCredentials
    let token ← Crypto.randomToken
    let csrf ← Crypto.randomToken
    let digest ← Crypto.digestToken token
    let result ← admitted service fun conn => do
      let now ← service.clock
      runDb conn <| transaction do
        let some current ← accountByActor old.val.actor | return .abort Error.invalidCredentials
        if !current.val.enabled || current.val.passwordHash != hash ||
            current.val.generation.toInt < 0 || current.val.generation.toInt ≥ 9223372036854775807 then
          return .abort Error.invalidCredentials
        let next := { current.val with generation := current.val.generation + 1 }
        discard <| update current next
        addSession service next digest csrf now
        return .commit (Issued.mk token csrf (userOf next))
    return flatten result

private def resolveSession (digest : String) (now : Nat) : DbM (Except Error (Stored Session × User)) := do
  let some session ← sessionByDigest digest | return .error .unauthenticated
  let some account ← accountByActor session.val.actor | return .error .unauthenticated
  if !account.val.enabled || session.val.expiresAt.toInt ≤ now ||
      account.val.generation != session.val.generation || account.val.generation.toInt < 0 then
    return .error .unauthenticated
  return .ok (session, userOf account.val)

/-- Verification, current membership and application policy execute within one admitted
callback. Trusted callback must not retain conn or recursively enter this service. -/
def Service.withAuthenticated (service : Service) (token : String) (csrf : Option String)
    (requestId : String) (action : Conn → RequestContext → User → IO α) : IO (Except Error α) := do
  unless tokenShape token do return .error .unauthenticated
  try
    let digest ← Crypto.digestToken token
    admitted service fun conn => do
      let now ← service.clock
      let checked ← runDb conn (resolveSession digest now)
      match flatten checked with
      | .error e => return .error e
      | .ok (session, user) =>
        if let some supplied := csrf then
          unless tokenShape supplied && (← Crypto.constantTimeEqual supplied session.val.csrf) do
            return .error .forbidden
        let context := TrustedNative.issueContext ⟨user.actor, user.tenant, user.generation⟩ requestId
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
    (action : Conn → RequestContext → User → Nat → Nat → IO α) : IO (Except Error α) := do
  unless tokenShape token && tokenShape csrf do return .error .unauthenticated
  try
    let digest ← Crypto.digestToken token
    admitted service fun conn => do
      let result ← runDb conn <| withTransaction do
        let now ← service.clock
        match ← resolveSession digest now with
        | .error e => return .error e
        | .ok (session, user) =>
          unless ← Crypto.constantTimeEqual csrf session.val.csrf do return .error .forbidden
          let context := TrustedNative.issueContext ⟨user.actor, user.tenant, user.generation⟩ requestId
          return .ok (← action conn context user now session.val.expiresAt.toInt.toNat)
      return flatten result
  catch _ => return .error .internal

def Service.logout (service : Service) (token csrf : String) : IO (Except Error Unit) := do
  let result ← service.withAuthenticated token (some csrf) "logout" fun conn _ _ => do
    let digest ← Crypto.digestToken token
    runDb conn <| withTransaction <| untrackedSqlite fun db => do
      let stmt ← db.prepare s!"DELETE FROM {quoteIdent (Entity.tableName Session)} WHERE tokenDigest = ?"
      stmt.bindText 1 digest
      discard stmt.step
  return flatten result

/-- Private administration only. Account disable or tenant changes revoke all sessions. -/
def Service.setAccess (service : Service) (actor tenant : String) (enabled : Bool) : IO (Except Error Unit) :=
  admitted service fun conn => runDb conn <| withTransaction do
    let some old ← accountByActor actor | throw (.sqlite "account unavailable")
    if tenant.isEmpty || old.val.generation.toInt ≥ 9223372036854775807 then throw (.sqlite "invalid account state")
    discard <| update old { old.val with tenant, enabled, generation := old.val.generation + 1 }
    deleteSessions actor

def Service.ready (service : Service) : IO Bool := service.runtime.ready

end LeanAppNative.Auth
