import Lean
import Lean.Compiler.LCNF.ToDecl

open Lean Compiler LCNF
namespace LeanJS

/-- A trusted Hook primitive contract, independent of the host library import. -/
structure HookPrimitive where
  name : Name
  arity : Nat
  kind : String
  siteArg : Nat
  deriving Inhabited

/-- Names defining the Hook execution boundary. Defaults describe the LeanReact ABI. -/
structure HookConfig where
  hookType : Name := `LeanReact.Hook
  componentType : Name := `LeanReact.Component
  elementType : Name := `LeanReact.Element
  actionType : Name := `LeanReact.Action
  pureName : Name := `LeanReact.Hook.pure
  bindName : Name := `LeanReact.Hook.bind
  mapName : Name := `LeanReact.Hook.map
  componentName : Name := `LeanReact.component
  namedName : Name := `LeanReact.Component.named
  componentCtor : Name := `LeanReact.Component.mk
  primitives : Array HookPrimitive := #[
    ⟨`LeanReact.useState, 3, "state", 2⟩,
    ⟨`LeanReact.useEffect, 3, "effect", 2⟩,
    ⟨`LeanReact.useContext, 3, "context", 2⟩]
  /-- Analysis bound; exhausting it is rejection, never successful validation. -/
  fuel : Nat := 50000
  deriving Inhabited

namespace HookCheck
private structure Site where
  primitive : Name
  kind : String
  label : String
  deriving BEq, Inhabited

private def siteJson (s : Site) : Json := Json.mkObj [
  ("primitive", toJson s.primitive.toString), ("kind", toJson s.kind), ("site", toJson s.label)]

/-- Abstract values retain only data needed to prove a static Hook sequence. -/
private inductive Value where
  | unknown
  | string (s : String)
  | constant (n : Name) (bound : Array Value) (relevant : Bool)
  | closure (params : Array (Param .pure)) (body : Code .pure)
      (captured : Array (FVarId × Value)) (relevant : Bool)
  | record (tag : Name) (fields : Array Value)
  | hook (sites : Array Site) (value : Value)
  | component (sites : Array Site)
  | choice (values : Array Value)
  deriving Inhabited

private partial def Value.relevant : Value → Bool
  | .constant _ _ r | .closure _ _ _ r => r
  | .record _ fs | .choice fs => fs.any Value.relevant
  | .hook .. | .component .. => true
  | _ => false

private abbrev Locals := Array (FVarId × Value)
private structure Context where
  config : HookConfig
  path : Array Name := #[]
  active : NameSet := {}
private structure State where
  fuel : Nat
  cache : NameMap (Decl .pure) := {}
private abbrev M := ReaderT Context (StateRefT State CoreM)

private def reject (reason : String) : M α := do
  let path := String.intercalate " -> " ((← read).path.toList.map toString)
  throwError "LeanJS hook placement: {reason}\nHook dependency path: {path}\nUse a fixed Hook sequence through named custom hooks; put conditional/repeated state in child components."

private def step : M Unit := do
  if (← get).fuel == 0 then reject "analysis bound exhausted; this hook program is unsupported"
  modify fun s => {s with fuel := s.fuel - 1}

private def mentions (t : Expr) (n : Name) : Bool := (t.find? (·.isConstOf n)).isSome
private def relevantType (t : Expr) : M Bool := do
  let c := (← read).config
  return mentions t c.hookType || mentions t c.componentType
private def returns (t : Expr) (n : Name) : Bool := t.getForallBody.isAppOf n
private def lookup (env : Locals) (id : FVarId) : Value :=
  ((env.toList.find? (·.1 == id)).map (·.2)).getD .unknown
private def arg (env : Locals) : Arg .pure → Value
  | .fvar id => lookup env id
  | _ => .unknown
private def bind (env : Locals) (ps : Array (Param .pure)) (vs : Array Value) : Locals :=
  (ps.zip vs).map (fun (p,v) => (p.fvarId,v)) ++ env

private partial def merge (a b : Value) : M Value := do
  match a, b with
  | .hook as av, .hook bs bv =>
    unless as == bs do
      reject s!"conditional Hook branches have inconsistent sequences: {(toJson (as.map siteJson)).compress} versus {(toJson (bs.map siteJson)).compress}"
    return .hook as (← merge av bv)
  | .hook .., _ | _, .hook .. => reject "a conditional branch returns an unknown Hook program"
  | _, _ =>
    if !a.relevant && !b.relevant then return .unknown
    return .choice #[a,b]

private def hook (v : Value) : M (Array Site × Value) := do
  match v with
  | .hook ss x => return (ss,x)
  | _ => reject "unknown higher-order/loop Hook result; its first-render sequence cannot be established"

private def getDecl (n : Name) : M (Decl .pure) := do
  if let some d := (← get).cache.find? n then return d
  let d ← try CompilerM.run (toDecl n)
    catch _ => reject s!"cannot inspect Hook dependency {n}; an explicit Hook primitive contract is required"
  modify fun s => {s with cache := s.cache.insert n d}
  return d

mutual
  private partial def call (f : Value) (args : Array Value) : M Value := do
    step
    match f with
    | .constant n bound _ => callConstant n (bound ++ args)
    | .closure ps body env relevant =>
      if args.size < ps.size then
        return .closure ps[args.size...*].toArray body (bind env ps[*...args.size].toArray args) relevant
      let value ← eval body (bind env ps args[*...ps.size].toArray)
      if args.size == ps.size then return value
      call value args[ps.size...*].toArray
    | .choice vs =>
      let mut out : Option Value := none
      for v in vs do
        let v ← call v args
        out := some (← match out with | none => pure v | some old => merge old v)
      return out.getD .unknown
    | _ => return .unknown

  private partial def callConstant (n : Name) (args : Array Value) : M Value := do
    step
    let cfg := (← read).config
    let info ← getConstInfo n
    let type ← Meta.MetaM.run' <| toLCNFType info.type
    let arity := type.getNumHeadForalls
    let relevant ← relevantType type
    if args.size < arity then return .constant n args relevant
    if args.size > arity then
      let v ← callConstant n args[*...arity].toArray
      return ← call v args[arity...*].toArray
    if let some p := cfg.primitives.find? (·.name == n) then
      unless p.arity == arity && p.siteArg < arity do reject s!"incorrect Hook primitive contract for {n}"
      let .string label := args[p.siteArg]! | reject s!"dynamic hook site label in {n}; use a literal stable site"
      return .hook #[⟨n,p.kind,label⟩] .unknown
    let expected := if n == cfg.pureName || n == cfg.componentName then some 2
      else if n == cfg.bindName || n == cfg.mapName then some 4
      else if n == cfg.componentCtor || n == cfg.namedName then some 3 else none
    if let some expected := expected then
      unless arity == expected do reject s!"incorrect Hook API arity for {n}: expected {expected}, found {arity}"
    if n == cfg.pureName then return .hook #[] args[1]!
    if n == cfg.bindName then
      let (before,value) ← hook args[2]!
      let (after,result) ← hook (← call args[3]! #[value])
      return .hook (before ++ after) result
    if n == cfg.mapName then
      let (before,value) ← hook args[3]!
      return .hook before (← call args[2]! #[value])
    if n == cfg.componentName || n == cfg.componentCtor then
      let (sites,_) ← hook (← call args[1]! #[.unknown])
      return .component sites
    if n == cfg.namedName then return args[2]!
    if returns type cfg.elementType || returns type cfg.actionType then return .unknown
    if let .ctorInfo c := info then
      if c.induct == cfg.hookType then reject "raw Hook construction has no static primitive contract"
      return .record n args[c.numParams...*].toArray
    -- Data-only calls (including Element and Action constructors) do not execute Hooks.
    -- Keep dictionaries/functions that carry a Hook value or a Hook-returning callback.
    if !relevant && !(args.any Value.relevant) then return .unknown
    let ctx ← read
    if ctx.active.contains n then reject s!"loop or recursive Hook program through {n} is unsupported"
    if (getExternAttrData? (← getEnv) n).isSome || (getImplementedBy? (← getEnv) n).isSome then
      reject s!"unsupported higher-order/loop or native Hook dependency {n}"
    let d ← getDecl n
    let .code body := d.value | reject s!"opaque Hook dependency {n} has no static contract"
    withReader (fun ctx => {ctx with active := ctx.active.insert n, path := if ctx.path.back? == some n then ctx.path else ctx.path.push n}) do
      eval body (bind #[] d.params args)

  private partial def evalValue (v : LetValue .pure) (env : Locals) : M Value := do
    match v with
    | .lit (.str s) => return .string s
    | .lit _ | .erased => return .unknown
    | .const n _ args => callConstant n (args.map (arg env))
    | .fvar id args =>
      if args.isEmpty then return lookup env id
      call (lookup env id) (args.map (arg env))
    | .proj _ i id =>
      match lookup env id with
      | .record _ fields => return fields[i]?.getD .unknown
      | .choice _ => reject "projection from conditional Hook dictionary/function data is unsupported"
      | _ => return .unknown

  private partial def eval (code : Code .pure) (env : Locals) : M Value := do
    step
    match code with
    | .let d k =>
      let value ← evalValue d.value env
      if d.type.isAppOf (← read).config.hookType then
        let _ ← hook value
      eval k (env.push (d.fvarId,value))
    | .fun d k | .jp d k =>
      let v := Value.closure d.params d.value env (← relevantType d.type)
      eval k (env.push (d.fvarId,v))
    | .return f => return lookup env f
    | .jmp f args => call (lookup env f) (args.map (arg env))
    | .unreach _ => reject "unreachable branch in a Hook program is outside the static subset"
    | .cases c =>
      let mut out : Option Value := none
      for a in c.alts do
        let result ← match a with
          | .alt _ ps k => eval k (bind env ps (Array.replicate ps.size .unknown))
          | .default k => eval k env
        out := some (← match out with | none => pure result | some old => merge old result)
      return out.getD .unknown
end

/-- Validate one exported or reachable Hook/component definition, if applicable.
The result is descriptive static metadata; no host module is imported. -/
def validate (name : Name) (config : HookConfig := {}) (isExport : Bool := true) : CoreM (Option Json) := do
  let info ← getConstInfo name
  let type ← Meta.MetaM.run' <| toLCNFType info.type
  if !(isExport && returns type config.hookType) && !returns type config.componentType then return none
  if #[config.pureName, config.bindName, config.mapName, config.componentName,
      config.namedName, config.componentCtor].contains name || config.primitives.any (·.name == name) then
    return none
  let action : M Json := do
    let d ← getDecl name
    let value ← callConstant name (Array.replicate d.params.size .unknown)
    let sites ← match value with
      | .hook ss _ | .component ss => pure ss
      | _ => reject "exported Hook/component has an unknown or conditional higher-order program"
    return Json.mkObj [("name",toJson name.toString), ("validation",toJson "fixed-hook-sequence-v1"),
      ("sites",toJson (sites.map siteJson))]
  return some (← (action.run {config, path := #[name]}).run' {fuel := config.fuel})
end HookCheck
end LeanJS
