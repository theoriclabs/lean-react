import Lean

namespace LeanJS
open Lean

/-- Identity of a compiled library, independent of its import URL. Versions may coexist;
one shared dependency must resolve to one ESM module instance within an application. -/
structure LibraryId where
  packageName : String
  version : String
  moduleName : String
  deriving BEq, Inhabited, ToJson, FromJson

/-- The retained Lean ABI of an exported declaration, checked against consumer sources. -/
structure ExportSignature where
  name : Name
  arity : Nat
  typeHash : String
  deriving BEq, Inhabited, ToJson, FromJson

structure LibraryInterface where
  id : LibraryId
  abi : String := "leanjs-v0"
  lean : String := "4.33.0"
  exports : Array ExportSignature
  deriving BEq, Inhabited, ToJson, FromJson

/-- An ordinary ESM dependency. The interface comes from the producer's artifacts or
manifest, rather than a hand-written list of names and arities. -/
structure LibraryImport where
  module : String
  interface : LibraryInterface
  deriving Inhabited

def exportSignature (name : Name) : CoreM ExportSignature := do
  let info ← getConstInfo name
  let arity ← Meta.MetaM.run' <| Meta.forallTelescopeReducing info.type fun xs _ => pure xs.size
  return { name, arity, typeHash := toString info.type.hash }

/-- Load a separately built producer's public interface. `module` is resolved by ESM
relative to the consumer output, and may also be an npm package specifier. -/
def readLibrary (manifestPath : System.FilePath) (module : String) : IO LibraryImport := do
  let manifest ← IO.ofExcept <| Json.parse (← IO.FS.readFile manifestPath)
  let interface ← IO.ofExcept <| manifest.getObjValAs? LibraryInterface "library"
  return { module, interface }

end LeanJS
