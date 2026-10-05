import LeanApp.Domain.Flow

/-! A portable reference interpreter with nonempty typed row decoding, unique checks,
set memberships, ordered projections and rollback. It is not a SQLite correctness proof. -/
namespace LeanApp.Domain.Memory
open Ontology
variable {resources : ResourceFamily}

structure Key where
  entity : TypeId
  scope : String
  id : String
  deriving BEq, DecidableEq, Repr

structure MemberKey where
  parent : Key
  field : FieldPathId
  target : Key
  deriving BEq, DecidableEq, Repr

structure Store where
  now : Instant
  rows : List (Key × Lean.Json) := []
  members : List MemberKey := []
  next : List (TypeId × Nat) := []
  projectionReads : Nat := 0
  /-- Profile keys of sessions started, in order (the reference backend has no tokens). -/
  sessions : List String := []
  /-- KDF evaluations performed (hash or verify, including decision-2 dummy work). -/
  kdfRuns : Nat := 0

inductive Fault where
  | decode (errors : ValidationErrors)
  | missingCurrentRow
  | danglingMember
  | nativeAuthenticationRequired
  | malformedMemberPath
  | unsupportedConstraint (identity : String)
  deriving Repr

abbrev Engine := StateT Store (Except Fault)

private def key [HasTypeId T] (ref : Ref T) : Key := ⟨HasTypeId.typeId (α := T), ref.scope.value, ref.key⟩

private def parentKey (relation : MemberHandle Scope P T resources) : Except Fault Key := do
  match relation.field.identity.head? with
  | some (.field owner _) => pure ⟨owner, relation.parent.scope.value, relation.parent.key⟩
  | _ => throw .malformedMemberPath

private def memberKey (relation : MemberHandle Scope P T resources) (target : Ref T) : Except Fault MemberKey := do
  pure ⟨← parentKey relation, relation.field.identity, ⟨relation.target, target.scope.value, target.key⟩⟩

private def liftChecked (result : Validation A) : Engine A :=
  match result with | .ok value => pure value | .error errors => throw (.decode errors)

private def liftFault (result : Except Fault A) : Engine A :=
  match result with | .ok value => pure value | .error error => throw error

def lookup [Entity T] (ref : Ref T) : Engine (Option (Row Scope T)) := do
  match (← get).rows.find? (fun item => item.1 == key ref) with
  | none => pure none
  | some (_, json) =>
    let value ← liftChecked ((Entity.recordRepresentation (T := T)).decode json)
    pure (some (Trusted.row ref value))

private def conflict (json : Lean.Json) (identity : TypeId) (excluding : Option Key)
    (constraints : List (Constraint E)) : Engine (Option E) := do
  let rows := (← get).rows
  for constraint in constraints do
    if constraint.fields.isEmpty then throw (Fault.unsupportedConstraint constraint.identity)
    let matchesRow := fun (row : Key × Lean.Json) => row.1.entity == identity && excluding != some row.1 &&
      constraint.fields.all (fun field => match json.getObjVal? field, row.2.getObjVal? field with
        | .ok a, .ok b => a == b | _, _ => false)
    if rows.any matchesRow then return some constraint.publicFailure
  return none

def contains (relation : MemberHandle Scope P T resources) (target : Ref T) : Engine Bool := do
  let member ← liftFault (memberKey relation target)
  return (← get).members.contains member

private def putRow (ref : Ref T) [Entity T] (value : T) : Engine Unit :=
  modify fun store => { store with rows := store.rows.filter (fun row => row.1 != key ref) ++
    [(key ref, (Entity.recordRepresentation (T := T)).encode value)] }

private def insertRow [Entity T] (value : T) : Engine (Ref T) := do
  let identity := HasTypeId.typeId (α := T)
  let store ← get
  let next := (store.next.find? (fun entry => entry.1 == identity)).map Prod.snd |>.getD 1
  let ref ← liftChecked (Ref.parse (T := T) (toString next))
  putRow ref value
  modify fun store => { store with next := store.next.filter (fun entry => entry.1 != identity) ++ [(identity, next + 1)] }
  return ref

/-- Every stored row of one entity, decoded through its typed representation, by numeric id. -/
def entityRows [Entity T] : Engine (List (Row Scope T)) := do
  let identity := HasTypeId.typeId (α := T)
  let stored := (← get).rows.filter (fun row => row.1.entity == identity)
    |>.mergeSort (fun a b => a.1.id.toNat?.getD 0 ≤ b.1.id.toNat?.getD 0)
  let mut rows := []
  for (rowKey, json) in stored do
    let ref ← liftChecked (Ref.parse (T := T) rowKey.id rowKey.scope)
    let value ← liftChecked ((Entity.recordRepresentation (T := T)).decode json)
    rows := rows ++ [Trusted.row ref value]
  return rows

/-- TEST KDF, not cryptographic: a deterministic stand-in so the reference backend can store
and verify `PasswordHash`es. Native runtimes use their real KDF (scrypt under `KDFGate`). -/
def testKdf (password : Password) : String :=
  "memory-test-kdf$" ++ toString (hash ("leanapp-memory-salt" ++ password.value))

private def runKdf (password : Password) : Engine String := do
  modify fun store => { store with kdfRuns := store.kdfRuns + 1 }
  return testKdf password

def request : Request Scope E k A resources → Engine (Except E A)
  | .now => do return .ok (← get).now
  | @RequestF.find _ _ _ _ T inst _storage ref => do
    let _ : Entity T := inst
    return .ok (← lookup (Scope := Scope) ref)
  | @RequestF.create _ _ _ T inst _storage value constraints => do
    let _ : Entity T := inst
    let identity := HasTypeId.typeId (α := T)
    let json := (Entity.recordRepresentation (T := T)).encode value
    match ← conflict json identity none constraints with
    | some failure => return .error failure
    | none => do
      let store ← get
      let next := (store.next.find? (fun entry => entry.1 == identity)).map Prod.snd |>.getD 1
      let ref ← liftChecked (Ref.parse (T := T) (toString next))
      putRow ref value
      modify fun store => { store with next := store.next.filter (fun entry => entry.1 != identity) ++ [(identity, next + 1)] }
      return .ok ref
  | @RequestF.change _ _ _ T inst _storage row patch constraints => do
    let _ : Entity T := inst
    let .some current ← lookup (Scope := Scope) row.id | throw Fault.missingCurrentRow
    let updated := patch.apply current.value
    let json := (Entity.recordRepresentation (T := T)).encode updated
    match ← conflict json (HasTypeId.typeId (α := T)) (some (key row.id)) constraints with
    | some failure => return .error failure
    | none => putRow row.id updated; return .ok ()
  | @RequestF.remove _ _ _ T inst _storage row _constraints => do
    let _ : Entity T := inst
    if let some constraint := _constraints.head? then throw (Fault.unsupportedConstraint constraint.identity)
    let identity := key row.id
    modify fun store => { store with rows := store.rows.filter (fun row => row.1 != identity), members := store.members.filter (fun member => member.parent != identity) }
    return .ok ()
  | @RequestF.signUp .. | @RequestF.signIn .. => throw Fault.nativeAuthenticationRequired
  | @RequestF.insert _ _ _ T _ inst _storage value conflicts => do
    let _ : Entity T := inst
    let identity := HasTypeId.typeId (α := T)
    let json := (Entity.recordRepresentation (T := T)).encode value
    match ← conflict json identity none conflicts with
    | some failure => return .ok (.error failure)
    | none => return .ok (.ok (← insertRow value))
  | @RequestF.update _ _ _ T _ inst _storage row patch conflicts => do
    let _ : Entity T := inst
    let .some current ← lookup (Scope := Scope) row.id | throw Fault.missingCurrentRow
    let updated := patch.apply current.value
    let codec := Entity.recordRepresentation (T := T)
    let before := codec.encode current.value
    let json := codec.encode updated
    -- Touched-field rule: only constraints over fields whose value changed can newly conflict.
    let touched := conflicts.filter fun c => c.fields.any fun field =>
      match before.getObjVal? field, json.getObjVal? field with
      | .ok a, .ok b => a != b
      | _, _ => true
    match ← conflict json (HasTypeId.typeId (α := T)) (some (key row.id)) touched with
    | some failure => return .ok (.error failure)
    | none => putRow row.id updated; return .ok (.ok ())
  | @RequestF.delete _ _ _ T inst _storage row => do
    let _ : Entity T := inst
    let identity := key row.id
    modify fun store => { store with rows := store.rows.filter (fun row => row.1 != identity), members := store.members.filter (fun member => member.parent != identity) }
    return .ok ()
  | @RequestF.findBy _ _ _ _ T _ inst _storage unique _lookup probe => do
    let _ : Entity T := inst
    let rows ← entityRows (Scope := Scope) (T := T)
    return .ok (rows.find? fun row => unique.equal (unique.key row.value) probe)
  | @RequestF.select _ _ _ _ T inst _storage => do
    let _ : Entity T := inst
    return .ok (← entityRows (Scope := Scope) (T := T))
  | @RequestF.linkField _ _ _ _ E P T V instE instT _edges key _link _targets field _column parent => do
    let _ : Entity E := instE
    let _ : Entity T := instT
    let edges ← entityRows (Scope := Scope) (T := E)
    let targets := (edges.filter fun edge => key.parent edge.value == parent).map (key.target ·.value)
    -- Each target once, by numeric id (the native plan's ORDER BY target id).
    let distinct := targets.foldl (fun acc ref => if acc.any (· == ref) then acc else acc ++ [ref]) []
    let ordered := distinct.mergeSort fun a b => a.key.toNat?.getD 0 ≤ b.key.toNat?.getD 0
    modify fun store => { store with projectionReads := store.projectionReads + 1 }
    let mut values : List V := []
    for ref in ordered do
      let .some row ← lookup (Scope := Scope) ref | throw Fault.danglingMember
      values := values ++ [field.get row.value]
    return .ok values
  | .hashPassword password => do
    return .ok (Trusted.passwordHash (← runKdf password))
  | @RequestF.verifyCredential _ _ _ T C instT instC _credentials link profile password => do
    let _ : Entity T := instT
    let _ : Entity C := instC
    -- Decision 2: the same KDF work whether or not the profile exists.
    let candidate ← runKdf password
    match profile with
    | none => return .ok none
    | some row =>
      let credentials ← entityRows (Scope := Scope) (T := C)
      let accepted := credentials.any fun credential =>
        link.profile.get credential.value == row.id &&
          Trusted.passwordHashText (link.hash.get credential.value) == candidate
      return .ok (if accepted then some row.id else none)
  | @RequestF.startSession _ _ _ _ _ _storage _authentication profile => do
    modify fun store => { store with sessions := store.sessions ++ [profile.key] }
    return .ok (Trusted.session profile)
  | .«include» relation member _constraints => do
    if let some constraint := _constraints.head? then throw (Fault.unsupportedConstraint constraint.identity)
    let member ← liftFault (memberKey relation member.id)
    let store ← get
    if !store.rows.any (fun row => row.1 == member.parent) || !store.rows.any (fun row => row.1 == member.target) then
      throw Fault.danglingMember
    if !store.members.contains member then modify fun store => { store with members := store.members ++ [member] }
    return .ok ()

def project : Projection Scope A resources → Engine A
  | @ProjectionF.members _ _ _Parent Target _Value inst relation field _selection => do
    let _ : Entity Target := inst
    let parent ← liftFault (parentKey relation)
    modify fun store => { store with projectionReads := store.projectionReads + 1 }
    let store ← get
    let ids := store.members.filter (fun member => member.parent == parent && member.field == relation.field.identity)
      |>.mergeSort (fun a b => a.target.id.toNat?.getD 0 ≤ b.target.id.toNat?.getD 0)
    let mut values := []
    for member in ids do
      let ref ← liftChecked (Ref.parse (T := Target) member.target.id member.target.scope)
      let .some row ← lookup (Scope := Scope) ref | throw Fault.danglingMember
      values := values ++ [field.get row.value]
    return values
  | .map plan f => do return f (← project plan)

def algebra : Algebra Engine k Scope E resources := ⟨request, contains, project⟩

def read (flow : Flow .query Scope E A resources) (store : Store) : Except Fault (Except E A × Store) :=
  (flow.run algebra).run store

/-- A late domain error discards every mutation; infrastructure faults stay separate. -/
def command (flow : Flow .command Scope E A resources) (store : Store) : Except Fault (Except E A × Store) := do
  let (result, after) ← (flow.run algebra).run store
  match result with | .ok _ => pure (result, after) | .error _ => pure (result, store)

end LeanApp.Domain.Memory
