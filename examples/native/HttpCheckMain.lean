import NativeTickets.Checks

def main (args : List String) : IO UInt32 := do
  let [port] := args | throw (IO.userError "usage: tickets_http_checks <local-port>")
  let some port := port.toNat? | throw (IO.userError "port must be numeric")
  if port == 0 || port > 65535 then throw (IO.userError "port must be between 1 and 65535")
  NativeTickets.Checks.http port.toUInt16
  pure 0
