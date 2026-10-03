import LeanApp.Domain.Resources
import LeanContract.Operation

namespace LeanApp.Domain
open Ontology

/-- Interpreter-local data. No Wire instance; no public constructor. -/
structure Row (Scope T : Type) where
  private mk ::
  id : Ref T
  value : T

instance {Scope T : Type} : CoeOut (Row Scope T) T := ⟨@Row.value Scope T⟩

structure SignedIn (Scope T : Type) where
  private mk ::
  row : Row Scope T

def SignedIn.id (actor : SignedIn Scope T) : Ref T := actor.row.id

structure Viewer (Scope T : Type) where
  private mk ::
  person : Option (Ref T)

/- Explicitly trusted assembly boundary. Call only after live lookup in the current snapshot.
The browser has no codecs for these types. Adapters must rank-2 quantify Scope. -/
namespace Trusted

def row (id : Ref T) (value : T) : Row Scope T := ⟨id, value⟩
def signedIn (live : Row Scope T) : SignedIn Scope T := ⟨live⟩
def viewer (live : Option (Row Scope T)) : Viewer Scope T := ⟨live.map Row.id⟩
end Trusted

structure MemberHandleF (resources : ResourceFamily) (Scope Parent Target : Type) where
  private mk ::
  target : TypeId
  parent : Ref Parent
  name : String
  field : FieldPath Parent (Members Target)
  storage : resources.member Parent name Target

abbrev MemberHandle (Scope Parent Target : Type) (resources : ResourceFamily := portableResources) := MemberHandleF resources Scope Parent Target

/-- Explicit portable path constructor; native flows use the declared field capability below. -/
def Row.members [HasTypeId Target] (row : Row Scope Parent) (field : FieldPath Parent (Members Target)) :
    MemberHandle Scope Parent Target := ⟨HasTypeId.typeId (α := Target), row.id, "", field, PUnit.unit⟩

@[reducible] def Row.membersField {resources : ResourceFamily} (row : Row Scope Parent) (field : String)
    [MemberField Parent field Target] [HasTypeId Target] [HasMemberResource resources Parent field Target] :
    MemberHandle Scope Parent Target resources :=
  ⟨HasTypeId.typeId (α := Target), row.id, field, MemberField.path field, HasMemberResource.witness⟩

inductive PolicyF (resources : ResourceFamily) (Scope : Type) where
  | literal (value : Bool)
  | member {Parent Target : Type} (relation : MemberHandle Scope Parent Target resources) (member : Ref Target)
  | and (left right : PolicyF resources Scope)
  | or (left right : PolicyF resources Scope)
  | not (value : PolicyF resources Scope)
abbrev Policy (Scope : Type) (resources : ResourceFamily := portableResources) := PolicyF resources Scope
namespace Policy
abbrev literal := @PolicyF.literal
abbrev member := @PolicyF.member
abbrev and := @PolicyF.and
abbrev or := @PolicyF.or
abbrev not := @PolicyF.not
end Policy

def Policy.viewerMember {resources : ResourceFamily} (viewer : Viewer Scope T)
    (relation : MemberHandle Scope P T resources) : Policy Scope resources :=
  match viewer.person with | none => .literal false | some member => .member relation member

/-- Projection is a plan, with no unguarded Flow interpreter entry point. -/
inductive ProjectionF (resources : ResourceFamily) (Scope : Type) : Type → Type 1 where
  | members {Parent Target Value : Type} [Entity Target] (relation : MemberHandle Scope Parent Target resources)
      (field : FieldPath Target Value) (selection : resources.projection relation.storage field) : ProjectionF resources Scope (List Value)
  | map {A B : Type} (plan : ProjectionF resources Scope A) (f : A → B) : ProjectionF resources Scope B
abbrev Projection (Scope A : Type) (resources : ResourceFamily := portableResources) := ProjectionF resources Scope A
namespace Projection
/-- Arbitrary field paths are a portable reference-backend hook only. -/
def members [Entity T] (relation : MemberHandle Scope P T) (field : FieldPath T V) : Projection Scope (List V) :=
  ProjectionF.members relation field PUnit.unit
def map {resources : ResourceFamily} (plan : Projection Scope A resources) (f : A → B) : Projection Scope B resources := ProjectionF.map plan f
end Projection

def Projection.memberField {resources : ResourceFamily} [Entity T] (relation : MemberHandle Scope P T resources)
    (field : String) [EditableField T field V]
    [HasProjectionResource resources P T relation.name relation.storage field V] : Projection Scope (List V) resources :=
  ProjectionF.members relation (EditableField.lens (T := T) (field := field)).toFieldPath HasProjectionResource.witness

/-- Storage effects remain indexed. Constraints are explicit typed contracts, never caught wholesale. -/
inductive RequestF (resources : ResourceFamily) (Scope Error : Type) : Contract.OperationKind → Type → Type 1 where
  | now : RequestF resources Scope Error k Instant
  | find {T : Type} [Entity T] (storage : resources.entity T) (id : Ref T) : RequestF resources Scope Error k (Option (Row Scope T))
  | create {T : Type} [Entity T] (storage : resources.entity T) (value : T) (constraints : List (Constraint Error)) :
      RequestF resources Scope Error .command (Ref T)
  | change {T : Type} [Entity T] (storage : resources.entity T) (row : Row Scope T) (patch : Change T)
      (constraints : List (Constraint Error)) : RequestF resources Scope Error .command Unit
  | remove {T : Type} [Entity T] (storage : resources.entity T) (row : Row Scope T)
      (constraints : List (Constraint Error)) : RequestF resources Scope Error .command Unit
  | signUp {T : Type} [Entity T] (storage : resources.entity T) (authentication : resources.auth storage) (profile : T) (email : FieldPath T Email) (password : Password)
      (constraints : List (Constraint Error)) : RequestF resources Scope Error .command (Ref T)
  | signIn {T : Type} [Entity T] (storage : resources.entity T) (authentication : resources.auth storage) (email : FieldPath T Email) (address : Email) (password : Password)
      (invalidCredentials : Error) : RequestF resources Scope Error .command (Ref T)
  | include {P T : Type} (relation : MemberHandle Scope P T resources) (member : SignedIn Scope T)
      (constraints : List (Constraint Error)) : RequestF resources Scope Error .command Unit
  /- Plain-operation storage steps (DDD-LR-05/LDB-05). They never fail in the domain
  channel: declared unique conflicts are returned as VALUES of the entity's own conflict
  type `C`; foreign-key and infrastructure failures stay framework failures. -/
  | insert {T C : Type} [Entity T] (storage : resources.entity T) (value : T)
      (conflicts : List (Constraint C)) : RequestF resources Scope Error .command (Except C (Ref T))
  | update {T C : Type} [Entity T] (storage : resources.entity T) (row : Row Scope T) (patch : Change T)
      (conflicts : List (Constraint C)) : RequestF resources Scope Error .command (Except C Unit)
  | delete {T : Type} [Entity T] (storage : resources.entity T) (row : Row Scope T) :
      RequestF resources Scope Error .command Unit
  | findBy {T K : Type} [Entity T] (storage : resources.entity T) (unique : UniqueKey T K)
      (lookup : resources.unique storage unique) (key : K) : RequestF resources Scope Error k (Option (Row Scope T))
  | select {T : Type} [Entity T] (storage : resources.entity T) : RequestF resources Scope Error k (List (Row Scope T))
  /-- A join projection: field `field` of every target `T` linked to `parent` through edge
  `E`, each target once, ordered by target id (DDD-LDB-06; LeanDB lowers it to `Read.linkField`). -/
  | linkField {E P T V : Type} [Entity E] [Entity T] (edges : resources.entity E) (key : LinkKey E P T)
      (link : resources.link edges key) (targets : resources.entity T) (field : FieldPath T V)
      (column : resources.column targets field) (parent : Ref P) : RequestF resources Scope Error k (List V)
  /- Authentication steps (DDD-LAPI-06, decision 4). The runtime prepares the KDF work of
  `hashPassword`/`verifyCredential` before writer admission (`FlowMetadata.kdf` names the input
  field each consumes) and answers them from that preparation inside the transaction. -/
  | hashPassword (password : Password) : RequestF resources Scope Error .command PasswordHash
  /-- Decision 2: `profile = none` still does the (dummy) KDF work and returns `none`. -/
  | verifyCredential {T C : Type} [Entity T] [Entity C] (credentials : resources.entity C)
      (link : CredentialLink C T) (profile : Option (Row Scope T)) (password : Password) :
      RequestF resources Scope Error .command (Option (Ref T))
  | startSession {T : Type} [Entity T] (storage : resources.entity T) (authentication : resources.auth storage)
      (profile : Ref T) : RequestF resources Scope Error .command Session

abbrev Request (Scope Error : Type) (kind : Contract.OperationKind) (A : Type)
    (resources : ResourceFamily := portableResources) := RequestF resources Scope Error kind A
namespace Request
abbrev now := @RequestF.now
def signUp {resources : ResourceFamily} [Entity T] [HasEntityResource resources T]
    [HasAuthResource resources T HasEntityResource.witness]
    (profile : T) (email : FieldPath T Email) (password : Password) (constraints : List (Constraint E)) :
    Request Scope E .command (Ref T) resources := RequestF.signUp HasEntityResource.witness HasAuthResource.witness profile email password constraints
def signIn {resources : ResourceFamily} [Entity T] [HasEntityResource resources T]
    [HasAuthResource resources T HasEntityResource.witness]
    (email : FieldPath T Email) (address : Email) (password : Password) (invalidCredentials : E) :
    Request Scope E .command (Ref T) resources := RequestF.signIn HasEntityResource.witness HasAuthResource.witness email address password invalidCredentials
end Request

/-- Small reified language; queries cannot construct write requests or perform arbitrary IO. -/
inductive FlowF (resources : ResourceFamily) (kind : Contract.OperationKind) (Scope Error : Type) : Type → Type 1 where
  | pure {A : Type} (value : A) : FlowF resources kind Scope Error A
  | bind {A B : Type} (value : FlowF resources kind Scope Error A) (next : A → FlowF resources kind Scope Error B) : FlowF resources kind Scope Error B
  | fail {A : Type} (error : Error) : FlowF resources kind Scope Error A
  | request {A : Type} (value : RequestF resources Scope Error kind A) : FlowF resources kind Scope Error A
  | check (proposition : Prop) (decision : Decidable proposition) (error : Error) :
      FlowF resources kind Scope Error (PLift proposition)
  | disclose {A : Type} (policy : Policy Scope resources) (projection : Projection Scope A resources) :
      FlowF resources kind Scope Error (Disclosure A)

abbrev Flow (kind : Contract.OperationKind) (Scope Error A : Type)
    (resources : ResourceFamily := portableResources) := FlowF resources kind Scope Error A
namespace Flow
abbrev pure := @FlowF.pure
abbrev bind := @FlowF.bind
abbrev fail := @FlowF.fail
abbrev request := @FlowF.request
abbrev check := @FlowF.check
abbrev disclose := @FlowF.disclose
end Flow

variable {resources : ResourceFamily}

instance : Monad (FlowF resources k Scope Error) where
  pure := Flow.pure
  bind := Flow.bind

/-- Native Read/Txn adapters supply this algebra while Scope remains rank-2 scoped. -/
structure Algebra (m : Type → Type u) (kind : Contract.OperationKind) (Scope Error : Type) (resources : ResourceFamily := portableResources) where
  request : {A : Type} → RequestF resources Scope Error kind A → m (Except Error A)
  contains : {P T : Type} → MemberHandle Scope P T resources → Ref T → m Bool
  project : {A : Type} → Projection Scope A resources → m A

def Policy.eval {m : Type → Type u} [Monad m] (contains : {P T : Type} → MemberHandle Scope P T resources → Ref T → m Bool) :
    Policy Scope resources → m Bool
  | .literal value => pure value
  | .member relation member => contains relation member
  | .and left right => do if ← Policy.eval contains left then Policy.eval contains right else pure false
  | .or left right => do if ← Policy.eval contains left then pure true else Policy.eval contains right
  | .not value => do pure (!(← Policy.eval contains value))

def Flow.run {m : Type → Type u} [Monad m] (algebra : Algebra m k Scope Error resources) :
    Flow k Scope Error A resources → m (Except Error A)
  | .pure value => Pure.pure (.ok value)
  | .fail error => Pure.pure (.error error)
  | .request req => algebra.request req
  | .bind value next => do
    match ← Flow.run algebra value with
    | .error error => Pure.pure (.error error)
    | .ok value => Flow.run algebra (next value)
  | .check _ decision error =>
    match decision with
    | .isTrue proof => Pure.pure (.ok ⟨proof⟩)
    | .isFalse _ => Pure.pure (.error error)
  | .disclose policy projection => do
    if ← Policy.eval algebra.contains policy then Pure.pure (.ok (.visible (← algebra.project projection)))
    else Pure.pure (.ok .hidden)

abbrev FlowF.run := @Flow.run
abbrev PolicyF.eval := @Policy.eval

namespace Flow

def now : Flow k Scope E Instant resources := .request .now

def find [Entity T] [HasEntityResource resources T] (id : Ref T) (missing : E) : Flow k Scope E (Row Scope T) resources := do
  match ← Flow.request (.find HasEntityResource.witness id) with
  | none => .fail missing
  | some row => pure row

def require (p : Prop) [Decidable p] (error : E) : Flow k Scope E (PLift p) resources :=
  .check p inferInstance error

def create [Entity T] [HasEntityResource resources T] (value : T) (constraints : List (Constraint E) := []) : Flow .command Scope E (Ref T) resources :=
  .request (.create HasEntityResource.witness value constraints)
def change [Entity T] [HasEntityResource resources T] (row : Row Scope T) (patch : Change T)
    (constraints : List (Constraint E) := []) : Flow .command Scope E Unit resources :=
  .request (.change HasEntityResource.witness row patch constraints)
def remove [Entity T] [HasEntityResource resources T] (row : Row Scope T) (constraints : List (Constraint E) := []) : Flow .command Scope E Unit resources :=
  .request (.remove HasEntityResource.witness row constraints)
def «include» (relation : MemberHandle Scope P T resources) (actor : SignedIn Scope T)
    (constraints : List (Constraint E) := []) : Flow .command Scope E Unit resources :=
  .request (.include relation actor constraints)

/-- A callee's closed error type must be explicitly mapped; new alternatives break the map. -/
def mapError (map : E → F) : Flow k Scope E A resources → Flow k Scope F A resources
  | .pure value => .pure value
  | .fail error => .fail (map error)
  | .bind value next => .bind (mapError map value) (fun value => mapError map (next value))
  | .check p decision error => .check p decision (map error)
  | .disclose policy projection => .disclose policy projection
  | .request req => .request (match req with
    | .now => .now
    | @RequestF.find _ _ _ _ T inst storage id => @RequestF.find _ _ _ _ T inst storage id
    | @RequestF.create _ _ _ T inst storage value constraints => @RequestF.create _ _ _ T inst storage value (constraints.map fun c => { c with publicFailure := map c.publicFailure })
    | @RequestF.change _ _ _ T inst storage row patch constraints => @RequestF.change _ _ _ T inst storage row patch (constraints.map fun c => { c with publicFailure := map c.publicFailure })
    | @RequestF.remove _ _ _ T inst storage row constraints => @RequestF.remove _ _ _ T inst storage row (constraints.map fun c => { c with publicFailure := map c.publicFailure })
    | @RequestF.signUp _ _ _ T inst storage authentication profile email password constraints => @RequestF.signUp _ _ _ T inst storage authentication profile email password
        (constraints.map fun c => { c with publicFailure := map c.publicFailure })
    | @RequestF.signIn _ _ _ T inst storage authentication email address password error => @RequestF.signIn _ _ _ T inst storage authentication email address password (map error)
    | .include relation member constraints => .include relation member (constraints.map fun c => { c with publicFailure := map c.publicFailure })
    | @RequestF.insert _ _ _ T C inst storage value conflicts => @RequestF.insert _ _ _ T C inst storage value conflicts
    | @RequestF.update _ _ _ T C inst storage row patch conflicts => @RequestF.update _ _ _ T C inst storage row patch conflicts
    | @RequestF.delete _ _ _ T inst storage row => @RequestF.delete _ _ _ T inst storage row
    | @RequestF.findBy _ _ _ _ T K inst storage unique lookup key => @RequestF.findBy _ _ _ _ T K inst storage unique lookup key
    | @RequestF.select _ _ _ _ T inst storage => @RequestF.select _ _ _ _ T inst storage
    | .hashPassword password => .hashPassword password
    | @RequestF.linkField _ _ _ _ E P T V instE instT edges key link targets field column parent =>
        @RequestF.linkField _ _ _ _ E P T V instE instT edges key link targets field column parent
    | @RequestF.verifyCredential _ _ _ T C instT instC credentials link profile password =>
        @RequestF.verifyCredential _ _ _ T C instT instC credentials link profile password
    | @RequestF.startSession _ _ _ T inst storage authentication profile =>
        @RequestF.startSession _ _ _ T inst storage authentication profile)
end Flow
abbrev FlowF.mapError := @Flow.mapError

/-- Read-only requests embed into a writer transaction unchanged. -/
def RequestF.toCommand : RequestF resources Scope E .query A → RequestF resources Scope E .command A
  | .now => .now
  | @RequestF.find _ _ _ _ T inst storage id => @RequestF.find _ _ _ _ T inst storage id
  | @RequestF.findBy _ _ _ _ T K inst storage unique lookup key => @RequestF.findBy _ _ _ _ T K inst storage unique lookup key
  | @RequestF.select _ _ _ _ T inst storage => @RequestF.select _ _ _ _ T inst storage
  | @RequestF.linkField _ _ _ _ E P T V instE instT edges key link targets field column parent =>
      @RequestF.linkField _ _ _ _ E P T V instE instT edges key link targets field column parent

/-- `ReadOp`/`Query` lift into `Op`/`DB`: the same flow, run inside the writer. -/
def Flow.toCommand : Flow .query Scope E A resources → Flow .command Scope E A resources
  | .pure value => .pure value
  | .fail error => .fail error
  | .bind value next => .bind (Flow.toCommand value) (fun value => Flow.toCommand (next value))
  | .check p decision error => .check p decision error
  | .disclose policy projection => .disclose policy projection
  | .request req => .request req.toCommand
abbrev FlowF.toCommand := @Flow.toCommand

/-- Capture domain failures of a flow as values, without a new IR node. Every failure
source is structural (`fail`, `check`) or a request with a value-returning twin
(`create`/`change`/`remove` with constraints become `insert`/`update`/`delete`).
The milestone-1 auth and membership requests (`signUp`, `signIn`, `include` with
constraints) have no value-returning twin; their failures are NOT captured and
propagate unchanged. Plain operations never construct those requests. -/
def Flow.capture : Flow k Scope E A resources → Flow k Scope E (Except E A) resources
  | .pure value => .pure (.ok value)
  | .fail error => .pure (.error error)
  | .bind value next => .bind (Flow.capture value) fun
      | .ok value => Flow.capture (next value)
      | .error error => .pure (.error error)
  | .check p decision error => match decision with
      | .isTrue proof => .pure (.ok ⟨proof⟩)
      | .isFalse _ => .pure (.error error)
  | .disclose policy projection => .bind (.disclose policy projection) (fun value => .pure (.ok value))
  | .request req => match req with
      | @RequestF.create _ _ _ T inst storage value constraints =>
          .bind (.request (@RequestF.insert _ _ _ T _ inst storage value constraints)) (fun result => .pure result)
      | @RequestF.change _ _ _ T inst storage row patch constraints =>
          .bind (.request (@RequestF.update _ _ _ T _ inst storage row patch constraints)) (fun result => .pure result)
      | @RequestF.remove _ _ _ T inst storage row constraints =>
          if constraints.isEmpty then .bind (.request (@RequestF.delete _ _ _ T inst storage row)) (fun _ => .pure (.ok ()))
          else .bind (.request (.remove storage row constraints)) (fun value => .pure (.ok value))
      | other => .bind (.request other) (fun value => .pure (.ok value))

/-- `try … catch` for flows: same error type, effects before a caught failure persist. -/
def Flow.tryCatch (body : Flow k Scope E A resources) (handler : E → Flow k Scope E A resources) :
    Flow k Scope E A resources :=
  .bind (Flow.capture body) fun
    | .ok value => .pure value
    | .error error => handler error

structure NodeMetadata where
  kind : String
  effect : Contract.OperationKind
  detail : String
  failure : Option String := none
  fields : List String := []
  constraints : List String := []
  deriving Repr

/-- A KDF step an operation can reach, keyed by the request input field it consumes, so the
runtime can run it before writer admission (decision 4). -/
inductive KdfStep where
  | hash (field : String)
  | verify (field : String)
  deriving Repr, BEq, DecidableEq

structure FlowMetadata where
  identity : Contract.OperationId
  kind : Contract.OperationKind
  failures : List String
  source : String
  actor : String := "Unit"
  nodes : List NodeMetadata := []
  establishesSession : Bool := false
  kdf : List KdfStep := []
  deriving Repr

/-- The ordinary LeanContract operation is the sole public wire contract. -/
structure Operation (kind : Contract.OperationKind) (Actor : Type → Type) (Input Output Error : Type) where
  contract : Contract.Operation kind Input Output Error
  Requirements : ResourceFamily → Type 1
  portable : Requirements portableResources
  bodyWithResources : {resources : ResourceFamily} → Requirements resources →
    {Scope : Type} → Actor Scope → Input → Flow kind Scope Error Output resources
  metadata : FlowMetadata

def Operation.body (operation : Operation kind Actor Input Output Error) :
    {Scope : Type} → Actor Scope → Input → Flow kind Scope Error Output :=
  operation.bodyWithResources operation.portable

end LeanApp.Domain

namespace LeanApp.Domain
/-- Portable auth declaration; credentials/sessions and execution remain native-only. -/
structure Account (Profile : Type) [Entity Profile] where
  SignUpInput : Type
  SignUpError : Type
  SignInInput : Type
  SignInError : Type
  email : Ontology.FieldPath Profile Email
  signUpProfile : SignUpInput → Profile
  signUpPassword : SignUpInput → Password
  signInEmail : SignInInput → Email
  signInPassword : SignInInput → Password
  signUp : Operation .command (fun _ => Unit) SignUpInput (Ref Profile) SignUpError
  signIn : Operation .command (fun _ => Unit) SignInInput (Ref Profile) SignInError
end LeanApp.Domain
