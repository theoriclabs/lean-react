import LeanApp.Domain.Declarations
import Lean.Elab.Tactic.Basic

/-! # Operations as ordinary Lean (DDD-LR-05)

`Op ε α`, `ReadOp ε α`, `DB α` and `Query α` are VIEWS of the one family-indexed `Flow`
IR at the portable resource family and the plain-operation transaction index `OpScope`.
There is no second semantics: `Flow.run` interprets every one of them. Publication
(`LeanApp.Domain.Publish`) abstracts `portableResources`, the named portable instances and
`OpScope` out of an operation's elaborated body, which yields the resource-generic,
Scope-polymorphic `bodyWithResources` that native adapters run. -/

namespace LeanApp.Domain
open Ontology

/-- Transaction index of plain operations. Uninhabited and never inspected: publication
replaces it by the adapter's rank-2 `Scope`, so rows cannot depend on it. -/
inductive OpScope : Type

/-- A UTC instant. (Entity identities are `Ref T`; there is no `Id`
alias because core `Id` is the identity monad — coordination decision 11.) -/
abbrev Time : Type := Instant

/-- Readable UTC display text, `YYYY-MM-DD HH:MM UTC` (`:SS` only when nonzero), e.g.
`2026-10-17 19:00 UTC`. The wire form is RFC 3339 (`Instant.rfc3339`). -/
def Time.format (time : Time) : String := Instant.format time

/-- The server's clock reading. Only `Clock.now` (or an explicitly trusted adapter) can
produce one, so a rule or write that takes `Now` cannot be fed a time from the request
(coordination decision 14). It coerces to `Time`, so `now < p.date` elaborates. -/
structure Now where
  private mk ::
  time : Time

instance : Coe Now Time := ⟨Now.time⟩

/-- Trusted assembly/test boundary: a `Now` from an externally sampled clock. -/
def Trusted.now (time : Time) : Now := ⟨time⟩

/-- A read-write operation: one writer transaction; it returns `α` or fails with the
authored domain error `ε`. -/
def Op (ε α : Type) : Type 1 := Flow .command OpScope ε α
/-- A read-only operation over one snapshot; it lifts into `Op`. -/
def ReadOp (ε α : Type) : Type 1 := Flow .query OpScope ε α
/-- A read-write storage step. It cannot fail in the domain channel: declared unique
conflicts are values (`Except T.Conflict _`), other failures are framework failures. -/
def DB (α : Type) : Type 1 := Flow .command OpScope Empty α
/-- A read-only storage step. Lifts into `DB`, `ReadOp` and `Op`. -/
def Query (α : Type) : Type 1 := Flow .query OpScope Empty α

instance : Monad (Op ε) := inferInstanceAs (Monad (FlowF portableResources .command OpScope ε))
instance : Monad (ReadOp ε) := inferInstanceAs (Monad (FlowF portableResources .query OpScope ε))
instance : Monad DB := inferInstanceAs (Monad (FlowF portableResources .command OpScope Empty))
instance : Monad Query := inferInstanceAs (Monad (FlowF portableResources .query OpScope Empty))

instance : MonadExceptOf ε (Op ε) where
  throw := Flow.fail
  tryCatch := Flow.tryCatch
instance : MonadExceptOf ε (ReadOp ε) where
  throw := Flow.fail
  tryCatch := Flow.tryCatch

instance : MonadLift Query DB := ⟨Flow.toCommand⟩
instance : MonadLift DB (Op ε) := ⟨Flow.mapError (fun error => nomatch error)⟩
instance : MonadLift Query (ReadOp ε) := ⟨Flow.mapError (fun error => nomatch error)⟩
instance : MonadLift (ReadOp ε) (Op ε) := ⟨Flow.toCommand⟩

/-- Call another operation with a different closed error type: every alternative must be
mapped, so a new case in the callee breaks the caller until handled. -/
def Op.mapError (f : ε → δ) (op : Op ε α) : Op δ α := Flow.mapError f op
def ReadOp.mapError (f : ε → δ) (op : ReadOp ε α) : ReadOp δ α := Flow.mapError f op

instance : Inhabited (Op ε Unit) := ⟨Flow.pure ()⟩
instance : Inhabited (ReadOp ε Unit) := ⟨Flow.pure ()⟩

/-- Check a decidable proposition; hand back its proof, or fail the operation with `err`.
`let ⟨h⟩ ← require p .err` binds `h : p`. -/
def «require» (p : Prop) [Decidable p] (err : ε) : Op ε (PLift p) := Flow.check p inferInstance err
/-- `require` inside a read-only operation. -/
def ReadOp.«require» (p : Prop) [Decidable p] (err : ε) : ReadOp ε (PLift p) := Flow.check p inferInstance err

/-- Server time, sampled by the runtime when the request is interpreted (after writer
admission for `Op`). Never part of the request. -/
def Clock.now : Op ε Now := Flow.bind (Flow.request .now) fun time => Flow.pure ⟨time⟩
/-- Snapshot time inside a read-only operation. -/
def ReadOp.now : ReadOp ε Now := Flow.bind (Flow.request .now) fun time => Flow.pure ⟨time⟩

/-- Lets the `require p err` surface work in both `Op` and `ReadOp` do-blocks. -/
class MonadRequire (ε : outParam Type) (m : Type → Type 1) where
  requireWith : (p : Prop) → Decidable p → ε → m (PLift p)
instance : MonadRequire ε (Op ε) := ⟨fun p decision err => @«require» ε p decision err⟩
instance : MonadRequire ε (ReadOp ε) := ⟨fun p decision err => @ReadOp.«require» ε p decision err⟩

/-- `Decidable p`, unfolding definitions such as `def MayEdit … : Prop := …` as needed. -/
partial def decidableByUnfolding (p : Lean.Expr) : Lean.MetaM Lean.Expr := do
  match ← Lean.Meta.synthInstance? (Lean.mkApp (Lean.mkConst ``Decidable) p) with
  | some inst => return inst
  | none =>
    match ← Lean.Meta.unfoldDefinition? p with
    | some unfolded => decidableByUnfolding unfolded
    | none =>
      let whnf ← Lean.Meta.whnfR p
      if whnf != p then decidableByUnfolding whnf
      else Lean.throwError m!"require: failed to find a Decidable instance for{Lean.indentExpr p}"

/-- Closes `Decidable p` goals, unfolding the proposition's head definitions. -/
elab "domain_decidable" : tactic => Lean.Elab.Tactic.liftMetaTactic fun goal => do
  let goalType ← Lean.instantiateMVars (← goal.getType)
  let some p := goalType.app1? ``Decidable | Lean.throwError "domain_decidable: expected a Decidable goal"
  goal.assign (← decidableByUnfolding p)
  return []

/-- Per-entity row view (`T.Row Scope` extends `T` with its `id`), generated by
`deriving Entity`. `Row T` in authored code elaborates to it, so `p.date`/`p.id` work. -/
class HasRow (T : Type) (R : outParam (Type → Type)) where
  ofRow : {Scope : Type} → Row Scope T → R Scope
  toRow : {Scope : Type} → R Scope → Row Scope T

/-- Types the runtime may fill from a verified session (`SignedIn`). A published operation's
parameter of a `Principal` type (or `Option` of one) is the actor, never request input. -/
class Principal (A : Type) where
  Profile : Type
  id : A → Ref Profile
  /-- Trusted adapter construction from a live profile row. Assembly only. -/
  trusted : Ref Profile → Profile → A

instance : Principal (SignedIn Scope T) where
  Profile := T
  id := SignedIn.id
  trusted := fun id value => Trusted.signedIn (Trusted.row id value)

/-- Marker for `deriving Changes (except := [fields])`: generates `T.Changes`, the editable
fields of entity `T` (a wire record), its lawful patch `T.Changes.toChange`, and `T.patch`. -/
class Changes (T : Type) : Type where

/-- `Op Empty α` publishes with an empty error schema. -/
instance : HasTypeId Empty := ⟨{ packageName := "lean", name := "Empty" }⟩
instance : Domain Empty := { typeId := { packageName := "lean", name := "Empty" }, cases := [] }
instance : Wire Empty := ⟨enumCodec { packageName := "lean", name := "Empty" } [] (fun value => nomatch value)⟩

/-! ## Generic storage steps (portable family). Generated `T.insert`/`T.find`/… call these. -/

namespace DB
def insert [Entity T] [HasEntityResource portableResources T] (value : T) (conflicts : List (Constraint C)) :
    DB (Except C (Ref T)) :=
  Flow.request (.insert HasEntityResource.witness value conflicts)
def insertTotal [Entity T] [HasEntityResource portableResources T] (value : T) : DB (Ref T) :=
  Flow.bind (Flow.request (.insert HasEntityResource.witness value ([] : List (Constraint Empty)))) fun
    | .ok id => Flow.pure id
    | .error error => nomatch error
def update [Entity T] [HasEntityResource portableResources T] [HasRow T R] (row : R OpScope) (value : T)
    (conflicts : List (Constraint C)) : DB (Except C Unit) :=
  Flow.request (.update HasEntityResource.witness (HasRow.toRow (T := T) row) (Change.replace value) conflicts)
def updateTotal [Entity T] [HasEntityResource portableResources T] [HasRow T R] (row : R OpScope) (value : T) : DB Unit :=
  Flow.bind (Flow.request (.update HasEntityResource.witness (HasRow.toRow (T := T) row) (Change.replace value)
    ([] : List (Constraint Empty)))) fun
    | .ok () => Flow.pure ()
    | .error error => nomatch error
/-- A selective update built from lawful field lenses (`T.Changes.toChange`). Only constraints
over the changed fields can conflict; pass exactly those. -/
def patch [Entity T] [HasEntityResource portableResources T] [HasRow T R] (row : R OpScope) (edit : Change T)
    (conflicts : List (Constraint C)) : DB (Except C Unit) :=
  Flow.request (.update HasEntityResource.witness (HasRow.toRow (T := T) row) edit conflicts)
def patchTotal [Entity T] [HasEntityResource portableResources T] [HasRow T R] (row : R OpScope) (edit : Change T) : DB Unit :=
  Flow.bind (Flow.request (.update HasEntityResource.witness (HasRow.toRow (T := T) row) edit
    ([] : List (Constraint Empty)))) fun
    | .ok () => Flow.pure ()
    | .error error => nomatch error
def delete [Entity T] [HasEntityResource portableResources T] [HasRow T R] (row : R OpScope) : DB Unit :=
  Flow.request (.delete HasEntityResource.witness (HasRow.toRow (T := T) row))
end DB

namespace Query
def «find» [Entity T] [HasEntityResource portableResources T] [HasRow T R] (id : Ref T) : Query (Option (R OpScope)) :=
  Flow.bind (Flow.request (.find HasEntityResource.witness id)) fun row => Flow.pure (row.map HasRow.ofRow)
def findBy [Entity T] [storage : HasEntityResource portableResources T] [HasRow T R] (unique : UniqueKey T K)
    [HasUniqueResource portableResources T K storage.witness unique] (key : K) : Query (Option (R OpScope)) :=
  Flow.bind (Flow.request (.findBy storage.witness unique HasUniqueResource.witness key)) fun row =>
    Flow.pure (row.map HasRow.ofRow)
def select [Entity T] [HasEntityResource portableResources T] [HasRow T R] : Query (List (R OpScope)) :=
  Flow.bind (Flow.request (.select HasEntityResource.witness)) fun rows => Flow.pure (rows.map (HasRow.ofRow (T := T)))
/-- Field `field` of every `T` linked to `parent` through edge `E`, once each, by target id.
A row view of the edge or the target never reaches the caller: only the selected values. -/
def linkField [Entity E] [edges : HasEntityResource portableResources E] [Entity T]
    [targets : HasEntityResource portableResources T] (key : LinkKey E P T)
    [HasLinkResource portableResources E P T edges.witness key] (field : FieldPath T V)
    [HasColumnResource portableResources T V targets.witness field] (parent : Ref P) : Query (List V) :=
  Flow.request (.linkField edges.witness key HasLinkResource.witness targets.witness field HasColumnResource.witness parent)
end Query

/-! ## Authored surface syntax (scoped: active with `open LeanApp.Domain`) -/

/-- `Row T` is the entity's row view; `Row Scope T` keeps the milestone-1 meaning. -/
scoped syntax (name := rowType) "Row " term:max (ppSpace colGt term:max)? : term

open Lean Elab Term Meta in
elab_rules : term
  | `(rowType| Row $scope:term $target:term) => do
    elabTerm (← `(LeanApp.Domain.Row $scope $target)) none
  | `(rowType| Row $target:term) => do
    let ty ← elabType target
    let rowView ← mkFreshExprMVar (some (.forallE `Scope (.sort 1) (.sort 1) .default))
    match ← synthInstance? (mkApp2 (mkConst ``HasRow) ty rowView) with
    | some _ => return mkApp (← instantiateMVars rowView) (mkConst ``OpScope)
    | none => return mkApp2 (mkConst ``LeanApp.Domain.Row) (mkConst ``OpScope) ty

/-- `require p err` in `Op`/`ReadOp`; decides `p` by unfolding authored rule definitions. -/
syntax (name := requireTerm) "require " term:max term:max : term
macro_rules (kind := requireTerm)
  | `(require $p $err) => `(LeanApp.Domain.MonadRequire.requireWith $p (by first | infer_instance | domain_decidable) $err)

@[app_unexpander LeanApp.Domain.Row] def unexpandRow : Lean.PrettyPrinter.Unexpander
  | `($_ $scope:ident $t) => if scope.getId.getString! == "OpScope" then `(Row $t) else `(Row $scope $t)
  | `($_ $scope $t) => `(Row $scope $t)
  | _ => throw ()

end LeanApp.Domain
