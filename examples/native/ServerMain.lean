import NativeTickets.Http

def main (args : List String) : IO UInt32 := do
  match args with
  | [port, path] =>
    let some port := port.toNat? | throw (IO.userError "port must be an integer from 0 to 65535")
    if port > 65535 then throw (IO.userError "port must be an integer from 0 to 65535")
    NativeTickets.runServer port.toUInt16 path
  | ["--manifest"] =>
    IO.println (← NativeTickets.loadOperations).manifest.compress
    pure 0
  | _ =>
    IO.eprintln "usage: tickets_server <port> <sqlite-file> | --manifest"
    pure 2
