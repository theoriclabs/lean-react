import LeanReact.Compiler

namespace Examples

/-- Example output lives in examples/generated; reusable bindings live in the engine. -/
def reactModule : String := "../../engine/adapters/leanjs-react.mjs"

def reactIntrinsics : Array LeanJS.Intrinsic := LeanReact.Compiler.intrinsics reactModule
def reactOptions : LeanJS.Options := LeanReact.Compiler.options reactModule

end Examples
