import Examples.Tickets.Queries
open Ontology Examples.Tickets

def main : IO Unit := do
  let rows : List Nat := [1, 2, 3, 4]
  let evens : Query Nat Nat := Query.source.filter (· % 2 == 0)
  unless (evens.take 1).run rows == [2] do throw <| IO.userError "filter/take order changed"
  unless ((Query.source.take 1).filter (· % 2 == 0)).run rows == [] do
    throw <| IO.userError "limit was moved past filter"
  unless (evens.map (· * 10)).run rows == [20, 40] do throw <| IO.userError "projection failed"
  unless (evens.cross (Query.source.take 1)).run rows == [(2, 1), (4, 1)] do
    throw <| IO.userError "cross composition failed"
  let .ok tickets := seed | throw <| IO.userError "seed invalid"
  unless (openTickets.run tickets.toList).length == 2 do throw <| IO.userError "shared fragment failed"
  unless (previewTitles 1 tickets).length == 1 do throw <| IO.userError "fragment extension failed"
  IO.println "Query composition passed: ordered filters/limits, projections, products, and shared Tickets fragment."
