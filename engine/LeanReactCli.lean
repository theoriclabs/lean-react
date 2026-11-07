/-! `lake exe leanreact build|dev|test <Module> …`: runs LeanReact's `scripts/leanreact.mjs` with
Node from the application's directory (see that script for the options). -/

def main (args : List String) : IO UInt32 := do
  -- This executable is `<package>/.lake/build/bin/leanreact`.
  let some package := (← IO.appPath).parent >>= (·.parent) >>= (·.parent) >>= (·.parent)
    | throw (IO.userError "leanreact: cannot locate the LeanReact package")
  let script := package / "scripts" / "leanreact.mjs"
  unless ← script.pathExists do throw (IO.userError s!"leanreact: missing {script}")
  let child ← IO.Process.spawn {
    cmd := "node"
    args := #[script.toString] ++ args.toArray
    stdin := .inherit, stdout := .inherit, stderr := .inherit }
  child.wait
