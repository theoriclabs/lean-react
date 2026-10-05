import LeanApp.Domain.Deriving
import LeanApp.Domain.Flow
import Lean.Elab.Command

namespace LeanApp.Domain
open Lean Elab Command

syntax (name := requireStep) "require " term " else " ident (" as " ident)? : doElem
syntax (name := findStep) "let " ident " ← " "find " term:max term " else " ident : doElem
syntax (name := createStep) "create " term:max term : doElem
syntax (name := callStep) "call " term:max term:max term : doElem
syntax (name := removeStep) "remove " term : doElem
syntax (name := includeStep) "include " term " in " term : doElem

declare_syntax_cat domainPatchField
syntax ident : domainPatchField
syntax ident " := " term : domainPatchField
syntax (name := changeStep) "change " term:max " { " domainPatchField,* " }" : doElem

syntax (name := domainDisclosure) "disclose " term:max " do " term : term

syntax (name := authCreateStep) "authCreate " term:max term:max term:max term : doElem
syntax (name := authVerifyStep) "authVerify " term:max term:max term:max term " else " ident : doElem
syntax (name := domainAuth) "auth% " ident " : " term " using " "emailPassword(" ident ")" : command

-- Declarations lower these nodes before elaboration, avoiding hygiene on generated Error names.
syntax (name := domainCommand) "command% " ident bracketedBinder* " : " term " := " term : command
syntax (name := domainQuery) "query% " ident bracketedBinder* " : " term " := " term : command
syntax (name := domainPolicy) "policy% " ident bracketedBinder* " := " term : command
syntax (name := domainUnique) "unique% " ident " := " ident : command

private def runGenerated (source : String) : CommandElabM Unit := do
  match Parser.runParserCategory (← getEnv) `command source with
  | .error message => throwError "Domain elaboration failed: {message}\n{source}"
  | .ok stx => elabCommand stx

private def render (stx : Syntax) : CommandElabM String :=
  match stx.reprint with | some source => pure source | none => throwError "missing domain source"

structure UniqueEntry where
  owner : Lean.Name
  identity : Lean.Name
  field : String
  failure : Lean.Name
  deriving Inhabited

initialize uniqueDeclarations : SimplePersistentEnvExtension UniqueEntry (Array UniqueEntry) ←
  registerSimplePersistentEnvExtension {
    addEntryFn := Array.push
    addImportedFn := fun entries => entries.foldl Array.append #[]
  }

private def createConstraints (stx : Syntax) : CommandElabM (Array UniqueEntry) := do
  let owner ← resolveGlobalConstNoOverload stx[1]
  return (uniqueDeclarations.getState (← getEnv)).filter (fun declaration => declaration.owner == owner)

initialize operationAuthProfiles : SimplePersistentEnvExtension (Lean.Name × Array Lean.Name) (Array (Lean.Name × Array Lean.Name)) ←
  registerSimplePersistentEnvExtension {
    addEntryFn := Array.push
    addImportedFn := fun entries => entries.foldl Array.append #[]
  }

private partial def loadedEntities (stx : Syntax) : CommandElabM (Array (Lean.Name × Lean.Name)) := do
  let mut result := #[]
  if stx.isOfKind ``findStep then
    result := result.push (stx[1].getId, ← resolveGlobalConstNoOverload stx[4])
  for child in stx.getArgs do result := result ++ (← loadedEntities child)
  return result

private def changeConstraints (owners : Array (Lean.Name × Lean.Name)) (stx : Syntax) : CommandElabM (Array UniqueEntry) := do
  let some (_, owner) := owners.find? (fun entry => stx[1].isIdent && entry.1 == stx[1].getId)
    | throwErrorAt stx "change requires a row resolved by a typed find in this flow"
  let fields := stx[3].getSepArgs.map (fun field => field[0].getId.toString)
  return (uniqueDeclarations.getState (← getEnv)).filter fun declaration => declaration.owner == owner && fields.contains declaration.field

private def calleeErrors (stx : Syntax) : CommandElabM (Lean.Name × Array (Lean.Name × Lean.Name)) := do
  let callee ← resolveGlobalConstNoOverload stx[1]
  let info ← getConstInfoInduct (callee ++ `Error)
  return (callee, info.ctors.toArray.map fun ctor =>
    (ctor, Lean.Name.mkSimple (callee.getString! ++ "_" ++ ctor.getString!)))

private partial def failures (owners : Array (Lean.Name × Lean.Name)) (stx : Syntax) : CommandElabM (Array Lean.Name) := do
  let mut result := #[]
  if stx.isOfKind ``requireStep then result := result.push stx[3].getId
  if stx.isOfKind ``findStep then result := result.push stx[7].getId
  if stx.isOfKind ``createStep || stx.isOfKind ``authCreateStep then
    for constraint in ← createConstraints stx do result := result.push constraint.failure
  if stx.isOfKind ``changeStep then
    for constraint in ← changeConstraints owners stx do result := result.push constraint.failure
  if stx.isOfKind ``callStep then
    for (_, failure) in (← calleeErrors stx).2 do result := result.push failure
  if stx.isOfKind ``authVerifyStep then result := result.push stx[6].getId
  for arg in stx.getArgs do
    for name in ← failures owners arg do
      if !result.contains name then result := result.push name
  return result

private partial def projectedFields (subject : Lean.Name) (stx : Syntax) : Array Lean.Name :=
  let here := if stx.isIdent && stx.getId.getPrefix == subject then #[stx.getId.getString! |> Lean.Name.mkSimple] else #[]
  stx.getArgs.foldl (fun acc child => acc ++ projectedFields subject child) here

private partial def selectedTerm (subject field selected : Lean.Name) (stx : Syntax) : Syntax :=
  if stx.isIdent && stx.getId == subject ++ field then mkIdent selected
  else stx.setArgs (stx.getArgs.map (selectedTerm subject field selected))

private partial def loadedNames (stx : Syntax) : Array Lean.Name :=
  let here := if stx.isOfKind ``findStep then #[stx[1].getId] else #[]
  stx.getArgs.foldl (fun acc child => acc ++ loadedNames child) here

private def rowField (rows : Array Lean.Name) (stx : Syntax) : Option Syntax :=
  if stx.isIdent && rows.contains stx.getId.getPrefix &&
      !["id", "value", "membersField", "members"].contains stx.getId.getString! then
    some (mkIdent (stx.getId.getPrefix ++ `value ++ Lean.Name.mkSimple stx.getId.getString!))
  else none

private partial def lower (rows : Array Lean.Name) (owners : Array (Lean.Name × Lean.Name)) (errorName : Lean.Name) (stx : Syntax) : CommandElabM Syntax := do
  if let some access := rowField rows stx then return access
  if stx.isOfKind ``domainDisclosure then
    let policy : TSyntax `term := ⟨← lower rows owners errorName stx[1]⟩
    let projected := stx[3]
    unless projected.isOfKind ``Lean.Parser.Term.app && projected[0].isIdent do
      throwErrorAt projected "disclose requires a declared members.project projection"
    let method := projected[0].getId
    unless method.getString! == "project" do throwErrorAt projected "disclose requires members.project"
    let relation := method.getPrefix
    let row := mkIdent relation.getPrefix
    let relationField := Syntax.mkStrLit relation.getString!
    let mapper : TSyntax `term := ⟨projected[1][0]⟩
    match mapper with
    | `(fun $subject:ident => $mapping:term) =>
      let fields := projectedFields subject.getId mapping
      unless fields.size > 0 && fields.all (· == fields[0]!) do
        throwErrorAt mapping "protected projection currently selects one declared scalar field; other shapes require a checked projection adapter"
      let selected := Lean.Name.mkSimple "selectedValue"
      let transformed : TSyntax `term := ⟨selectedTerm subject.getId fields[0]! selected mapping⟩
      let field := Syntax.mkStrLit fields[0]!.toString
      let valueName := mkIdent selected
      return (← `(LeanApp.Domain.Flow.disclose $policy ((LeanApp.Domain.Projection.memberField (LeanApp.Domain.Row.membersField $row $relationField) $field).map (List.map (fun $valueName => $transformed))))).raw
    | _ => throwErrorAt mapper "protected projection requires an explicit scalar-selection lambda"
  if stx.isOfKind ``requireStep then
    let condition : TSyntax `term := ⟨← lower rows owners errorName stx[1]⟩
    let err := mkIdent (errorName ++ stx[3].getId)
    match stx with
    | `(doElem| require $_:term else $_:ident as $proof:ident) =>
      return (← `(doElem| let $proof ← LeanApp.Domain.Flow.require $condition $err)).raw
    | _ => return (← `(doElem| let _ ← LeanApp.Domain.Flow.require $condition $err)).raw
  if stx.isOfKind ``findStep then
    let name : TSyntax `ident := ⟨stx[1]⟩
    let type : TSyntax `term := ⟨stx[4]⟩
    let id : TSyntax `term := ⟨← lower rows owners errorName stx[5]⟩
    let err := mkIdent (errorName ++ stx[7].getId)
    return (← `(doElem| let $name ← LeanApp.Domain.Flow.find (T := $type) $id $err)).raw
  if stx.isOfKind ``createStep then
    let type : TSyntax `term := ⟨stx[1]⟩
    let value : TSyntax `term := ⟨← lower rows owners errorName stx[2]⟩
    let constraints ← (← createConstraints stx).mapM fun declaration => do
      let failure := mkIdent (errorName ++ declaration.failure)
      let identity := Syntax.mkStrLit declaration.identity.toString
      let field := Syntax.mkStrLit declaration.field
      `(term| { identity := $identity, fields := [$field], publicFailure := $failure : LeanApp.Domain.Constraint $(mkIdent errorName) })
    return (← `(doElem| LeanApp.Domain.Flow.create ($value : $type) [$constraints,*])).raw
  if stx.isOfKind ``authCreateStep then
    let type : TSyntax `term := ⟨stx[1]⟩
    let profile : TSyntax `term := ⟨stx[2]⟩
    let email : TSyntax `term := ⟨stx[3]⟩
    let password : TSyntax `term := ⟨stx[4]⟩
    let constraints ← (← createConstraints stx).mapM fun declaration => do
      let failure := mkIdent (errorName ++ declaration.failure)
      let identity := Syntax.mkStrLit declaration.identity.toString
      let field := Syntax.mkStrLit declaration.field
      `(term| { identity := $identity, fields := [$field], publicFailure := $failure : LeanApp.Domain.Constraint $(mkIdent errorName) })
    return (← `(doElem| LeanApp.Domain.Flow.request (LeanApp.Domain.Request.signUp ($profile : $type) $email $password [$constraints,*]))).raw
  if stx.isOfKind ``authVerifyStep then
    let type : TSyntax `term := ⟨stx[1]⟩
    let field : TSyntax `term := ⟨stx[2]⟩
    let email : TSyntax `term := ⟨stx[3]⟩
    let password : TSyntax `term := ⟨stx[4]⟩
    let failure := mkIdent (errorName ++ stx[6].getId)
    return (← `(doElem| LeanApp.Domain.Flow.request (LeanApp.Domain.Request.signIn (T := $type) $field $email $password $failure))).raw
  if stx.isOfKind ``callStep then
    let (callee, alternatives) ← calleeErrors stx
    let operation := "_root_." ++ callee.toString
    let mapping := if alternatives.isEmpty then "fun error => nomatch error" else
      "fun error => match error with " ++ String.intercalate " " (alternatives.toList.map fun (source, target) =>
        "| _root_." ++ source.toString ++ " => _root_." ++ (errorName ++ target).toString)
    let source := "LeanApp.Domain.Flow.mapError (" ++ mapping ++ ") (" ++ operation ++ ".bodyWithResources " ++
      operation ++ ".Requirements.infer (" ++ (← render stx[2]) ++ ") (" ++ (← render stx[3]) ++ "))"
    match Parser.runParserCategory (← getEnv) `doElem source with
    | .ok value => return value
    | .error message => throwErrorAt stx "cannot elaborate typed callee: {message}"
  if stx.isOfKind ``removeStep then
    let row : TSyntax `term := ⟨← lower rows owners errorName stx[1]⟩
    return (← `(doElem| LeanApp.Domain.Flow.remove $row)).raw
  if stx.isOfKind ``changeStep then
    let row : TSyntax `term := ⟨stx[1]⟩
    let mut patch : Option (TSyntax `term) := none
    for field in stx[3].getSepArgs do
      let name := field[0].getId
      let value : TSyntax `term := if field.getArgs.size == 1 then mkIdent name else ⟨field[2]⟩
      let key := Syntax.mkStrLit name.toString
      let next ← `(term| LeanApp.Domain.Change.set (field := $key) $value)
      patch := some (← match patch with | none => pure next | some previous => `(term| LeanApp.Domain.Change.andThen $previous $next))
    match patch with
    | none => throwErrorAt stx "change requires at least one declared field"
    | some merged =>
      let constraints ← (← changeConstraints owners stx).mapM fun declaration => do
        let failure := mkIdent (errorName ++ declaration.failure)
        let identity := Syntax.mkStrLit declaration.identity.toString
        let field := Syntax.mkStrLit declaration.field
        `(term| { identity := $identity, fields := [$field], publicFailure := $failure : LeanApp.Domain.Constraint $(mkIdent errorName) })
      return (← `(doElem| LeanApp.Domain.Flow.change $row $merged [$constraints,*])).raw
  if stx.isOfKind ``includeStep then
    let subject : TSyntax `term := ⟨stx[1]⟩
    let target : TSyntax `term := ⟨stx[3]⟩
    if subject.raw.isIdent && target.raw.isIdent && subject.raw.getId.getString! == "id" then
      let actor := mkIdent subject.raw.getId.getPrefix
      let row := mkIdent target.raw.getId.getPrefix
      let fieldName := Syntax.mkStrLit target.raw.getId.getString!
      return (← `(doElem| LeanApp.Domain.Flow.«include» (LeanApp.Domain.Row.membersField $row $fieldName) $actor)).raw
    else
      throwErrorAt stx "include requires authenticated actor.id and a declared row membership field"
  let children ← stx.getArgs.mapM (lower rows owners errorName)
  return stx.setArgs children

private partial def nodes (owners : Array (Lean.Name × Lean.Name)) (stx : Syntax) : CommandElabM (Array String) := do
  let q := fun text => (Lean.Json.str text).compress
  let mut result := #[]
  let mut kind := ""
  let mut effect := "query"
  let mut failure := "none"
  let mut fields := "[]"
  let mut constraints := "[]"
  if stx.isOfKind ``callStep then
    kind := "call"
    let callee ← resolveGlobalConstNoOverload stx[1]
    let type := (← getConstInfo callee).type
    if let some index := type.getAppArgs[0]? then
      if index.isConstOf ``Contract.OperationKind.command then effect := "command"
  if stx.isOfKind ``findStep then kind := "find"; failure := "some " ++ q stx[7].getId.toString
  if stx.isOfKind ``requireStep then kind := "require"; failure := "some " ++ q stx[3].getId.toString
  if stx.isOfKind ``authCreateStep then kind := "signUp"; effect := "command"
  if stx.isOfKind ``authVerifyStep then kind := "signIn"; effect := "command"; failure := "some " ++ q stx[6].getId.toString
  if stx.isOfKind ``createStep then kind := "create"; effect := "command"
  if stx.isOfKind ``removeStep then kind := "remove"; effect := "command"
  if stx.isOfKind ``includeStep then kind := "include"; effect := "command"
  if stx.isOfKind ``changeStep then
    kind := "change"
    effect := "command"
    fields := "[" ++ String.intercalate ", " (stx[3].getSepArgs.toList.map fun field => q field[0].getId.toString) ++ "]"
  if stx.isOfKind ``domainDisclosure || (stx.isOfKind ``Lean.Parser.Term.app && stx[0].isIdent && stx[0].getId.getString! == "disclose") then kind := "disclose"
  if stx.isOfKind ``createStep || stx.isOfKind ``authCreateStep || stx.isOfKind ``changeStep then
    let entries ← if stx.isOfKind ``changeStep then changeConstraints owners stx else createConstraints stx
    constraints := "[" ++ String.intercalate ", " (entries.toList.map (q ∘ Lean.Name.toString ∘ UniqueEntry.identity)) ++ "]"
  if !kind.isEmpty then
    result := result.push ("{ kind := " ++ q kind ++ ", effect := ." ++ effect ++ ", detail := " ++ q (← render stx) ++ ", failure := " ++ failure ++ ", fields := " ++ fields ++ ", constraints := " ++ constraints ++ " }")
  for child in stx.getArgs do result := result ++ (← nodes owners child)
  return result

private partial def lowerPolicy (rows : Array Lean.Name) (stx : Syntax) : CommandElabM Syntax := do
  if (stx.reprint.getD "").trimAscii.toString.startsWith ".literal " then return stx
  if stx.isOfKind ``Lean.Parser.Term.app && stx[0].isIdent && stx[0].getId.getString! == "literal" then return stx
  if let some access := rowField rows stx then return access
  if stx.isIdent && (stx.getId == `true || stx.getId == `false) then
    let value : TSyntax `term := ⟨stx⟩
    return (← `(LeanApp.Domain.Policy.literal $value)).raw
  if stx.isOfKind ``Lean.Parser.Term.app && stx[0].isIdent && stx[0].getId.getString! == "any" then
    let function := stx[0].getId.getPrefix
    unless function.getString! == "person" do throwErrorAt stx "policy any requires optional viewer.person"
    let viewer := mkIdent function.getPrefix
    let predicate := stx[1][0]
    unless predicate.isIdent && predicate.getId.getString! == "contains" do
      throwErrorAt predicate "policy membership must be a declared relation.contains"
    let relation := predicate.getId.getPrefix
    let row := mkIdent relation.getPrefix
    let field := Syntax.mkStrLit relation.getString!
    return (← `(LeanApp.Domain.Policy.viewerMember $viewer (LeanApp.Domain.Row.membersField $row $field))).raw
  return stx.setArgs (← stx.getArgs.mapM (lowerPolicy rows))

private def parameter (binder : Syntax) : CommandElabM (String × String × Option String) := do
  match binder with
  | `(bracketedBinder| ($name:ident : $type:term := $value:term)) =>
    return (name.getId.toString, ← render type, some (← render value))
  | `(bracketedBinder| ($name:ident : $type:term)) =>
    return (name.getId.toString, ← render type, none)
  | _ => throwErrorAt binder "domain parameters require one named explicit binder and a nondependent type"

private partial def generatedSyntax : Syntax → Syntax
  | .ident info raw name _ => .ident info raw name.eraseMacroScopes []
  | .node info kind args => .node info kind (args.map generatedSyntax)
  | other => other

private partial def authOwners (stx : Syntax) : CommandElabM (Array Lean.Name) := do
  let mut owners := #[]
  if stx.isOfKind ``authCreateStep || stx.isOfKind ``authVerifyStep then
    owners := owners.push (← resolveGlobalConstNoOverload stx[1])
  if stx.isOfKind ``callStep then
    let callee ← resolveGlobalConstNoOverload stx[1]
    if let some (_, inherited) := (operationAuthProfiles.getState (← getEnv)).find? (fun entry => entry.1 == callee) then
      owners := owners ++ inherited
  for child in stx.getArgs do
    for owner in ← authOwners child do
      if !owners.contains owner then owners := owners.push owner
  return owners

/-- Typed requirements are generated from the declaration namespace's storage closure. -/
private def resourceRequirements (body : Option Syntax := none) : CommandElabM (Array (String × String)) := do
  let ns ← getCurrNamespace
  let entities := (Deriving.entityDeclarations.getState (← getEnv)).filter fun entry => entry.name.getPrefix == ns
  let mut result := #[]
  let mut entityFields : Array (Lean.Name × String) := #[]
  for entry in entities do
    let entityField := "entity" ++ toString result.size
    entityFields := entityFields.push (entry.name, entityField)
    result := result.push (entityField, "LeanApp.Domain.HasEntityResource resources _root_." ++ entry.name.toString)
    for (field, target) in entry.members do
      let memberField := "member" ++ toString result.size
      result := result.push (memberField, "LeanApp.Domain.HasMemberResource resources _root_." ++ entry.name.toString ++ " " ++ (Lean.Json.str field).compress ++ " (" ++ target ++ ")")
      let targetInfo := entities.find? fun candidate => candidate.name.toString == target || candidate.name.getString! == target
      if let some targetInfo := targetInfo then
        for (column, valueType) in targetInfo.fields do
          result := result.push ("projection" ++ toString result.size,
            "LeanApp.Domain.HasProjectionResource resources _root_." ++ entry.name.toString ++ " (" ++ target ++ ") " ++
              (Lean.Json.str field).compress ++ " " ++ memberField ++ ".witness " ++ (Lean.Json.str column).compress ++ " (" ++ valueType ++ ")")
      else throwError "membership target {target} requires an imported typed resource closure adapter"
  if let some body := body then
    for owner in ← authOwners body do
      let some (_, entityField) := entityFields.find? (fun entry => entry.1 == owner)
        | throwError "authentication profile {owner} is outside this typed resource closure"
      result := result.push ("auth" ++ toString result.size,
        "LeanApp.Domain.HasAuthResource resources _root_." ++ owner.toString ++ " " ++ entityField ++ ".witness")
  return result

private def dependentResourceType (requirements : Array (String × String)) (replacementPrefix : String) (source : String) : String :=
  requirements.foldl (fun result (field, _) => result.replace (field ++ ".witness") (replacementPrefix ++ field ++ ".witness")) source

private def deriveOperation (name : TSyntax `ident) (binders : Array Syntax)
    (output body : TSyntax `term) (kind : String) : CommandElabM Unit := do
  let namespaceName ← getCurrNamespace
  let operationName := if name.getId.toString.startsWith "_root_." then name.getId.replacePrefix `_root_ .anonymous else namespaceName ++ name.getId
  let errName := operationName ++ `Error
  let owners ← loadedEntities body
  let alternatives ← failures owners body
  let nodeMetadata ← nodes owners body
  let mut publicFields : Array String := #[]
  let mut locals : Array String := #[]
  let mut routeField : Option (String × String) := none
  let mut actorName := "actor"
  let mut actorType := "Unit"
  for binder in binders do
    let (param, type, defaultValue) ← parameter binder
    if type.startsWith "SignedIn " || type.startsWith "Viewer " then
      if actorType != "Unit" then throwErrorAt binder "one injected actor/viewer is supported"
      actorName := param
      let parts := type.splitOn " "
      actorType := parts.head! ++ " Scope " ++ String.intercalate " " parts.tail!
    else
      if type == "Instant" && param == "now" then throwErrorAt binder "now is injected; it cannot be a public input"
      if type.trimAscii.toString.startsWith "Ref " then
        routeField := some (param, (type.trimAscii.toString.drop 4).toString)
      publicFields := publicFields.push (param ++ " : " ++ type ++ (defaultValue.map (" := " ++ ·) |>.getD ""))
      locals := locals.push ("let " ++ param ++ " := input." ++ param)
  let q := fun (text : String) => (Lean.Json.str text).compress
  let op := "_root_." ++ operationName.toString
  runGenerated ("inductive " ++ op ++ ".Error where " ++ String.intercalate " " (alternatives.toList.map fun n => "| " ++ n.toString) ++ " deriving LeanApp.Domain.Domain, BEq, Repr")
  if publicFields.isEmpty then
    runGenerated ("abbrev " ++ op ++ ".Input := Unit")
  else
    runGenerated ("structure " ++ op ++ ".Input where\n  " ++ String.intercalate "\n  " publicFields.toList ++ "\n  deriving LeanApp.Domain.Domain")
  if publicFields.size == 1 then
    if let some (field, target) := routeField then
      runGenerated ("instance : LeanApp.Domain.RouteInput " ++ op ++ ".Input := { Target := " ++ target ++ ", targetIdentity := inferInstance, parse := fun raw => (LeanApp.Domain.Ref.parse (T := " ++ target ++ ") raw).map " ++ op ++ ".Input.mk, reference := " ++ op ++ ".Input." ++ field ++ " }")
  let lowered : TSyntax `term := ⟨generatedSyntax (← lower (loadedNames body) owners errName body)⟩
  -- Reparsed generated code uses original identifiers so the public/local binder names agree.
  let sourceBody := (← liftCoreM <| withOptions (fun options => options.setBool `pp.hygiene false) <| PrettyPrinter.ppTerm lowered).pretty 100000
  let actor := if actorType == "Unit" then "(fun _ => Unit)" else "(fun Scope => " ++ actorType ++ ")"
  let outputType ← render output
  let namespaceText := if namespaceName.isAnonymous then "domain" else namespaceName.toString
  let identity := "{ namespaceName := " ++ q namespaceText ++ ", name := " ++ q (operationName.replacePrefix namespaceName .anonymous).toString ++ ", version := \"1\" }"
  let authProfiles ← authOwners body
  modifyEnv fun env => operationAuthProfiles.addEntry env (operationName, authProfiles)
  let requirements ← resourceRequirements (some body.raw)
  let fields := requirements.toList.map fun (field, type) => field ++ " : " ++ type
  runGenerated ("structure " ++ op ++ ".Requirements (resources : LeanApp.Domain.ResourceFamily) : Type 1 where\n  " ++ String.intercalate "\n  " fields)
  let inferBinders := String.intercalate " " (requirements.toList.map fun (field, type) => "[resource_" ++ field ++ " : " ++ dependentResourceType requirements "resource_" type ++ "]")
  runGenerated ("def " ++ op ++ ".Requirements.infer {resources : LeanApp.Domain.ResourceFamily} " ++ inferBinders ++ " : " ++ op ++ ".Requirements resources := ⟨" ++ String.intercalate ", " (requirements.toList.map fun (field, _) => "resource_" ++ field) ++ "⟩")
  runGenerated ("def " ++ op ++ ".portableRequirements : " ++ op ++ ".Requirements LeanApp.Domain.portableResources := " ++ op ++ ".Requirements.infer")
  let resourceLets := String.intercalate "\n  " (requirements.toList.map fun (field, type) => "let _ : " ++ dependentResourceType requirements "requirements." type ++ " := requirements." ++ field)
  runGenerated ("def " ++ op ++ ".flowWithResources {resources : LeanApp.Domain.ResourceFamily} (requirements : " ++ op ++ ".Requirements resources) {Scope : Type} (" ++ actorName ++ " : " ++ actorType ++ ") (input : " ++ op ++ ".Input) : LeanApp.Domain.Flow ." ++ kind ++ " Scope " ++ op ++ ".Error (" ++ outputType ++ ") resources := do\n  " ++ resourceLets ++ "\n  let now ← LeanApp.Domain.Flow.now\n  " ++ String.intercalate "\n  " locals.toList ++ "\n  return ← ((" ++ sourceBody.replace "\n" "\n  " ++ ") : LeanApp.Domain.Flow ." ++ kind ++ " Scope " ++ op ++ ".Error (" ++ outputType ++ ") resources)")
  runGenerated ("def " ++ op ++ ".flow {Scope : Type} (" ++ actorName ++ " : " ++ actorType ++ ") (input : " ++ op ++ ".Input) : LeanApp.Domain.Flow ." ++ kind ++ " Scope " ++ op ++ ".Error (" ++ outputType ++ ") := " ++ op ++ ".flowWithResources " ++ op ++ ".portableRequirements " ++ actorName ++ " input")
  runGenerated ("def " ++ op ++ " : LeanApp.Domain.Operation ." ++ kind ++ " " ++ actor ++ " " ++ op ++ ".Input (" ++ outputType ++ ") " ++ op ++ ".Error := { contract := Contract.Operation.ofValidated ." ++ kind ++ " " ++ identity ++ " (by decide), Requirements := " ++ op ++ ".Requirements, portable := " ++ op ++ ".portableRequirements, bodyWithResources := " ++ op ++ ".flowWithResources, metadata := { identity := " ++ identity ++ ", kind := ." ++ kind ++ ", failures := [" ++ String.intercalate ", " (alternatives.toList.map (q ∘ Lean.Name.toString)) ++ "], source := " ++ q ((← getEnv).mainModule.toString.replace "." "/" ++ ".lean:" ++ toString (body.raw.getPos?.map (·.byteIdx) |>.getD 0)) ++ ", actor := " ++ q actorType ++ ", establishesSession := " ++ toString (!authProfiles.isEmpty) ++ ", nodes := [" ++ String.intercalate ", " nodeMetadata.toList ++ "] } }")

elab_rules : command
  | `(command% $name:ident $binders:bracketedBinder* : $output:term := $body:term) => deriveOperation name (binders.map (·.raw)) output body "command"
  | `(query% $name:ident $binders:bracketedBinder* : $output:term := $body:term) => deriveOperation name (binders.map (·.raw)) output body "query"
  | `(policy% $name:ident $binders:bracketedBinder* := $body:term) => do
    let mut params := ""
    let mut rowNames := #[]
    for binder in binders do
      let (param, type, _) ← parameter binder
      if type.startsWith "Row " then rowNames := rowNames.push (Lean.Name.mkSimple param)
      let scopedType := if type.startsWith "Viewer " then "Viewer Scope " ++ (type.drop 7).toString
        else if type.startsWith "Row " then "Row Scope " ++ (type.drop 4).toString else type
      params := params ++ " (" ++ param ++ " : " ++ scopedType ++ ")"
    let meaning : TSyntax `term := ⟨generatedSyntax (← lowerPolicy rowNames body)⟩
    let source := (← liftCoreM <| PrettyPrinter.ppTerm meaning).pretty 100000
    let requirements ← resourceRequirements
    let resourceBinders := String.intercalate " " (requirements.toList.map fun (field, type) => "[resource_" ++ field ++ " : " ++ dependentResourceType requirements "resource_" type ++ "]")
    runGenerated ("def " ++ name.getId.toString ++ " {resources : LeanApp.Domain.ResourceFamily} {Scope : Type} " ++ resourceBinders ++ params ++ " : LeanApp.Domain.Policy Scope resources := " ++ source)
  | `(auth% $name:ident : $profile:term using emailPassword($email:ident)) => do
    let profileName ← resolveGlobalConstNoOverload profile
    let fields := getStructureFields (← getEnv) profileName
    unless fields.toList == [`name, email.getId] do
      throwErrorAt profile "emailPassword currently requires a profile record with name : Name and the selected email : Email; extra profile fields require a checked profile-construction adapter"
    let accountName := (← getCurrNamespace) ++ name.getId
    let base := "_root_." ++ accountName.toString
    let target := "_root_." ++ profileName.toString
    let emailPath := target ++ "." ++ email.getId.toString ++ "Path"
    runGenerated ("command% " ++ base ++ ".signUp (name : LeanApp.Domain.Name) (email : LeanApp.Domain.Email) (password : LeanApp.Domain.Password) : LeanApp.Domain.Ref " ++ target ++ " := do\n  authCreate " ++ target ++ " (" ++ target ++ ".mk name email) " ++ emailPath ++ " password")
    runGenerated ("command% " ++ base ++ ".signIn (email : LeanApp.Domain.Email) (password : LeanApp.Domain.Password) : LeanApp.Domain.Ref " ++ target ++ " := do\n  authVerify " ++ target ++ " " ++ emailPath ++ " email password else invalidCredentials")
    runGenerated ("def " ++ base ++ ".signUp.profile (input : " ++ base ++ ".signUp.Input) : " ++ target ++ " := " ++ target ++ ".mk input.name input.email")
    runGenerated ("def " ++ base ++ ".signUp.password (input : " ++ base ++ ".signUp.Input) : LeanApp.Domain.Password := input.password")
    runGenerated ("def " ++ base ++ ".signIn.email (input : " ++ base ++ ".signIn.Input) : LeanApp.Domain.Email := input.email")
    runGenerated ("def " ++ base ++ ".signIn.password (input : " ++ base ++ ".signIn.Input) : LeanApp.Domain.Password := input.password")
    runGenerated ("def " ++ base ++ " : LeanApp.Domain.Account " ++ target ++ " := { SignUpInput := " ++ base ++ ".signUp.Input, SignUpError := " ++ base ++ ".signUp.Error, SignInInput := " ++ base ++ ".signIn.Input, SignInError := " ++ base ++ ".signIn.Error, email := " ++ emailPath ++ ", signUpProfile := " ++ base ++ ".signUp.profile, signUpPassword := " ++ base ++ ".signUp.password, signInEmail := " ++ base ++ ".signIn.email, signInPassword := " ++ base ++ ".signIn.password, signUp := " ++ base ++ ".signUp, signIn := " ++ base ++ ".signIn }")
  | `(unique% $name:ident := $field:ident) => do
    let ownerSyntax := mkIdent name.getId.getPrefix
    if name.getId.getPrefix.isAnonymous then throwErrorAt name "unique name must be Entity.constraint"
    let owner ← resolveGlobalConstNoOverload ownerSyntax
    let identity := owner ++ Lean.Name.mkSimple name.getId.getString!
    let qualified := mkIdent identity
    let ownerId := mkIdent owner
    let fieldPath := mkIdent (owner ++ Lean.Name.mkSimple (field.getId.getString! ++ "Path"))
    elabCommand (← `(def $qualified := LeanApp.Domain.Unique.mk (T := $ownerId) $(Syntax.mkStrLit identity.toString) $fieldPath))
    let failure := Lean.Name.mkSimple (field.getId.getString! ++ "Taken")
    modifyEnv fun env => uniqueDeclarations.addEntry env ⟨owner, identity, field.getId.getString!, failure⟩
    -- Also a named constraint for plain operations: `owner.insert` reports it in `owner.Conflict`.
    Deriving.declareUniqueConstraint owner (Lean.Name.mkSimple name.getId.getString!) #[field.getId]
end LeanApp.Domain

namespace LeanApp.Domain
syntax "#domain_inspect " ident : command
elab_rules : command
  | `(#domain_inspect $operation:ident) => do
    Lean.Elab.Command.elabCommand (← `(#eval ($operation).metadata))
    Lean.Elab.Command.elabCommand (← `(#eval ($operation).contract.describe))
end LeanApp.Domain
