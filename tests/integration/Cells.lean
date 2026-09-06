import Examples.Tickets.Components

open LeanReact Examples.Tickets

def main : IO Unit := do
  let trace ← IO.mkRef #[]
  let effects ← IO.mkRef #[]
  let env : RenderEnv := { trace, effects }
  let cell ← (useCell (0 : Nat) "counter").runRender env
  let first ← (cell.modifyGet fun n => (n, n + 1)).runIO
  let second ← (cell.modifyGet fun n => (n, n + 1)).runIO
  unless first == 0 && second == 1 && (← cell.read.runIO) == 2 do
    throw (IO.userError "cell transitions were not immediate")
  let store ← (useCell initialTickets "local-store").runRender env
  let service := memoryService store
  let some ticket := initialTickets[0]? | throw (IO.userError "missing fixture")
  let input : SaveTicket := { id := ticket.id, expectedRevision := 1, title := ⟨"First"⟩, status := .backlog }
  let .ok saved ← (service.save input).runIO | throw (IO.userError "first save failed")
  unless saved.revision == 2 do throw (IO.userError "revision not incremented")
  let .error (.conflict current) ← (service.save { input with title := ⟨"Second"⟩ }).runIO
    | throw (IO.userError "same-revision second save was accepted")
  unless current.value.title.value == "First" do throw (IO.userError "conflict overwrote first save")
  IO.println "Local cell/service checks passed: immediate transitions and same-revision conflict."
