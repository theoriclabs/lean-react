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
  bridge moduleName `LeanReact.foreign "foreign" 4
]

def options (moduleName : String) : LeanJS.Options := {
  intrinsics := intrinsics moduleName
  hooks := { primitives := ({} : LeanJS.HookConfig).primitives ++ #[
    ⟨`LeanReact.useResource, 7, "resource", 6⟩, ⟨`LeanReact.useCell, 3, "cell", 2⟩] }
}

end LeanReact.Compiler
