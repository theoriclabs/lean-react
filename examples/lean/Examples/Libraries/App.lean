import Examples.Libraries.Provider
import Examples.Libraries.Consumer

namespace Examples.Libraries
open LeanReact

def App : Component Unit := component fun _ => do
  let heading ← useState "Provided" "heading"
  pure <| DOM.div {} #[
    DOM.h2 {} #[text "Components from compiled libraries"],
    DOM.input {
      ariaLabel := some "Provider heading"
      value := some heading.value
      onChange := some (fun event => heading.set event.value) },
    element Provider ⟨heading.value, element Greeting "Lean"⟩,
    element OtherGreeting (),
    element Greeting "Outside"]

-- Only this component is exported by its standalone build. The context is indirect,
-- held inside a record built through a function, and first read in a render closure.
structure Services where
  context : Context Formatter

def makeServices (heading : String) : Services :=
  ⟨createContext "Hidden" { heading, format := id }⟩

def hiddenServices := makeServices "Hidden default"

def Automatic : Component String := component fun name => do
  let service ← useContext hiddenServices.context "hidden"
  pure <| text s!"{service.heading}: {service.format name}"

end Examples.Libraries
