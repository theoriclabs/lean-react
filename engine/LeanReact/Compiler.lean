import LeanJS
import LeanReact

namespace LeanReact.Compiler

private def bridge (moduleName : String) (name : Lean.Name) (exportName : String)
    (arity : Nat) : LeanJS.Intrinsic :=
  { leanName := name, module := moduleName, exportName, arity }

/-- Reusable React bindings. The application chooses the module path from its generated ESM. -/
def intrinsics (moduleName : String) : Array LeanJS.Intrinsic := #[
  bridge moduleName `LeanReact.Action.pure "actionPure" 2,
  bridge moduleName `LeanReact.Action.bind "actionBind" 4,
  bridge moduleName `LeanReact.Action.map "actionMap" 4,
  bridge moduleName `LeanReact.Action.catchError "actionCatch" 3,
  bridge moduleName `LeanReact.Hook.pure "hookPure" 2,
  bridge moduleName `LeanReact.Hook.bind "hookBind" 4,
  bridge moduleName `LeanReact.Hook.map "hookMap" 4,
  bridge moduleName `LeanReact.useState "useState" 3,
  bridge moduleName `LeanReact.useCell "useCell" 3,
  bridge moduleName `LeanReact.Cell.read "cellRead" 2,
  bridge moduleName `LeanReact.Cell.modifyGet "cellModifyGet" 4,
  bridge moduleName `LeanReact.useEffect "useEffect" 3,
  bridge moduleName `LeanReact.useResource "useResource" 7,
  bridge moduleName `LeanReact.component "component" 2,
  bridge moduleName `LeanReact.Component.named "componentNamed" 3,
  bridge moduleName `LeanReact.element "element" 3,
  bridge moduleName `LeanReact.text "text" 1,
  bridge moduleName `LeanReact.node "node" 3,
  bridge moduleName `LeanReact.fragment "fragment" 1,
  bridge moduleName `LeanReact.empty "empty" 0,
  bridge moduleName `LeanReact.keyed "keyed" 2,
  bridge moduleName `LeanReact.keyedEach "keyedEach" 4,
  bridge moduleName `LeanReact.createContext "createContext" 4,
  bridge moduleName `LeanReact.useContext "useContext" 3,
  bridge moduleName `LeanReact.provide "provide" 4,
  -- LR-03 imperative handles: `foreign {P H} name props`; the host resolves `name` through `registerForeign`.
  bridge moduleName `LeanReact.foreign "foreign" 4,
  -- LR-06 router: the history hook, its context's erased native TypeName dictionary, and URL helpers that
  -- portable Lean cannot express yet (no string splitting).
  bridge moduleName `LeanReact.useLocation "useLocation" 1,
  bridge moduleName `LeanReact.instTypeNameRouteState "erased" 0,
  bridge moduleName `LeanReact.Route.split "routeSplit" 1,
  bridge moduleName `LeanReact.Route.segments "routeSegments" 1,
  bridge moduleName `LeanReact.Route.nat? "routeNat" 1,
  bridge moduleName `LeanReact.Query.parse "queryParse" 1,
  bridge moduleName `LeanReact.Query.encode "queryEncode" 1,
  -- LR-06 endpoint pages: the app context's erased TypeName dictionary and the mounted app that
  -- `call`/`navigate` act on (one per document).
  bridge moduleName `LeanReact.Domain.instTypeNameAppContext "erased" 0,
  bridge moduleName `LeanReact.Domain.installAppRuntime "appInstall" 1,
  bridge moduleName `LeanReact.Domain.currentAppRuntime "appCurrent" 0
]

def options (moduleName : String) : LeanJS.Options := {
  intrinsics := intrinsics moduleName
  hooks := { primitives := ({} : LeanJS.HookConfig).primitives ++ #[
    ⟨`LeanReact.useResource, 7, "resource", 6⟩, ⟨`LeanReact.useCell, 3, "cell", 2⟩,
    -- LR-06 router
    ⟨`LeanReact.useLocation, 1, "router", 0⟩] }
}

/-- `#leanreact_check App, Page`: the build-time portability check of `#leanjs_check`, with the
LeanReact intrinsics and hook primitives. A component that reaches native-only code fails
`lake build` with the dependency path that generation would report. -/
syntax "#leanreact_check " ident,+ : command
macro_rules
  | `(#leanreact_check $names,*) => `(#leanjs_check $names,* using LeanReact.Compiler.options "")

open Lean in
private unsafe def stylesheetUnsafe (prefixes : Array Name) : CoreM String := do
  let env ← getEnv
  let under (n : Name) := prefixes.any (·.isPrefixOf n)
  let names := (env.constants.fold (fun acc n info =>
    if under n && !n.isInternal then acc.push (n, info.type) else acc) #[]).qsort (fun a b => a.1.toString < b.1.toString)
  let mut styles : List Style := []
  let mut tokens : List TokenDecl := []
  for (n, type) in names do
    if type == mkConst ``LeanReact.Style then
      styles := styles ++ [← IO.ofExcept (env.evalConst Style (← getOptions) n)]
    else if type == mkApp (mkConst ``LeanReact.Token) (mkConst ``LeanReact.Length) then
      tokens := tokens ++ [(← IO.ofExcept (env.evalConst (Token Length) (← getOptions) n)).declLength]
    else if type == mkApp (mkConst ``LeanReact.Token) (mkConst ``LeanReact.Color) then
      tokens := tokens ++ [(← IO.ofExcept (env.evalConst (Token Color) (← getOptions) n)).declColor]
    else if type == mkApp (mkConst ``LeanReact.Token) (mkConst ``String) then
      tokens := tokens ++ [(← IO.ofExcept (env.evalConst (Token String) (← getOptions) n)).declFont]
  match Stylesheet.extract styles tokens with
  | .ok css => return css
  | .error message => throwError "LeanReact styles: {message}"

/-- The stylesheet of every top-level `Style` and `Token` declared under `prefixes`
(e.g. `#[`MyApp]`): tokens as custom properties, then each style's rules once. -/
@[implemented_by stylesheetUnsafe]
opaque stylesheet (prefixes : Array Lean.Name) : Lean.CoreM String

/-- Write `stylesheet prefixes` to `path` (a static CSS file next to the generated JavaScript). -/
def writeStylesheet (path : System.FilePath) (prefixes : Array Lean.Name) : Lean.CoreM Unit := do
  IO.FS.writeFile path (← stylesheet prefixes)

end LeanReact.Compiler
