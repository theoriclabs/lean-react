import LeanApp.Domain.Entities

/-! # Publishing a plain operation (contract derivation)

`derive_operation f` (also run by an `Api` declaration for each listed function) reads the
operation contract off the type of an ordinary `def`:

```
def borrow (me : Signed) (book : Ref Book) : Op BorrowError (Ref Loan) := …
```

* the parameter whose type is a `Principal` (or `Option` of one) is the actor, never input;
* every other explicit parameter becomes a field of the generated `borrow.Input` record;
* `Op ε α` publishes a command, `ReadOp ε α` a query; `ε` is the closed error, `α` the output.

It generates, next to `f` (all are ordinary declarations you can `#check`):

```
f.Input                 : Type                       -- record of the non-actor arguments
f.Requirements          : ResourceFamily → Type 1    -- typed storage capabilities f uses
f.Requirements.infer    : [capabilities…] → f.Requirements resources
f.portableRequirements  : f.Requirements portableResources
f.flowWithResources     : {resources} → f.Requirements resources → {Scope} → (args…) →
                          Flow kind Scope ε α resources
f.Actor                 : Type → Type                -- `fun Scope => SignedIn` (or `Unit`)
f.bodyWithResources     : {resources} → f.Requirements resources → {Scope} → f.Actor Scope →
                          f.Input → Flow kind Scope ε α resources
f.operation             : Operation kind f.Actor f.Input α ε  -- the existing Contract-carrying value
instance : PublishedOperation f kind f.Actor f.Input α ε     -- so `post "/x" f` finds it
```

Limitations (reported as errors): `partial`/opaque helpers, operations stored inside data
constructors, implicit/instance parameters, and argument types that depend on other
arguments cannot be published.

`f.flowWithResources` is `f`'s OWN elaborated body: operation-building definitions are
unfolded, then `portableResources`, its named instances and `OpScope` are abstracted. The
result is re-checked by the kernel. Requirements are exactly the typed capabilities the
body's `DB`/`Query` calls demanded; nothing is inferred from syntax. -/

namespace LeanApp.Domain.Publish
open Lean Meta Elab Command

/-- The portable instances abstracted to requirement binders. -/
def portableInstances : Array Lean.Name :=
  #[``portableEntity, ``portableMember, ``portableProjection, ``portableAuth, ``portableUnique,
    ``portableLink, ``portableColumn]

private def isTarget (c : Lean.Name) : Bool :=
  c == ``portableResources || c == ``OpScope || portableInstances.contains c

/-- Modules that (transitively) import `LeanApp.Domain.Resources`; nothing else can
mention the portable family. -/
private def dependentModules (env : Environment) : Array Bool := Id.run do
  let names := env.header.moduleNames
  let some root := env.getModuleIdx? `LeanApp.Domain.Resources | return names.map fun _ => false
  let mut result : Array Bool := names.map fun _ => false
  -- Module data is stored dependencies-first; iterate to a fixpoint for safety.
  let mut changed := true
  while changed do
    changed := false
    for i in [:names.size] do
      if result[i]! then continue
      let depends := i == root.toNat ||
        env.header.moduleData[i]!.imports.any fun imp =>
          match env.getModuleIdx? imp.module with
          | some j => result[j.toNat]!
          | none => false
      if depends then
        result := result.set! i true
        changed := true
  return result

/-- Optional-argument defaults (`(resources := portableResources)`) do not make a
declaration depend on the portable family. -/
partial def stripDefaults (e : Expr) : Expr :=
  e.replace fun
    | .app (.app (.const ``optParam _) t) _ => some (stripDefaults t)
    | .app (.app (.const ``autoParam _) t) _ => some (stripDefaults t)
    | _ => none

/-- Does constant `c` (transitively) mention the portable family or `OpScope`? -/
partial def mentionsPortable (dependent : Array Bool) (memo : IO.Ref (NameMap Bool)) (c : Lean.Name) : MetaM Bool := do
  if isTarget c then return true
  if let some known := (← memo.get).find? c then return known
  let env ← getEnv
  if let some idx := env.getModuleIdxFor? c then
    unless dependent[idx.toNat]?.getD false do
      memo.modify (·.insert c false)
      return false
  memo.modify (·.insert c false) -- cycle guard
  let some info := env.find? c | return false
  let mut used := (stripDefaults info.type).getUsedConstants
  if let some value := info.value? (allowOpaque := true) then used := used ++ value.getUsedConstants
  let mut result := false
  for d in used do
    if d != c && (← mentionsPortable dependent memo d) then
      result := true
      break
  memo.modify (·.insert c result)
  return result

/-- Unfold every operation-building definition until only `Flow` constructors, generic
library code and the abstraction targets remain. -/
def inlinePortable (e : Expr) : MetaM Expr := do
  let dependent := dependentModules (← getEnv)
  let memo ← IO.mkRef ({} : NameMap Bool)
  Meta.transform e (pre := fun e => do
    match e.getAppFn with
    | .const c us =>
      if isTarget c then return .continue
      unless ← mentionsPortable dependent memo c do return .continue
      match (← getEnv).find? c with
      | some (.defnInfo info) =>
        return .visit ((info.value.instantiateLevelParams info.levelParams us).betaRev e.getAppRevArgs)
      | some (.thmInfo info) =>
        return .visit ((info.value.instantiateLevelParams info.levelParams us).betaRev e.getAppRevArgs)
      | some info =>
        let kind := match info with
          | .opaqueInfo _ => "an opaque or partial definition"
          | .axiomInfo _ => "an axiom"
          | .thmInfo _ => "a theorem"
          | .inductInfo _ => "an inductive type"
          | .ctorInfo _ => "a constructor"
          | .recInfo _ => "a recursor"
          | .quotInfo _ => "a quotient primitive"
          | .defnInfo _ => "a definition"
        throwError "cannot publish: `{c}` is {kind} that depends on the portable storage family; operations must be built from unfoldable definitions"
      | none => throwError "cannot publish: unknown constant `{c}`"
    | _ => return .continue)

/-- Portable-instance applications occurring in `e` (closed, fully applied). -/
def collectInstances (e : Expr) : MetaM (Array Expr) := do
  let mut arities : Array (Lean.Name × Nat) := #[]
  for c in portableInstances do
    let info ← getConstInfo c
    let arity ← forallTelescope info.type fun args _ => pure args.size
    arities := arities.push (c, arity)
  let found ← IO.mkRef (#[] : Array Expr)
  let rec visit (e : Expr) : StateRefT (Std.HashSet Expr) MetaM Unit := do
    if (← get).contains e then return
    modify (·.insert e)
    match e with
    | .app f a => visit f; visit a
    | .lam _ t b _ | .forallE _ t b _ => visit t; visit b
    | .letE _ t v b _ => visit t; visit v; visit b
    | .mdata _ b => visit b
    | .proj _ _ b => visit b
    | _ => pure ()
    if let .const c _ := e.getAppFn then
      if let some (_, arity) := arities.find? (·.1 == c) then
        if e.getAppNumArgs == arity then
          if e.hasLooseBVars then
            throwError "cannot publish: storage capability `{c}` depends on a locally bound type; publish a monomorphic operation"
          unless (← found.get).contains e do found.modify (·.push e)
  (visit e).run' {}
  found.get

/-- Replace each instance application by its binder, then the family and `OpScope`. -/
def abstractTargets (e : Expr) (instances : Array Expr) (binders : Array Expr) (resources scope : Expr) : Expr :=
  let e := e.replace fun sub => (instances.findIdx? (· == sub)).map (binders[·]!)
  e.replace fun
    | .const ``portableResources _ => some resources
    | .const ``OpScope _ => some scope
    | _ => none

structure Node where
  kind : String
  effect : String
  detail : String
  failure : Option String := none
  constraints : List String := []

private def stringLit? : Expr → Option String
  | .lit (.strVal s) => some s
  | .mdata _ e => stringLit? e
  | _ => none

/-- Identity literals of a literal `List (Constraint C)`. -/
private partial def constraintIdentities (e : Expr) : List String :=
  if e.isAppOfArity ``List.cons 3 then
    let head := e.appFn!.appArg!
    let rest := constraintIdentities e.appArg!
    if head.isAppOf ``Constraint.mk then
      match head.getAppArgs[1]? >>= stringLit? with
      | some identity => identity :: rest
      | none => rest
    else rest
  else []

/-- Ordered storage steps and guards of the unfolded body, for `#domain_inspect`. -/
partial def scanNodes (e : Expr) : MetaM (Array Node) := do
  let out ← IO.mkRef (#[] : Array Node)
  let failureOf (err : Expr) : MetaM (Option String) := do
    match err.getAppFn with
    | .const c _ => if err.getAppNumArgs == 0 then return some c.getString! else return none
    | _ => return none
  let seen ← IO.mkRef (Std.HashSet.emptyWithCapacity 64 : Std.HashSet Expr)
  let rec visit (e : Expr) : MetaM Unit := do
    if (← seen.get).contains e then return
    seen.modify (·.insert e)
    match e with
    | .app .. =>
      let fn := e.getAppFn
      let args := e.getAppArgs
      if let .const c _ := fn then
        if c.getPrefix == ``RequestF then
          let kind := c.getString!
          let effect := if ["insert", "update", "delete", "create", "change", "remove", "include", "signUp", "signIn",
              "hashPassword", "verifyCredential", "startSession"].contains kind
            then "command" else "query"
          let entity ← forallTelescope (← getConstInfo c).type fun binders _ => do
            let names ← binders.mapM fun b => return (← b.fvarId!.getDecl).userName
            match names.findIdx? (· == `T) with
            | some i => match args[i]? with
              | some (.const t _) => return t.toString
              | _ => return ""
            | none => return ""
          let constraints := if ["insert", "update", "create", "change"].contains kind then
              (args.back?.map constraintIdentities).getD []
            else []
          out.modify (·.push { kind, effect, detail := entity, constraints })
        else if (c == ``FlowF.check || c == ``Flow.check || c == ``MonadRequire.requireWith) && args.size >= 6 &&
            !args.back!.hasLooseBVars then
          out.modify (·.push { kind := "require", effect := "query", detail := "", failure := ← failureOf args.back! })
        else if (c == ``FlowF.fail || c == ``Flow.fail || c == ``MonadExcept.throw || c == ``MonadExceptOf.throw) &&
            args.size ≥ 4 && !args.back!.hasLooseBVars then
          out.modify (·.push { kind := "throw", effect := "query", detail := "", failure := ← failureOf args.back! })
      visit fn
      for arg in args do visit arg
    | .lam _ _ b _ => visit b
    | .forallE .. => pure ()
    | .letE _ _ v b _ => visit v; visit b
    | .mdata _ b => visit b
    | .proj _ _ b => visit b
    | _ => pure ()
  visit e
  out.get

/-- KDF steps the body can reach, keyed by the input field each consumes (decision 4). A KDF
input that is not one of the operation's own (non-actor) arguments cannot be prepared before
writer admission, so it is a publication error. -/
def kdfSteps (f : Lean.Name) (params : Array Lean.Name) (actors : Array Bool) (inlined : Expr) : MetaM (List KdfStep) :=
  lambdaTelescope inlined fun binders body => do
    let steps ← IO.mkRef (#[] : Array KdfStep)
    let mut failure : Option String := none
    let check (kind : String) (password : Expr) : MetaM (Option String) := do
      match binders.findIdx? (· == password) with
      | some i =>
        if i < params.size then
          if actors[i]! then return some s!"its {kind} input is the actor"
          return none
        else return some s!"its {kind} input is not an argument of `{f}`"
      | none => return some s!"`{kind}` must be applied directly to a `Password` argument of `{f}`"
    let found ← IO.mkRef (#[] : Array (String × Expr))
    body.forEach fun e => do
      if e.isAppOfArity ``RequestF.hashPassword 4 then found.modify (·.push ("Password.hash", e.appArg!))
      if e.isAppOfArity ``RequestF.verifyCredential 11 then found.modify (·.push ("Credential.verify", e.appArg!))
    for (kind, password) in ← found.get do
      if let some problem ← check kind password then
        failure := some problem
      else
        let i := (binders.findIdx? (· == password)).getD 0
        let field := params[i]!.toString
        let step := if kind == "Password.hash" then KdfStep.hash field else KdfStep.verify field
        unless (← steps.get).contains step do steps.modify (·.push step)
    if let some problem := failure then
      throwError "cannot publish `{f}`: {problem}, so the runtime cannot run the KDF before writer admission"
    return (← steps.get).toList

/-- A parameter of a published function. -/
structure Parameter where
  name : Lean.Name
  type : Expr
  actor : Bool
  deriving Inhabited

/-- Is `type` an actor (a `Principal` instance, or `Option` of one)? -/
def isActorType (type : Expr) : MetaM Bool := do
  let candidate := if type.isAppOfArity ``Option 1 then type.appArg! else type
  return (← synthInstance? (mkApp (mkConst ``Principal) candidate)).isSome

/-- Shape of a published function: parameters, kind, error and output. -/
structure Shape where
  params : Array Parameter
  kind : Contract.OperationKind
  error : Expr
  output : Expr

def shapeOf (f : Lean.Name) : MetaM Shape := do
  let info ← getConstInfo f
  unless info.levelParams.isEmpty do throwError "cannot publish `{f}`: universe-polymorphic operations are not supported"
  forallTelescope info.type fun args result => do
    let (kind, error, output) ← match result.getAppFn, result.getAppArgs with
      | .const ``LeanApp.Domain.Op _, #[ε, α] => pure (Contract.OperationKind.command, ε, α)
      | .const ``LeanApp.Domain.ReadOp _, #[ε, α] => pure (Contract.OperationKind.query, ε, α)
      | _, _ => throwError "cannot publish `{f}`: its result type{indentExpr result}\nmust be `Op ε α` (read-write) or `ReadOp ε α` (read-only)"
    let mut params := #[]
    let mut actors := 0
    for arg in args do
      let decl ← arg.fvarId!.getDecl
      unless decl.binderInfo.isExplicit do
        throwError "cannot publish `{f}`: parameter `{decl.userName}` must be explicit"
      if decl.type.hasAnyFVar (fun fvar => args.contains (.fvar fvar)) then
        throwError "cannot publish `{f}`: the type of parameter `{decl.userName}` depends on another parameter"
      let actor ← isActorType decl.type
      if actor then actors := actors + 1
      if actors > 1 then throwError "cannot publish `{f}`: at most one actor (`SignedIn`/`Option SignedIn`) parameter is supported"
      params := params.push { name := decl.userName.eraseMacroScopes, type := decl.type, actor }
    if error.hasAnyFVar (fun fvar => args.contains (.fvar fvar)) || output.hasAnyFVar (fun fvar => args.contains (.fvar fvar)) then
      throwError "cannot publish `{f}`: the error and output types must not depend on the arguments"
    return { params, kind, error, output }

/-- Constructor names of a closed error type, in declaration order. -/
def failuresOf (error : Expr) : MetaM (List String) := do
  match error.getAppFn with
  | .const c _ =>
    match (← getEnv).find? c with
    | some (.inductInfo info) => return info.ctors.map (·.getString!)
    | _ => return []
  | _ => return []

/-- Run a generated declaration through the kernel and compiler. -/
def addDefinition (name : Lean.Name) (type value : Expr) : MetaM Unit := do
  let type ← instantiateMVars type
  let value ← instantiateMVars value
  if type.hasMVar || value.hasMVar then throwError "internal: unresolved metavariables in generated `{name}`"
  let hints := ReducibilityHints.regular (getMaxHeight (← getEnv) value + 1)
  addAndCompile <| .defnDecl { name, levelParams := [], type, value, hints, safety := .safe }

private def kindSyntax : Contract.OperationKind → String
  | .command => "command"
  | .query => "query"

/-- Order instance applications so that every one comes after those it contains. -/
partial def dependencyOrder (pending : Array Expr) (done : Array Expr := #[]) : Array Expr :=
  if pending.isEmpty then done else
  let ready := pending.filter fun a => !pending.any fun b => b != a && (a.find? (· == b)).isSome
  let ready := if ready.isEmpty then pending else ready
  dependencyOrder (pending.filter (!ready.contains ·)) (done ++ ready)

/-- Bind one instance-implicit capability per portable instance, abstracting earlier ones. -/
partial def withCapabilityBinders {β : Type} (sorted : Array Expr) (resources scope : Expr) (i : Nat) (binders : Array Expr)
    (k : Array Expr → MetaM β) : MetaM β := do
  if h : i < sorted.size then
    let type ← inferType sorted[i]
    let type := abstractTargets type (sorted.extract 0 i) binders resources scope
    withLocalDecl (.mkSimple s!"capability{i}") .instImplicit type fun binder =>
      withCapabilityBinders sorted resources scope (i + 1) (binders.push binder) k
  else k binders

/-- Generalize `f`'s body and add `f.Requirements`, `.infer`, `.portableRequirements` and
`f.flowWithResources`. Returns the requirement count and the scanned nodes. -/
def generalize (f : Lean.Name) (shape : Shape) : MetaM (Nat × Array Node × List KdfStep) := do
  let info ← getConstInfo f
  let some value := info.value? | throwError "cannot publish `{f}`: it has no definition body (opaque or partial)"
  let inlined ← inlinePortable value
  let inlinedType ← inlinePortable info.type
  let nodes ← scanNodes inlined
  let kdf ← kdfSteps f (shape.params.map (·.name)) (shape.params.map (·.actor)) inlined
  let instances := (← collectInstances inlined) ++ (← collectInstances inlinedType)
  let instances := instances.foldl (fun acc i => if acc.contains i then acc else acc.push i) #[]
  -- Instances whose arguments contain other instances must come later.
  let sorted := dependencyOrder instances
  withLocalDecl `resources .implicit (mkConst ``ResourceFamily) fun resources => do
  withLocalDecl `Scope .implicit (mkSort Level.one) fun scope => do
  withCapabilityBinders sorted resources scope 0 #[] fun binders => do
    let body := abstractTargets inlined sorted binders resources scope
    let bodyType := abstractTargets inlinedType sorted binders resources scope
    for leftover in [``portableResources, ``OpScope] ++ portableInstances.toList do
      if body.getUsedConstants.contains leftover || bodyType.getUsedConstants.contains leftover then
        throwError "cannot publish `{f}`: its body still depends on `{leftover}` after generalization"
    -- Requirements r := (c0 : …) ×' (c1 : …) ×' … ×' PUnit
    let unitLevel := Level.one.succ
    let mut products : Array Expr := #[mkConst ``PUnit [unitLevel]]
    let mut tuples : Array Expr := #[mkConst ``PUnit.unit [unitLevel]]
    for j in [:binders.size] do
      let i := binders.size - 1 - j
      let binder := binders[i]!
      let α ← inferType binder
      let u ← getLevel α
      let rest := products.back!
      let β ← mkLambdaFVars #[binder] rest
      let v ← getLevel rest
      products := products.push (mkApp2 (mkConst ``PSigma [u, v]) α β)
      tuples := tuples.push (mkApp4 (mkConst ``PSigma.mk [u, v]) α β binder tuples.back!)
    let requirementsBody := products.back!
    let requirementsName := f ++ `Requirements
    addDefinition requirementsName (← mkArrow (mkConst ``ResourceFamily) (mkSort Level.one.succ))
      (← mkLambdaFVars #[resources] requirementsBody)
    let inferValue ← mkLambdaFVars (#[resources] ++ binders) tuples.back!
    let inferType' ← mkForallFVars (#[resources] ++ binders) (mkApp (mkConst requirementsName) resources)
    addDefinition (requirementsName ++ `infer) inferType' inferValue
    addDefinition (f ++ `portableRequirements) (mkApp (mkConst requirementsName) (mkConst ``portableResources))
      (mkAppN (mkConst (requirementsName ++ `infer)) (#[mkConst ``portableResources] ++ sorted))
    -- flowWithResources {resources} (requirements) {Scope} args… := body[capability_i := requirements.i]
    withLocalDecl `requirements .default (mkApp (mkConst requirementsName) resources) fun requirements => do
      let mut projections : Array Expr := #[]
      let mut cursor := requirements
      for _ in [:binders.size] do
        projections := projections.push (← mkAppM ``PSigma.fst #[cursor])
        cursor ← mkAppM ``PSigma.snd #[cursor]
      let body' := body.replaceFVars binders projections
      let bodyType' := bodyType.replaceFVars binders projections
      let value ← mkLambdaFVars #[resources, requirements, scope] body'
      let type ← mkForallFVars #[resources, requirements, scope] bodyType'
      check value
      unless ← isDefEq (← inferType value) type do
        throwError "internal: generalized body of `{f}` does not have the generalized type"
      addDefinition (f ++ `flowWithResources) type value
    return (binders.size, nodes, kdf)

/-- Generate the `Operation` value and its input record for a published function. -/
def deriveOperation (f : Lean.Name) (ref : Syntax) : CommandElabM Unit := do
  if (← getEnv).contains (f ++ `operation) then return
  let shape ← liftTermElabM <| shapeOf f
  -- Wire codecs for authored value types (error, output, inputs) declared in this module.
  Deriving.ensureWire shape.error
  Deriving.ensureWire shape.output
  for param in shape.params do
    unless param.actor do Deriving.ensureWire param.type
  for (what, ty) in [("error", shape.error), ("output", shape.output)] ++
      (shape.params.filter (!·.actor)).toList.map (fun p => (s!"argument `{p.name}`", p.type)) do
    unless ← liftTermElabM (return (← synthInstance? (mkApp (mkConst ``Ontology.Wire) ty)).isSome) do
      throwErrorAt ref "cannot publish `{f}`: the {what} type {← liftTermElabM (ppExpr ty)} has no wire codec (entities, rows and actors are never published)"
  let inputs := shape.params.filter (!·.actor)
  let full := Deriving.full
  let inputName := f ++ `Input
  if inputs.isEmpty then
    Deriving.runCommand ("abbrev " ++ full inputName ++ " := Unit")
  else
    let fields ← liftTermElabM <| inputs.mapM (m := TermElabM) fun p => do
      return p.name.toString ++ " : " ++ (← Deriving.sourceOf p.type)
    Deriving.runCommand ("structure " ++ full inputName ++ " where\n  " ++ String.intercalate "\n  " fields.toList ++ "\n  deriving LeanApp.Domain.Domain")
    if inputs.size == 1 && (← liftTermElabM (whnfR inputs[0]!.type)).isAppOfArity ``Ontology.EntityId 1 then
      let target ← liftTermElabM do Deriving.sourceOf (← whnfR inputs[0]!.type).appArg!
      Deriving.runCommand ("instance : LeanApp.Domain.RouteInput " ++ full inputName ++ " := { Target := " ++ target ++
        ", targetIdentity := inferInstance, parse := fun raw => (LeanApp.Domain.Ref.parse (T := " ++ target ++ ") raw).map " ++
        full inputName ++ ".mk, reference := " ++ full (inputName ++ inputs[0]!.name) ++ " }")
  let (_, nodes, kdf) ← liftTermElabM <| generalize f shape
  -- bodyWithResources {resources} requirements {Scope} actor input := flowWithResources … (actor | input.field)…
  liftTermElabM do
    let flow := mkConst (f ++ `flowWithResources)
    forallTelescope (← inferType flow) fun outer result => do
      let resources := outer[0]!
      let requirements := outer[1]!
      let scope := outer[2]!
      let args := outer.extract 3 outer.size
      let actorFamily ← if let some i := shape.params.findIdx? (·.actor) then mkLambdaFVars #[scope] (← inferType args[i]!)
        else pure (.lam `Scope (mkSort Level.one) (mkConst ``Unit) .default)
      addDefinition (f ++ `Actor) (← mkArrow (mkSort Level.one) (mkSort Level.one)) actorFamily
      let inputType := mkConst inputName
      withLocalDecl `actor .default (mkApp (mkConst (f ++ `Actor)) scope) fun actor => do
      withLocalDecl `input .default inputType fun input => do
        let mut callArgs := #[]
        for p in shape.params do
          if p.actor then callArgs := callArgs.push actor
          else callArgs := callArgs.push (← mkAppM (inputName ++ p.name) #[input])
        let invocation := mkAppN flow (#[resources, requirements, scope] ++ callArgs)
        let binders := #[resources, requirements, scope, actor, input]
        addDefinition (f ++ `bodyWithResources) (← mkForallFVars binders result) (← mkLambdaFVars binders invocation)
  let ns := f.getPrefix
  let namespaceText := if ns.isAnonymous then "domain" else ns.toString
  let q := Deriving.quoted
  let identity := "{ namespaceName := " ++ q namespaceText ++ ", name := " ++ q f.getString! ++ ", version := \"1\" }"
  let failures ← liftTermElabM <| failuresOf shape.error
  let actorText ← liftTermElabM do
    if let some p := shape.params.find? (·.actor) then return (← ppExpr p.type).pretty else return "Unit"
  let nodesText := String.intercalate ", " (nodes.toList.map fun n =>
    "{ kind := " ++ q n.kind ++ ", effect := ." ++ n.effect ++ ", detail := " ++ q n.detail ++
    ", failure := " ++ (n.failure.map (fun s => "some " ++ q s) |>.getD "none") ++
    ", constraints := [" ++ String.intercalate ", " (n.constraints.map q) ++ "] }")
  let pos := (ref.getPos?.map fun position => position.byteIdx).getD 0
  let location := (← getEnv).mainModule.toString.replace "." "/" ++ ".lean:" ++ toString pos
  let kdfText := String.intercalate ", " (kdf.map fun
    | .hash field => "LeanApp.Domain.KdfStep.hash " ++ q field
    | .verify field => "LeanApp.Domain.KdfStep.verify " ++ q field)
  let session := nodes.any (·.kind == "startSession")
  let metadata := "{ identity := " ++ identity ++ ", kind := ." ++ kindSyntax shape.kind ++ ", failures := [" ++
    String.intercalate ", " (failures.map q) ++ "], source := " ++ q location ++ ", actor := " ++ q actorText ++
    ", nodes := [" ++ nodesText ++ "], establishesSession := " ++ toString session ++ ", kdf := [" ++ kdfText ++ "] }"
  let errorText ← liftTermElabM <| Deriving.sourceOf shape.error
  let outputText ← liftTermElabM <| Deriving.sourceOf shape.output
  Deriving.runCommand ("def " ++ full (f ++ `operation) ++ " : LeanApp.Domain.Operation ." ++ kindSyntax shape.kind ++ " " ++
    full (f ++ `Actor) ++ " " ++ full inputName ++ " (" ++ outputText ++ ") (" ++ errorText ++ ") := { contract := Contract.Operation.ofValidated ." ++
    kindSyntax shape.kind ++ " " ++ identity ++ " (by decide), Requirements := " ++ full (f ++ `Requirements) ++
    ", portable := " ++ full (f ++ `portableRequirements) ++ ", bodyWithResources := " ++ full (f ++ `bodyWithResources) ++
    ", metadata := " ++ metadata ++ " }")
  -- `post "/x" f` / `get "/x" f` find the operation through the function value.
  if (← getEnv).contains `LeanApp.Domain.PublishedOperation then
    Deriving.runCommand ("instance : LeanApp.Domain.PublishedOperation " ++ full f ++ " ." ++ kindSyntax shape.kind ++ " " ++
      full (f ++ `Actor) ++ " " ++ full inputName ++ " (" ++ outputText ++ ") (" ++ errorText ++ ") := ⟨" ++ full (f ++ `operation) ++ "⟩")

end LeanApp.Domain.Publish

namespace LeanApp.Domain
open Lean Elab Command

/-- Publish a plain operation: derive its input record, closed error, output, actor,
typed requirements and resource-generic body. An `Api` declaration runs this for each
listed function. -/
syntax (name := deriveOperationCmd) "derive_operation " ident : command

elab_rules : command
  | `(derive_operation $f:ident) => do
    let name ← liftCoreM <| realizeGlobalConstNoOverload f
    Publish.deriveOperation name f

/-- `#domain_inspect f` for a published plain operation shows its derived metadata. -/
elab_rules : command
  | `(#domain_inspect $f:ident) => do
    let name ← liftCoreM <| realizeGlobalConstNoOverload f
    unless (← getEnv).contains (name ++ `operation) do throwUnsupportedSyntax
    let op := mkIdent (name ++ `operation)
    elabCommand (← `(#eval ($op).metadata))
    elabCommand (← `(#eval ($op).contract.describe))
end LeanApp.Domain
