import Examples.Tickets.Components

namespace Examples.Composition
open LeanReact
open Examples.Tickets

def Counters : Component (Array String) := Component.named "CounterCollection" <| component fun names =>
  pure <| keyedEach names Key.string fun name => element Counter { label := name }

structure Formatter where
  heading : String
  render : String → String
  deriving TypeName

def formatterContext : Context Formatter :=
  createContext "examples.Formatter" { heading := "Default", render := fun value => value }

def Greeting : Component String := Component.named "Greeting" <| component fun name => do
  let formatter ← useContext formatterContext "formatter"
  pure <| text (formatter.heading ++ ": " ++ formatter.render name)

def Formatted : Component String := Component.named "Formatted" <| component fun heading =>
  pure <| provide formatterContext { heading, render := fun value => "Hello, " ++ value }
    (element Greeting "Lean")

end Examples.Composition
