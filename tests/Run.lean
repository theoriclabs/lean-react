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
  IO.FS.createDirAll (build / "LeanJS")
  IO.FS.createDirAll (build / "tests/compiler")
  lean project #["--version"]
  for module in #["LeanJS/Declarations", "LeanJS/Hooks", "LeanJS/Compiler", "LeanJS", "tests/compiler/Corpus"] do
    let sourceDir := sourceRoot project module
    lean project #["-R", sourceDir.toString, "-o", (build / s!"{module}.olean").toString,
      (sourceDir / s!"{module}.lean").toString]
  lean project #["tests/compiler/Generate.lean"]
  let artifacts := #["generated.mjs", "generated.d.ts", "generated.d.mts", "generated.manifest.json"]
  let original ← artifacts.mapM fun (name : String) => IO.FS.readBinFile (tests / name)
  lean project #["tests/compiler/Deterministic.lean"]
  lean project #["tests/compiler/Generate.lean"]
  for (name, bytes) in artifacts.zip original do
    check ((← IO.FS.readBinFile (tests / name)) == bytes)
      s!"Non-deterministic {name} across Lean processes"
  lean project #["tests/compiler/Negative.lean"]
  lean project #["tests/compiler/Hooks.lean"]
  let native ← checkedOutput (← leanCommand project #["--run", "tests/compiler/Native.lean"])
  IO.FS.writeFile (tests / "native.json") native
  run { cmd := "node", args := #["--check", "tests/compiler/generated.mjs"], cwd := project }
  run { cmd := "node", args := #["--test", "tests/compiler/compiler.test.mjs"], cwd := project }
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

private def field (value : Json) (name : String) : IO Json :=
  IO.ofExcept (value.getObjVal? name)

private def operation (name : String) (version := "1") : Json :=
  Json.mkObj [("namespace", toJson "leanreact.tickets"), ("name", toJson name), ("version", toJson version)]

private def nat (value : Nat) : Json :=
  Json.mkObj [("tag", toJson "nat"), ("value", toJson (toString value))]

private abbrev SessionChild := IO.Process.Child { stdin := .null, stdout := .piped }

private def waitForExit (child : SessionChild) : IO UInt32 := do
  for _ in [:200] do
    if let some code ← child.tryWait then
      return code
    IO.sleep 50
  throw <| IO.userError "protocol did not exit within 10 seconds"

/-- The returned child no longer owns stdin; dropping the handle signals EOF. -/
private def interact {α : Type} (executable database : String)
    (body : IO.FS.Handle → IO.FS.Handle → IO α) : IO (SessionChild × Except IO.Error α) := do
  let child ← IO.Process.spawn { cmd := executable, args := #[database], stdin := .piped, stdout := .piped }
  let (input, child) ← child.takeStdin
  let result ← try pure (.ok (← body input child.stdout)) catch error => pure (.error error)
  return (child, result)

private def withProtocol {α : Type} (executable database : String)
    (body : IO.FS.Handle → IO.FS.Handle → IO α) : IO α := do
  let (child, result) ← interact executable database body
  let reaped ← IO.mkRef false
  try
    let value ← IO.ofExcept result
    let code ← waitForExit child
    reaped.set true
    check (code == 0) s!"protocol exit code {code}"
    return value
  finally
    unless ← reaped.get do
      if (← child.tryWait).isNone then
        child.kill
        discard child.wait

private def responseLine (output : IO.FS.Handle) : IO String := do
  let pending ← IO.asTask output.getLine .dedicated
  for _ in [:200] do
    if ← IO.hasFinished pending then return ← IO.ofExcept pending.get
    IO.sleep 50
  throw <| IO.userError "protocol response timed out after 10 seconds"

private def call (input output : IO.FS.Handle) (name : String) (value : Json)
    (version := "1") (method := "POST") (path := s!"/api/tickets/{name}") : IO Json := do
  let envelope := Json.mkObj [
    ("method", toJson method), ("path", toJson path),
    ("body", Json.mkObj [("operation", operation name version),
      ("kind", toJson (if name == "list" then "query" else "command")), ("input", value)])]
  input.putStrLn envelope.compress
  input.flush
  let line ← responseLine output
  check (!line.isEmpty) "protocol exited before returning a response"
  IO.ofExcept (Json.parse line)

private def expectReply (reply : Json) (status : Nat) (tag : String) : IO Json := do
  check ((← field reply "status") == toJson status) s!"Expected HTTP {status}: {reply.compress}"
  let body ← field reply "body"
  check ((← field body "tag") == toJson tag) s!"Expected {tag}: {reply.compress}"
  return body

private def findTicket (values : Json) (key : Json) : IO Json := do
  let rows ← IO.ofExcept values.getArr?
  for row in rows do
    if (← field (← field row "id") "key") == key then return row
  throw <| IO.userError s!"Missing ticket {key.compress}"

private def protocol (executable database : String) : IO Unit := do
  let huge := 2^128 + 9007199254740993
  let saved ← withProtocol executable database fun input output => do
    let listed ← expectReply (← call input output "list" .null) 200 "success"
    let current ← findTicket (← field listed "value") (toJson "public-ticket-9007199254740993")
    check ((← field current "revision") == nat huge) "Initial revision must retain every digit"
    let id ← field current "id"
    check ((← field id "type") == Json.mkObj [("package", toJson "leanreact.tickets"), ("name", toJson "Ticket")])
      "Ticket identity must retain its public type"
    let assignee ← field (← field current "value") "assignee"
    check (assignee == Json.mkObj [("tag", toJson "some"), ("value", Json.mkObj [
      ("type", Json.mkObj [("package", toJson "leanreact.tickets"), ("name", toJson "User")]),
      ("scope", toJson "directory-demo"), ("key", toJson "user-17")])])
      "Assignee must retain its scope, type, and key"
    let save := Json.mkObj [("id", id), ("expectedRevision", ← field current "revision"),
      ("title", toJson "JSON protocol: exact λ🧪"), ("status", toJson "inProgress")]
    let success ← expectReply (← call input output "save" save) 200 "success"
    let saved ← field success "value"
    check ((← field saved "revision") == nat (huge + 1)) "Save must increment the exact revision"
    check ((← field (← field saved "value") "assignee") == assignee) "Save must preserve the assignee"
    let stale ← expectReply (← call input output "save" save) 409 "domainError"
    check ((← field stale "value") == Json.mkObj [("tag", toJson "conflict"), ("value", saved)])
      "Conflict must return the current persisted value"
    let missing := save.setObjVal! "id" (id.setObjVal! "key" (toJson "not-present"))
    let missingReply ← expectReply (← call input output "save" missing) 404 "domainError"
    check ((← field missingReply "value") == Json.mkObj [("tag", toJson "notFound"), ("value", .null)])
      "Missing identity must return typed notFound"
    for bad in #[save.setObjVal! "title" (toJson ""), save.setObjVal! "expectedRevision" (toJson huge),
        save.setObjVal! "status" (toJson "not-a-status"), save.setObjVal! "extra" (toJson true)] do
      let reply ← expectReply (← call input output "save" bad) 400 "decode"
      check (!(← IO.ofExcept (← field reply "errors").getArr?).isEmpty) "Decode failure must explain its errors"
    let changed ← expectReply (← call input output "list" .null "old-client") 409 "incompatible"
    check ((← field changed "expected") == operation "list") "Mismatch must return the expected operation"
    check ((← field (← call input output "save" save (path := "/rpc")) "status") == toJson (404 : Nat))
      "The public server must not expose the database dispatcher"
    let manifest ← call input output "list" .null (method := "GET") (path := "/api/manifest")
    check ((← field manifest "status") == toJson (200 : Nat)) "Manifest must be readable"
    let operations ← IO.ofExcept (← field (← field manifest "body") "operations").getArr?
    check ((← operations.mapM (field · "name")) == #[toJson "list", toJson "save"])
      "Manifest must list only the public operations"
    return saved
  withProtocol executable database fun input output => do
    let reply ← expectReply (← call input output "list" .null) 200 "success"
    let current ← findTicket (← field reply "value") (← field (← field saved "id") "key")
    check (current == saved) "Save must survive process restart"
  IO.println "PASS executable JSON protocol, typed statuses, large integers, and persistence across restart"

private def waitReady (log : FilePath) : IO Unit := do
  for _ in [:200] do
    let content ← if ← log.pathExists then IO.FS.readFile log else pure ""
    for line in content.splitOn "\n" do
      if let .ok event := Json.parse line then
        if (event.getObjValAs? String "event").toOption == some "tickets.ready" then
          let port ← IO.ofExcept (event.getObjValAs? Nat "port")
          check (port > 0 && port ≤ 65535) s!"Invalid ready port: {port}"
          IO.println port
          return
    IO.sleep 50
  throw <| IO.userError s!"Server did not become ready; inspect {log}"

def main (args : List String) : IO UInt32 := do
  try
    match args with
    | ["compiler"] => compiler
    | ["integration"] => integration
    | ["protocol", executable, database] => protocol executable database
    | ["wait-ready", log] => waitReady log
    | _ => throw <| IO.userError "usage: lake env lean --run tests/Run.lean <compiler|integration|protocol EXECUTABLE DATABASE|wait-ready LOG>"
    return 0
  catch error =>
    IO.eprintln error
    return 1

end TestRunner

def main := TestRunner.main
