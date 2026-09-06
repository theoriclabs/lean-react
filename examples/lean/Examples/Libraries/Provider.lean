import Examples.Libraries.Shared

namespace Examples.Libraries
open LeanReact

structure ProviderProps where
  heading : String
  child : Element

def providerContext := formatter

def Provider : Component ProviderProps := component fun props =>
  pure <| provide formatter { heading := props.heading, format := fun text => "Hello, " ++ text } props.child

end Examples.Libraries
