import Lean
import Lean.Elab.ParseImportsFast

/- Test orchestration uses the project's pinned Lean toolchain and Node. -/
namespace TestRunner
open Lean System

private def check (condition : Bool) (message : String) : IO Unit :=
  unless condition do throw <| IO.userError message

private def checkedOutput (args : IO.Process.SpawnArgs) : IO String := do
  let result ← IO.Process.output args
  check (result.exitCode == 0)
    s!"{args.cmd} {args.args} failed ({result.exitCode})\n{result.stdout}{result.stderr}"
  return result.stdout

private def run (args : IO.Process.SpawnArgs) : IO Unit := do
  let child ← IO.Process.spawn args
  let code ← child.wait
  check (code == 0) s!"{args.cmd} {args.args} failed ({code})"

private def root : IO FilePath := do
  let project ← IO.Process.getCurrentDir
  check (← (project / "engine/LeanJS/Compiler.lean").pathExists) "Run the test harness from the repository root"
  return project

private def sourceRoot (project : FilePath) (module : String) : FilePath :=
  if module.startsWith "Examples" then project / "examples/lean"
  else if module.startsWith "tests/" then project
  else project / "engine"

private def leanCommand (project : FilePath) (args : Array String)
    (cwd : FilePath := project) : IO IO.Process.SpawnArgs := do
  let base ← checkedOutput { cmd := "lake", args := #["env", "printenv", "LEAN_PATH"], cwd := project }
  let separator := if System.Platform.isWindows then ";" else ":"
  let path := s!"{project / "tests/compiler/.build"}{separator}{base.trimAscii}"
  return { cmd := "lake", args := #["env", "env", s!"LEAN_PATH={path}", "lean"] ++ args, cwd }

private def lean (project : FilePath) (args : Array String)
    (cwd : FilePath := project) : IO Unit := do
  IO.println s!"lean {String.intercalate " " args.toList}"
  (← IO.getStdout).flush
  run (← leanCommand project args cwd)

private def compiler : IO Unit := do
  let project ← root
  let tests := project / "tests/compiler"
  let build := tests / ".build"
  -- P0 also proves the generated-codec fallback for the non-portable FromJson path.
  run { cmd := "lake", args := #["build", "leanapi/LeanContract.Generate"], cwd := project }
  IO.FS.createDirAll (build / "LeanJS")
  IO.FS.createDirAll (build / "tests/compiler")
  lean project #["--version"]
  for module in #["LeanJS/Portable", "LeanJS/Declarations", "LeanJS/Hooks", "LeanJS/Modules", "LeanJS/Compiler", "LeanJS", "tests/compiler/Corpus", "tests/compiler/ProofFields", "tests/compiler/Components"] do
    let sourceDir := sourceRoot project module
    lean project #["-R", sourceDir.toString, "-o", (build / s!"{module}.olean").toString,
      (sourceDir / s!"{module}.lean").toString]
  lean project #["tests/compiler/Generate.lean"]
  lean project #["tests/compiler/GenerateProofFields.lean"]
  lean project #["tests/compiler/GenerateComponents.lean"]
  lean project #["tests/compiler/ComponentsEmbedRejected.lean"]
  let artifacts := #["generated.mjs", "generated.d.ts", "generated.d.mts", "generated.manifest.json",
    "components-generated.mjs", "components-generated.d.ts", "components-generated.d.mts", "components-generated.manifest.json",
    "components-json-generated.json", "components-embed-generated.json", "components-native-generated.json",
    "components-client-generated/operations.mjs", "components-client-generated/operations.d.ts",
    "components-client-generated/operations.d.mts", "components-client-generated/manifest.json"]
  let original ← artifacts.mapM fun (name : String) => IO.FS.readBinFile (tests / name)
  lean project #["tests/compiler/Deterministic.lean"]
  lean project #["tests/compiler/Generate.lean"]
  lean project #["tests/compiler/GenerateComponents.lean"]
  lean project #["tests/compiler/ComponentsEmbedRejected.lean"]
  for (name, bytes) in artifacts.zip original do
    check ((← IO.FS.readBinFile (tests / name)) == bytes)
      s!"Non-deterministic {name} across Lean processes"
  lean project #["tests/compiler/Negative.lean"]
  lean project #["tests/compiler/Modules.lean"]
  lean project #["tests/compiler/Hooks.lean"]
  let native ← checkedOutput (← leanCommand project #["--run", "tests/compiler/Native.lean"])
  IO.FS.writeFile (tests / "native.json") native
  run { cmd := "node", args := #["--check", "tests/compiler/generated.mjs"], cwd := project }
  run { cmd := "node", args := #["--test", "tests/compiler/compiler.test.mjs", "tests/compiler/components.test.mjs"], cwd := project }
  IO.println s!"PASS: compiler checks, native parity, intrinsic overrides, deterministic ESM ({original[0]!.size} bytes)"

/-- Rebuild source imports in isolation, using Lean's own import parser. -/
private partial def buildImports (project : FilePath) (seen : IO.Ref (Array Name))
    (module : Name) : IO Unit := do
  if (← seen.get).contains module then return
  seen.modify (·.push module)
  let relative := module.toString.replace "." "/"
  let sourceDir := sourceRoot project relative
  let source := sourceDir / s!"{relative}.lean"
  if !(← source.pathExists) then return -- Installed Lean/Std modules are already available.
  let header ← parseImports' (← IO.FS.readFile source) source.toString
  for dependency in header.imports do
    buildImports project seen dependency.module
  if module == `Examples.Generate || (`LeanJS).isPrefixOf module then return
  let output := project / "tests/compiler/.build" / s!"{relative}.olean"
  if let some parent := output.parent then IO.FS.createDirAll parent
  lean project #["-R", sourceDir.toString, "-o", output.toString, source.toString]

private def integration : IO Unit := do
  let project ← root
  let probe := project / "tests/compiler/integration"
  IO.FS.createDirAll probe
  buildImports project (← IO.mkRef #[]) `Examples.Generate
  lean project #["-R", (project / "examples/lean").toString,
    (project / "examples/lean/Examples/Generate.lean").toString] probe
  run { cmd := "node", args := #["--check", (probe / "examples/generated/tickets.mjs").toString], cwd := project }
  run { cmd := "node", args := #["--test", "tests/compiler/integration.test.mjs"], cwd := project }
  IO.println "PASS: actual examples/lean/Examples/Generate.lean with ABI artifact generation"

def main (args : List String) : IO UInt32 := do
  try
    match args with
    | ["compiler"] => compiler
    | ["integration"] => integration
    | _ => throw <| IO.userError "usage: lake env lean --run tests/Run.lean <compiler|integration>"
    return 0
  catch error =>
    IO.eprintln error
    return 1

end TestRunner

def main := TestRunner.main
