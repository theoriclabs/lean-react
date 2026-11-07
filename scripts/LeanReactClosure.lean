/- The import closures of LeanReact's libraries (run: `lake env lean --run scripts/LeanReactClosure.lean`).

* No module named `LeanApp` (the milestone 2 portable layer) is reachable from any of them.
* `LeanReact` (the UI core) and `LeanReact.Domain` (pages over typed endpoints) are portable:
  no native storage, SQLite, HTTP server or LeanAPI native module.
* Only `LeanReact.Server` reaches LeanAPI's native app. -/
import Lean
open Lean

def native (module : Name) : Bool :=
  let root := module.getRoot
  root == `SQLite || root == `LeanHttp ||
  (module.toString.startsWith "LeanDb." && !module.toString.startsWith "LeanDb.Model") ||
  module == `LeanDb ||
  module.toString.startsWith "LeanApi.Native" || module.toString.startsWith "LeanApi.Http" ||
  module.toString.startsWith "LeanApi.Runtime"

def closure (root : Name) : IO (Array Name) := do
  let env ← importModules #[{ module := root }] {} (loadExts := false)
  return env.header.moduleNames

def main : IO UInt32 := do
  initSearchPath (← findSysroot)
  let mut failures := 0
  for (root, portable) in [(`LeanReact, true), (`LeanReact.Domain, true), (`LeanReact.Server, false)] do
    let modules ← closure root
    let legacy := modules.filter (·.getRoot == `LeanApp)
    let natives := modules.filter native
    unless legacy.isEmpty do
      IO.eprintln s!"FAIL: {root} imports milestone 2 modules: {legacy}"
      failures := failures + 1
    if portable && !natives.isEmpty then
      IO.eprintln s!"FAIL: {root} is not portable; it imports {natives.toList.take 5}"
      failures := failures + 1
    let below := fun (start : String) => (modules.filter (·.toString.startsWith start)).size
    IO.println s!"{root}: {modules.size} modules; LeanOntology {below "LeanOntology"}, LeanContract {below "LeanContract"}, \
      LeanDb.Model {below "LeanDb.Model"}, LeanApi.Core {below "LeanApi.Core"}, native {natives.size}, LeanApp {legacy.size}"
  if failures == 0 then
    IO.println "PASS: no LeanApp module is reachable; LeanReact and LeanReact.Domain are portable"
  return if failures == 0 then 0 else 1
