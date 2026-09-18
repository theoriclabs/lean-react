import Examples.Tickets.Client

/-- `lake env lean --run examples/lean/Examples/GenerateClient.lean [out]` -/
def main (args : List String) : IO Unit :=
  match args with
  | [out] => Examples.Tickets.Client.emit out
  | _ => Examples.Tickets.Client.emit
