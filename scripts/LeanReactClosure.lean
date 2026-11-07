/- Inspect the union of the actual import closures of the UI libraries and examples. -/
import LeanReact.Compiler
import LeanReact.Domain
import Examples
open Lean

private def forbidden (module : Name) : Bool :=
  let name := module.toString
  module.getRoot == `LeanApp || module.getRoot == `LeanAppNative ||
  module.getRoot == `SQLite || module.getRoot == `LeanHttp ||
  module.getRoot == `LeanWS || module.getRoot == `LeanCrypto ||
  module == `LeanDb || (name.startsWith "LeanDb." && !name.startsWith "LeanDb.Model") ||
  ["LeanReact.Server", "LeanReact.Channels", "LeanReact.Streams",
   "LeanApi.Native", "LeanApi.Http", "LeanApi.Runtime"].any
    (fun start => name == start || name.startsWith (start ++ "."))

run_meta do
  let modules := (← getEnv).header.moduleNames
  let invalid := modules.filter forbidden
  unless invalid.isEmpty do
    throwError "UI libraries/examples import removed or native server modules: {invalid}"
  let intrinsics := (LeanReact.Compiler.intrinsics "adapter").map fun binding =>
    Json.mkObj [("leanName", toJson binding.leanName.toString),
      ("exportName", toJson binding.exportName)]
  IO.println (Json.mkObj [("modules", toJson modules.size),
    ("intrinsics", toJson intrinsics)]).compress
