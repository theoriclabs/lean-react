import Lean
import Lean.Compiler.LCNF.ToDecl
import LeanJS.Hooks
import LeanJS.Declarations
import LeanJS.Modules

open Lean Compiler LCNF

namespace LeanJS

/-- An explicit trusted host adapter. Arity includes type/proof argument slots. -/
structure Intrinsic where
  leanName : Name
  module : String
  exportName : String
  arity : Nat
  deriving Inhabited

structure Options where
  intrinsics : Array Intrinsic := #[]
  hooks : HookConfig := {}
  /-- Host representations that must not be described using native-reference fields. -/
  opaqueTypes : Array Name := #[`LeanReact.Hook, `LeanReact.Action, `LeanReact.Element, `LeanReact.Context, `LeanReact.Cell]
  /-- Set when publishing an importable library. Standalone output needs no identity. -/
  library : Option LibraryId := none
  /-- Shared declarations are imported by identity, without recompiling or rewrapping. -/
  libraries : Array LibraryImport := #[]
  deriving Inhabited

private def quote (s : String) : String := (Json.str s).compress
private def joined (xs : Array String) : String := String.intercalate ", " xs.toList
private def ident (n : Name) : String :=
  "n" ++ String.join (n.toString.toList.map fun c => "_" ++ toString c.toNat)
private def varName (vars : Std.HashMap FVarId String) (f : FVarId) : String := vars[f]!

private structure Builtin where
  name : Name
  arity : Nat
  body : String

/-- The private `where` helper `n` of a core module, as LCNF names it. -/
private def corePrivate (module n : Name) : Name :=
  (Name.mkNum (`_private ++ module) 0) ++ n

private def builtin (n : Name) : Option Builtin := do
  let (_, arity, body) ← (#[
    (`Nat.add, 2, "(a,b)=>a+b"), (`Nat.sub, 2, "$natSub"),
    (`Nat.mul, 2, "(a,b)=>a*b"), (`Nat.div, 2, "$natDiv"),
    (`Nat.mod, 2, "$natMod"), (`Nat.pow, 2, "(a,b)=>a**b"),
    (`Nat.beq, 2, "(a,b)=>$bool(a===b)"),
    (`Nat.ble, 2, "(a,b)=>$bool(a<=b)"), (`Nat.blt, 2, "(a,b)=>$bool(a<b)"),
    (`Nat.decEq, 2, "(a,b)=>$dec(a===b)"),
    (`Nat.decLe, 2, "(a,b)=>$dec(a<=b)"), (`Nat.decLt, 2, "(a,b)=>$dec(a<b)"),
    (`Nat.repr, 1, "a=>a.toString()"),
    (`Int.add, 2, "(a,b)=>a+b"), (`Int.sub, 2, "(a,b)=>a-b"),
    (`Int.mul, 2, "(a,b)=>a*b"), (`Int.neg, 1, "a=>-a"),
    (`Int.ediv, 2, "$ediv"), (`Int.emod, 2, "$emod"),
    (`Int.tdiv, 2, "(a,b)=>b===0n?0n:a/b"), (`Int.tmod, 2, "(a,b)=>b===0n?a:a%b"),
    (`Int.natAbs, 1, "a=>a<0n?-a:a"), (`Int.toNat, 1, "a=>a<0n?0n:a"),
    (`Int.decEq, 2, "(a,b)=>$dec(a===b)"),
    (`Int.decLe, 2, "(a,b)=>$dec(a<=b)"), (`Int.decLt, 2, "(a,b)=>$dec(a<b)"),
    (`Int.repr, 1, "a=>a.toString()"),
    (`String.append, 2, "(a,b)=>a+b"), (`String.length, 1, "s=>BigInt(Array.from(s).length)"),
    (`String.isEmpty, 1, "s=>$bool(s.length===0)"),
    (`String.decEq, 2, "(a,b)=>$dec(a===b)"),
    (`String.decidableLT, 2, "(a,b)=>$dec($stringCompare(a,b))"),
    (`String.toList, 1, "s=>$list(Array.from(s,$char))"),
    (`String.ofList, 1, "xs=>$array(xs).map(c=>String.fromCodePoint(Number($codepoint(c)))).join('')"),
    (`String.singleton, 1, "c=>String.fromCodePoint(Number($codepoint(c)))"),
    (`String.push, 2, "(s,c)=>s+String.fromCodePoint(Number($codepoint(c)))"),
    -- Scalar-indexed slicing; the Lean reference bodies live in LeanJS.Portable.
    (`String.takeScalars, 2, "$takeScalars"), (`String.dropScalars, 2, "$dropScalars"),
    (`String.extractScalars, 3, "$extractScalars"), (`String.scalarLength, 1, "$scalarLength"),
    (`String.foldlScalars, 4, "(_,f,z,s)=>$foldlScalars(f,z,s)"), (`String.ofScalars, 1, "$ofScalars"),
    (`Char.toNat, 1, "$codepoint"), (`Char.ofNat, 1, "$charOfNat"),
    (`instDecidableEqChar, 2, "(a,b)=>$dec($codepoint(a)===$codepoint(b))"),
    (`Char.instDecidableLt, 2, "(a,b)=>$dec($codepoint(a)<$codepoint(b))"),
    (`Char.instDecidableLe, 2, "(a,b)=>$dec($codepoint(a)<=$codepoint(b))"),
    (`Array.mk, 2, "(_,xs)=>$array(xs)"),
    (`List.toArray, 2, "(_,xs)=>$array(xs)"),
    (`List.toArrayImpl, 2, "(_,xs)=>$array(xs)"),
    (`Array.toList, 2, "(_,xs)=>$list(xs)"),
    (`Array.empty, 1, "_=>[]"), (`Array.emptyWithCapacity, 2, "(_,n)=>[]"),
    (`Array.mkEmpty, 2, "(_,n)=>[]"), (`Array.size, 2, "(_,xs)=>BigInt(xs.length)"),
    (`Array.push, 3, "(_,xs,x)=>xs.concat([x])"),
    (`Array.get!Internal, 4, "(_,inh,xs,i)=>$get(xs,i)"),
    (`Array.getInternal, 4, "(_,xs,i,h)=>$get(xs,i)"),
    (`Array.getD, 4, "(_,xs,i,d)=>i<BigInt(xs.length)?xs[Number(i)]:d"),
    (`Array.set, 5, "(_,xs,i,x,h)=>$set(xs,i,x)"),
    (`Array.set!, 4, "(_,xs,i,x)=>$set(xs,i,x)"),
    (`Array.foldl, 7, "(_,__,f,z,xs,start,stop)=>$foldl(f,z,xs,start,stop)"),
    (`Array.filter, 5, "(_,p,xs,start,stop)=>$filter(p,xs,start,stop)"),
    (`Array.map, 4, "(_,__,f,xs)=>xs.map(x=>$app(f,[x]))"),
    (`Array.pop, 2, "(_,xs)=>xs.slice(0,-1)"),
    (`Array.append, 3, "(_,xs,ys)=>xs.concat(ys)"),
    (`Array.extract, 4, "(_,xs,start,stop)=>$extract(xs,start,stop)"),
    (`Array.zipWith, 6, "(_,__,___,f,xs,ys)=>$zipWith(f,xs,ys)"),
    (`Array.zip, 4, "(_,__,xs,ys)=>$zipWith($prod,xs,ys)"),
    (`Array.foldr, 7, "(_,__,f,z,xs,start,stop)=>$foldr(f,z,xs,start,stop)"),
    (`Array.findIdx?, 3, "(_,p,xs)=>$findIdx(p,xs)"),
    (`Array.insertIdx, 5, "(_,xs,i,x,h)=>$insertIdx(xs,i,x)"),
    (`Array.insertIdx!, 4, "(_,xs,i,x)=>$insertIdx(xs,i,x)"),
    (`Array.eraseIdx, 4, "(_,xs,i,h)=>$eraseIdx(xs,i)"),
    (`Array.eraseIdx!, 3, "(_,xs,i)=>$eraseIdx(xs,i)"),
    (`List.length, 2, "(_,xs)=>$listLength(xs)"),
    (`List.lengthTR, 2, "(_,xs)=>$listLength(xs)"),
    (`List.lengthTRAux, 3, "(_,xs,n)=>n+$listLength(xs)"),
    (`List.foldl, 5, "(_,__,f,z,xs)=>$listFoldl(f,z,xs)"),
    (`List.map, 4, "(_,__,f,xs)=>$listMap(f,xs)"),
    (`List.mapTR, 4, "(_,__,f,xs)=>$listMap(f,xs)"),
    (`List.mapTR.loop, 5, "(_,__,f,xs,acc)=>$listAppend($listReverse(acc),$listMap(f,xs))"),
    (`List.flatMap, 4, "(_,__,f,xs)=>$listFlatMap(f,xs)"),
    (`List.flatMapTR, 4, "(_,__,f,xs)=>$listFlatMap(f,xs)"),
    (`List.append, 3, "(_,xs,ys)=>$listAppend(xs,ys)"),
    (`List.appendTR, 3, "(_,xs,ys)=>$listAppend(xs,ys)"),
    (`List.filter, 3, "(_,p,xs)=>$listFilter(p,xs)"),
    (`List.filterTR, 3, "(_,p,xs)=>$listFilter(p,xs)"),
    (`List.filterTR.loop, 4, "(_,p,xs,acc)=>$listAppend($listReverse(acc),$listFilter(p,xs))"),
    (`List.reverse, 2, "(_,xs)=>$listReverse(xs)"),
    (`List.reverseAux, 3, "(_,xs,acc)=>$listReverseAux(xs,acc)"),
    (`List.take, 3, "(_,n,xs)=>$listTake(n,xs)"),
    (`List.takeTR, 3, "(_,n,xs)=>$listTake(n,xs)"),
    (corePrivate `Init.Data.List.Impl `List.takeTR.go, 5, "(_,l,xs,n,acc)=>$listTakeGo(l,xs,n,acc)"),
    (`List.drop, 3, "(_,n,xs)=>$listDrop(n,xs)"),
    (`List.splitAt, 3, "(_,n,xs)=>$listSplitAt(n,xs)"),
    (`List.splitAt.go, 5, "(_,l,xs,n,acc)=>$listSplitAtGo(l,xs,n,acc)"),
    (`List.zip, 4, "(_,__,xs,ys)=>$listZipWith($prod,xs,ys)"),
    (`List.zipWith, 6, "(_,__,___,f,xs,ys)=>$listZipWith(f,xs,ys)"),
    (`List.zipWithTR, 6, "(_,__,___,f,xs,ys)=>$listZipWith(f,xs,ys)"),
    (corePrivate `Init.Data.List.Impl `List.zipWithTR.go, 7, "(_,__,___,f,xs,ys,acc)=>$listAppend($list(acc),$listZipWith(f,xs,ys))"),
    (`List.zipIdx, 3, "(_,xs,n)=>$listZipIdx(xs,n)"),
    (`List.zipIdxTR, 3, "(_,xs,n)=>$listZipIdx(xs,n)"),
    (`List.replicate, 3, "(_,n,x)=>$listReplicate(n,x)"),
    (`List.replicateTR, 3, "(_,n,x)=>$listReplicate(n,x)"),
    (`List.replicateTR.loop, 4, "(_,x,n,acc)=>$listReplicate(n,x,acc)"),
    (`List.range, 1, "n=>$listRange(n)"), (`List.range.loop, 2, "(n,acc)=>$listRange(n,acc)"),
    (`List.range', 3, "$listRangeFrom"), (`List.range'TR, 3, "$listRangeFrom"),
    (`List.range'TR.go, 4, "$listRangeGo"),
    (`List.foldr, 5, "(_,__,f,z,xs)=>$listFoldr(f,z,xs)"),
    (`List.foldrTR, 5, "(_,__,f,z,xs)=>$listFoldr(f,z,xs)"),
    (`List.getLast?, 2, "(_,xs)=>$listLastOpt(xs)"), (`List.getLast, 3, "(_,xs,h)=>$listLast(xs)"),
    (`List.all, 3, "(_,xs,p)=>$listAll(xs,p)"), (`List.any, 3, "(_,xs,p)=>$listAny(xs,p)")
  ] : Array (Name × Nat × String)).find? (·.1 == n)
  return ⟨n, arity, body⟩

private structure State where
  visited : NameSet := {}
  declarations : Array String := #[]
  imports : Array String := #[]
  metadata : Array Json := #[]
  constructors : Array Json := #[]
  constructorNames : NameSet := {}
  hookPlans : Array Json := #[]
  initializers : Array Name := #[]
  usedLibraries : Array Nat := #[]

private structure Context where
  options : Options
  exports : Array Name := #[]
  vars : Std.HashMap FVarId String := {}

private abbrev M := ReaderT Context (StateRefT State CoreM)

private partial def binders (code : Code .pure) : Array FVarId := Id.run do
  match code with
  | .let d k => return #[d.fvarId] ++ binders k
  | .fun d k | .jp d k => return #[d.fvarId] ++ d.params.map (·.fvarId) ++ binders d.value ++ binders k
  | .cases c =>
    let mut out := #[]
    for a in c.alts do
      match a with
      | .alt _ ps k => out := out ++ ps.map (·.fvarId) ++ binders k
      | .default k => out := out ++ binders k
    return out
  | .return .. | .jmp .. | .unreach .. => return #[]

private def nameVars (ids : Array FVarId) : Std.HashMap FVarId String := Id.run do
  let mut out := {}
  for i in [:ids.size] do out := out.insert ids[i]! s!"v{i}"
  return out

private def fail (path : Array Name) (reason : String) : M α :=
  throwError "LeanJS: {reason}\nDependency path: {String.intercalate " -> " (path.toList.map toString)}\nSupply a named intrinsic adapter or move this dependency outside portable code."

private def recordConstructor (n : Name) : M Unit := do
  if (← get).constructorNames.contains n then return
  let .ctorInfo c ← getConstInfo n | return
  let fieldInfo ← Meta.MetaM.run' <| Meta.forallTelescope c.type fun xs _ => do
    xs[c.numParams...*].toArray.mapM fun x => do
      let decl ← x.fvarId!.getDecl
      let erased ← Meta.isProp decl.type <||> Meta.isTypeFormer x
      return Json.mkObj [("name", toJson decl.userName.toString),
        ("type", toJson (← Meta.ppExpr decl.type).pretty), ("erased", toJson erased)]
  modify fun s => { s with
    constructorNames := s.constructorNames.insert n
    constructors := s.constructors.push (Json.mkObj [("name", toJson n.toString),
      ("type", toJson c.induct.toString), ("parameters", toJson c.numParams),
      ("fields", toJson c.numFields), ("fieldInfo", toJson fieldInfo)]) }

private def arg (vars : Std.HashMap FVarId String) : Arg .pure → String
  | .erased | .type .. => "null"
  | .fvar f => varName vars f

private def apply (vars : Std.HashMap FVarId String) (f : String) (args : Array (Arg .pure)) : String :=
  if args.isEmpty then f else s!"$app({f}, [{joined (args.map (arg vars))}])"

private def specialField (typeName : Name) (idx : Nat) (v : String) : Option String :=
  if typeName == `Nat && idx == 0 then some s!"({v} - 1n)"
  else if typeName == `Int && idx == 0 then some s!"({v} < 0n ? -{v} - 1n : {v})"
  else none

mutual
  private partial def visit (n : Name) (path : Array Name) : M Unit := do
    if (← get).visited.contains n then return
    modify fun s => { s with visited := s.visited.insert n }
    let path := path.push n
    let env ← getEnv
    let some info := env.find? n | fail path "unknown executable declaration"
    let name := ident n
    if let some plan ← HookCheck.validate n (← read).options.hooks ((← read).exports.contains n) then
      modify fun s => {s with hookPlans := s.hookPlans.push plan}
    let sourceType ← Meta.MetaM.run' do return (← Meta.ppExpr info.type).pretty
    for i in [:((← read).options.libraries.size)] do
      let dependency := (← read).options.libraries[i]!
      if let some signature := dependency.interface.exports.find? (·.name == n) then
        modify fun s => { s with
          usedLibraries := if s.usedLibraries.contains i then s.usedLibraries else s.usedLibraries.push i
          imports := s.imports.push s!"import \{ {quote n.toString} as i{name} } from {quote dependency.module};"
          declarations := s.declarations.push s!"const {name} = $lazy(() => i{name});"
          metadata := s.metadata.push (Json.mkObj [("name", toJson n.toString),
            ("arity", toJson signature.arity), ("type", toJson sourceType),
            ("importedFrom", toJson dependency.interface.id)]) }
        return
    if let some ext := (← read).options.intrinsics.find? (·.leanName == n) then
      let arity ← Meta.MetaM.run' <| Meta.forallTelescopeReducing info.type fun xs _ => pure xs.size
      unless arity == ext.arity do
        fail path s!"intrinsic arity mismatch: registered {ext.arity}, Lean declaration has {arity} slots"
      modify fun s => { s with
        initializers := if arity == 0 then s.initializers.push n else s.initializers
        imports := s.imports.push s!"import \{ {quote ext.exportName} as i{name} } from {quote ext.module};"
        declarations := s.declarations.push (if arity == 0 then s!"const {name} = $lazy(() => i{name});" else s!"const {name} = $lazy(() => $fn({arity}, i{name}));")
        metadata := s.metadata.push (Json.mkObj [("name", toJson n.toString), ("arity", toJson arity), ("intrinsic", toJson true), ("type", toJson sourceType)]) }
      return
    if let some b := builtin n then
      let arity ← Meta.MetaM.run' <| Meta.forallTelescopeReducing info.type fun xs _ => pure xs.size
      unless arity == b.arity do fail path s!"builtin arity mismatch: expected {b.arity}, actual {arity}"
      modify fun s => { s with
        declarations := s.declarations.push s!"const {name} = $lazy(() => $fn({b.arity}, {b.body}));"
        metadata := s.metadata.push (Json.mkObj [("name", toJson n.toString), ("arity", toJson b.arity), ("builtin", toJson true), ("type", toJson sourceType)]) }
      return
    if let .ctorInfo c := info then
      if c.induct == `String then fail path "raw String construction is unsupported; use String.ofList or string operations"
      recordConstructor n
      let ps := (Array.range (c.numParams + c.numFields)).map (s!"a{·}")
      let fields := joined ps[c.numParams...*].toArray
      let body := if n == `Nat.zero then "0n"
        else if n == `Nat.succ then "(a0 + 1n)"
        else if n == `Int.ofNat then "a0"
        else if n == `Int.negSucc then "(-a0 - 1n)"
        else s!"$ctor({quote n.toString}, [{fields}])"
      let value := if ps.isEmpty then body else s!"$fn({ps.size}, ({joined ps}) => {body})"
      modify fun s => { s with
        initializers := if ps.isEmpty then s.initializers.push n else s.initializers
        declarations := s.declarations.push s!"const {name} = $lazy(() => {value});"
        metadata := s.metadata.push (Json.mkObj [("name", toJson n.toString), ("arity", toJson ps.size), ("constructor", toJson true), ("type", toJson sourceType)]) }
      return
    if info.isUnsafe then fail path "unsafe declaration has no explicit intrinsic contract"
    -- These core definitions have portable, structurally recursive reference bodies.
    -- Lower those bodies, never their native USize/unsafe replacements. In particular,
    -- retain the caller's Monad dictionary and ForInStep early-exit behavior.
    let portableReference := n == `Array.forIn' || n == `Array.foldlM
    if (getImplementedBy? env n).isSome && !portableReference then
      fail path "implemented_by declaration has no explicit intrinsic contract"
    if (getExternAttrData? env n).isSome then fail path "unsupported native extern operation"
    if hasInitAttr env n then fail path "native initialization is unsupported"
    let d ← try CompilerM.run (toDecl n) catch e => fail path s!"LCNF lowering failed: {← e.toMessageData.toString}"
    unless d.safe do fail path "partial or unsafe recursive declaration is unsupported"
    let .code code := d.value | fail path "native or opaque declaration has no portable body"
    let vars := nameVars (d.params.map (·.fvarId) ++ binders code)
    let body ← withReader (fun ctx => { ctx with vars }) (emitCode code path)
    let varName := varName vars
    let ps := joined (d.params.map (varName ·.fvarId))
    let value := if d.params.isEmpty then s!"(() => \{\n{body}})()" else s!"$fn({d.params.size}, ({ps}) => \{\n{body}})"
    modify fun s => { s with
      initializers := if d.params.isEmpty then s.initializers.push n else s.initializers
      declarations := s.declarations.push s!"const {name} = $lazy(() => {value});"
      metadata := s.metadata.push (Json.mkObj [("name", toJson n.toString), ("arity", toJson d.params.size), ("parameters", toJson (d.params.map fun p => p.binderName.toString)), ("type", toJson sourceType)]) }

  private partial def emitValue (v : LetValue .pure) (path : Array Name) : M String := do
    let vars := (← read).vars
    let varName := varName vars
    let apply := apply vars
    match v with
    | .lit (.nat n) => return s!"{n}n"
    | .lit (.str s) => return quote s
    | .lit _ => fail path "fixed-width LCNF literals are unsupported"
    | .erased => return "null"
    | .fvar f args => return apply (varName f) args
    | .const n _ args =>
      visit n path
      return apply s!"{ident n}()" args
    | .proj t idx f =>
      let v := varName f
      if t == `Array || t == `String then fail path s!"raw projection from native representation {t} is unsupported"
      if let .inductInfo ind ← getConstInfo t then
        for ctor in ind.ctors do recordConstructor ctor
      return (specialField t idx v).getD s!"{v}.fields[{idx}]"

  private partial def emitCode (code : Code .pure) (path : Array Name) : M String := do
    let vars := (← read).vars
    let varName := varName vars
    match code with
    | .let d k =>
      let value ← emitValue d.value path
      return s!"const {varName d.fvarId} = {value};\n{← emitCode k path}"
    | .fun d k | .jp d k =>
      let body ← emitCode d.value path
      let ps := joined (d.params.map (varName ·.fvarId))
      return s!"const {varName d.fvarId} = $fn({d.params.size}, ({ps}) => \{\n{body}});\n{← emitCode k path}"
    | .jmp f args => return s!"return {varName f}({joined (args.map (arg vars))});\n"
    | .return f => return s!"return {varName f};\n"
    | .unreach _ => return "throw new Error('LeanJS: reached impossible branch');\n"
    | .cases c =>
      let v := varName c.discr
      let discr := if c.typeName == `Nat then s!"({v} === 0n ? 'Nat.zero' : 'Nat.succ')"
        else if c.typeName == `Int then s!"({v} < 0n ? 'Int.negSucc' : 'Int.ofNat')"
        else s!"{v}.tag"
      if c.typeName == `Array || c.typeName == `String then fail path s!"raw match on native representation {c.typeName} is unsupported"
      let mut out := s!"switch ({discr}) \{\n"
      let mut hasDefault := false
      for alt in c.alts do
        match alt with
        | .default k =>
          hasDefault := true
          out := out ++ s!"default: \{\n{← emitCode k path}}\n"
        | .alt ctor ps k =>
          recordConstructor ctor
          out := out ++ s!"case {quote ctor.toString}: \{\n"
          for i in [:ps.size] do
            let field := (specialField c.typeName i v).getD s!"{v}.fields[{i}]"
            out := out ++ s!"const {varName ps[i]!.fvarId} = {field};\n"
          out := out ++ (← emitCode k path) ++ "}\n"
      unless hasDefault do out := out ++ "default: throw new Error('LeanJS: invalid constructor tag');\n"
      return out ++ "}\n"
end

/-- A validated ESM module, its ABI declaration file, and a machine-readable manifest. -/
structure Artifacts where
  javascript : String
  declarations : String
  manifest : Json
  library : Option LibraryInterface

/-- Reuse the exact public interface of a producer in the same build program. -/
def Artifacts.asImport (artifacts : Artifacts) (module : String) : Except String LibraryImport :=
  match artifacts.library with
  | some interface => .ok { module, interface }
  | none => .error "LeanJS: set Options.library before importing these artifacts"

private def validateLibraries (options : Options) : CoreM Unit := do
  let mut names : NameSet := {}
  let mut ids : Array LibraryId := #[]
  let mut modules : Array String := #[]
  for dependency in options.libraries do
    let interface := dependency.interface
    unless interface.abi == "leanjs-v0" && interface.lean == "4.33.0" do
      throwError "LeanJS: incompatible library ABI/toolchain: {dependency.module}"
    if options.library == some interface.id then
      throwError "LeanJS: a library cannot import its own identity: {dependency.module}"
    if ids.contains interface.id || modules.contains dependency.module then
      throwError "LeanJS: duplicate library identity or module: {dependency.module}"
    ids := ids.push interface.id
    modules := modules.push dependency.module
    for signature in interface.exports do
      if names.contains signature.name then
        throwError "LeanJS: ambiguous library ownership of {signature.name}"
      if options.intrinsics.any (·.leanName == signature.name) then
        throwError "LeanJS: library/intrinsic overlap for {signature.name}"
      names := names.insert signature.name
      unless (← exportSignature signature.name) == signature do
        throwError "LeanJS: library signature mismatch for {signature.name} in {dependency.module}; rebuild against the same Lean interface"

/-- Compile actual declarations, validate Hook boundaries, and describe the public ABI. -/
def compileArtifacts (exports : Array Name) (options : Options := {}) : CoreM Artifacts := do
  validateLibraries options
  let mut seen : NameSet := {}
  for n in exports do
    if seen.contains n then throwError "LeanJS: duplicate export {n}"
    if n.toString == "__leanjs" || n.toString == "__leanjs_fn" then throwError "LeanJS: reserved export name {n}"
    seen := seen.insert n
  seen := {}
  for i in options.intrinsics do
    if seen.contains i.leanName then throwError "LeanJS: duplicate intrinsic registration for {i.leanName}"
    seen := seen.insert i.leanName
  let (_, s) ← ((exports.forM (visit · #[])).run { options, exports }).run {}
  let library ← options.library.mapM fun id => do
    return ({ id, exports := ← exports.mapM exportSignature } : LibraryInterface)
  let mut out := "// Generated by LeanJS for Lean 4.33.0; ABI v0.\n" ++ String.intercalate "\n" s.imports.toList ++ "\n"
  out := out ++ include_str "Runtime.js"
  for i in s.usedLibraries do
    let dependency := options.libraries[i]!
    out := out ++ s!"\nimport \{ __leanjs as l{i} } from {quote dependency.module};\n"
    out := out ++ s!"$checkLibrary(l{i}, {(toJson dependency.interface).compress});\n"
  out := out ++ "\n" ++ String.intercalate "\n" s.declarations.toList ++ "\n"
  -- All thunks exist before initialization, so forward references remain valid.
  -- A top-level value has module lifetime, including when only used inside render.
  for n in s.initializers do
    out := out ++ s!"{ident n}();\n"
  for n in exports do
    out := out ++ s!"const e{ident n} = {ident n}();\nexport \{ e{ident n} as {quote n.toString} };\n"
  let manifest := Json.mkObj [("abi", toJson "leanjs-v0"), ("lean", toJson "4.33.0"),
    ("library", toJson library),
    ("imports", toJson (s.usedLibraries.map fun i => toJson options.libraries[i]!.interface)),
    ("initialized", toJson (s.initializers.map toString)),
    ("exports", toJson (exports.map toString)), ("declarations", toJson s.metadata),
    ("constructors", toJson s.constructors), ("hookPlans", toJson s.hookPlans)]
  out := out ++ "export { $fn as __leanjs_fn };\n"
  let declarations ← TypeScript.emit exports options.opaqueTypes
  return ⟨out ++ s!"export const __leanjs = {manifest.compress};\n", declarations, manifest, library⟩

/-- Backwards-compatible ESM-only entry point. -/
def compile (exports : Array Name) (options : Options := {}) : CoreM String := do
  return (← compileArtifacts exports options).javascript

/-- Write ESM, .d.ts, .d.mts (Node ESM resolution), and a JSON manifest.
All analysis finishes before any output file is written. -/
def writeModule (path : System.FilePath) (exports : Array Name) (options : Options := {}) : CoreM Unit := do
  let result ← compileArtifacts exports options
  IO.FS.writeFile path result.javascript
  IO.FS.writeFile (path.withExtension "d.ts") result.declarations
  IO.FS.writeFile (path.withExtension "d.mts") result.declarations
  IO.FS.writeFile (path.withExtension "manifest.json") result.manifest.compress

open Elab Command in
elab "#lean_js " file:str " [" names:ident,* "]" : command => do
  let names ← names.getElems.mapM fun stx => liftCoreM <| realizeGlobalConstNoOverloadWithInfo stx
  liftCoreM <| writeModule file.getString names

end LeanJS
