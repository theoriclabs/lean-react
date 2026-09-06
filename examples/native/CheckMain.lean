import NativeTickets.Checks

def main (args : List String) : IO UInt32 := do
  match args with
  | [path] => NativeTickets.Checks.native path; pure 0
  | ["--init", path] =>
    discard <| NativeTickets.Checks.initializeFixture path
    IO.println "Fixture database initialized."
    pure 0
  | _ => IO.eprintln "usage: tickets_checks [--init] <new-sqlite-file>"; pure 2
