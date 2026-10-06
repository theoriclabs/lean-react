import LeanReact.Domain.App
import Lean.Elab.Term

namespace LeanReact.Domain
export LeanReact (Element)
open Lean

private partial def rejectsWildcard (stx : Syntax) : Bool :=
  stx.isOfKind ``Lean.Parser.Term.hole || (stx.isIdent && stx.getId == `_ ) || stx.getArgs.any rejectsWildcard

private partial def hasCases (stx : Syntax) : Bool :=
  stx.isOfKind ``Lean.Parser.Term.matchAlts || stx.isOfKind ``Lean.Parser.Term.nomatch || stx.getArgs.any hasCases

private partial def constructorPattern (stx : Syntax) : Bool :=
  if stx.isOfKind ``Lean.Parser.Term.dotIdent then true
  else if stx.isIdent then !stx.getId.getPrefix.isAnonymous
  else if stx.isOfKind ``Lean.Parser.Term.app then constructorPattern stx[0]
  else if stx.isOfKind ``Lean.Parser.Term.paren then constructorPattern stx[1]
  else if stx.getKind == `null && stx.getArgs.size == 1 then constructorPattern stx[0]
  else false

private partial def rejectsNamedCatchAll (stx : Syntax) : Bool :=
  (stx.isOfKind ``Lean.Parser.Term.matchAlt && stx[1].getArgs.any (fun pattern => !constructorPattern pattern)) ||
    stx.getArgs.any rejectsNamedCatchAll

private partial def unparen (stx : Syntax) : Syntax :=
  if stx.isOfKind ``Lean.Parser.Term.paren then unparen stx[1] else stx

private def matchesErrorArgument (handler : Syntax) : Bool := Id.run do
  let handler := unparen handler
  if handler.isOfKind ``Lean.Parser.Term.matchAlts then return true
  if !handler.isOfKind ``Lean.Parser.Term.«fun» then return false
  let body := handler[1]
  if body.isOfKind ``Lean.Parser.Term.matchAlts then return true
  if !body.isOfKind ``Lean.Parser.Term.basicFun then return false
  let binders := body[0].getArgs
  if binders.size != 1 || !binders[0]!.isIdent then return false
  let argument := binders[0]!.getId
  let result := unparen body[3]
  if result.isOfKind ``Lean.Parser.Term.nomatch then
    return result[1].getArgs.size == 1 && result[1][0].isIdent && result[1][0].getId == argument
  if !result.isOfKind ``Lean.Parser.Term.«match» then return false
  let discriminants := result[3].getArgs
  return discriminants.size == 1 && discriminants[0]![1].isIdent && discriminants[0]![1].getId == argument

/-- The derived surface admits explicit exhaustive branches, never an error-erasing catch-all. -/
private def checkHandler (handler : TSyntax `term) : MacroM Unit := do
  -- `nofun`: the endpoint's error type is empty (it fails to elaborate once it is not).
  if handler.raw.isOfKind ``Lean.Parser.Term.nofun then return
  unless handler.raw.isOfKind ``Lean.Parser.Term.matchAlts ||
      handler.raw.isOfKind ``Lean.Parser.Term.«fun» || handler.raw.isOfKind ``Lean.Parser.Term.«match» do
    Macro.throwErrorAt handler "onError requires explicit exhaustive domain-error branches"
  unless hasCases handler do Macro.throwErrorAt handler "onError requires explicit exhaustive branches or an empty-type elimination"
  if rejectsWildcard handler then Macro.throwErrorAt handler "wildcard domain-error handlers are forbidden in derived forms/screens"
  if rejectsNamedCatchAll handler then Macro.throwErrorAt handler "named catch-all domain-error patterns are forbidden; use explicit constructor branches"
  unless matchesErrorArgument handler do Macro.throwErrorAt handler "onError must match its error argument directly with explicit constructor branches"

/-- `fieldError "email" "…"`: a message on the named field (checked against the input record). -/
syntax (name := namedFieldErrorString) "fieldError " str term:max : term
macro_rules
  | `(fieldError $name:str $message:term) => `(fieldErrorNamed $name $message)

/-! Endpoint surface (DDD-LR-06): named arguments, `onError` always required. -/
syntax endpointArg := "(" ident " := " term ")"
syntax (name := endpointFormSyntax) "form " term:max (ppSpace endpointArg)+ : term
syntax (name := endpointCallSyntax) "call " term:max (ppSpace endpointArg)+ : term
syntax (name := endpointLoadSyntax) "load " term:max (ppSpace endpointArg)+ ppSpace term : term

private partial def argName (stx : Syntax) : String :=
  if stx.isIdent then stx.getId.toString
  else match stx with
    | .atom _ value => value.trimAscii.toString
    | .node _ _ args => (args.toList.map argName).find? (· != "") |>.getD ""
    | _ => ""

private def endpointArgs (what : String) (args : Array Syntax) (allowed : List String) :
    MacroM (List (String × TSyntax `term)) := do
  let mut result := []
  for arg in args do
    let name := argName arg[1]
    unless allowed.contains name do
      Macro.throwErrorAt arg s!"`{what}` takes {String.intercalate ", " (allowed.map fun n => "(" ++ n ++ " := …)")}"
    if result.any (·.1 == name) then Macro.throwErrorAt arg s!"`{name}` is given twice"
    result := result ++ [(name, ⟨arg[3]⟩)]
  return result

private def requiredError (what : String) (args : List (String × TSyntax `term)) (ref : Syntax) : MacroM (TSyntax `term) := do
  let some handler := args.lookup "onError"
    | Macro.throwErrorAt ref s!"`{what}` requires `(onError := …)`; use `(onError := nofun)` when the endpoint cannot fail"
  checkHandler handler
  return handler

macro_rules
  | `(endpointFormSyntax| form%$tk $endpoint:term $args:endpointArg*) => do
    let named ← endpointArgs "form" (args.map (·.raw)) ["onSuccess", "onError", "label"]
    let failure ← requiredError "form" named tk
    let success := (named.lookup "onSuccess").getD (← `(fun _ => pure ()))
    match named.lookup "label" with
    | some label => `(LeanReact.Domain.endpointForm $endpoint $success $failure $label)
    | none => `(LeanReact.Domain.endpointForm $endpoint $success $failure)
  | `(endpointCallSyntax| call%$tk $endpoint:term $args:endpointArg*) => do
    let named ← endpointArgs "call" (args.map (·.raw)) ["onSuccess", "onError"]
    let failure ← requiredError "call" named tk
    let success := (named.lookup "onSuccess").getD (← `(fun _ => pure ()))
    `(LeanReact.Domain.endpointCall $endpoint $success $failure)
  | `(endpointLoadSyntax| load%$tk $endpoint:term $args:endpointArg* $view:term) => do
    let named ← endpointArgs "load" (args.map (·.raw)) ["onError"]
    let failure ← requiredError "load" named tk
    `(LeanReact.Domain.endpointLoad $endpoint $failure $view)

end LeanReact.Domain

namespace LeanReact
-- The endpoint surface under `open LeanReact`.
export LeanReact.Domain (App PageRoute Feedback notice navigate)
end LeanReact
