import Examples.Libraries.Shared

namespace Examples.Libraries
open LeanReact

def consumerContext := formatter

def Greeting : Component String := component fun name => do
  let service ← useContext formatter "formatter"
  let count ← useState 0 "greeting-count"
  pure <| DOM.div {} #[
    DOM.p { className := some "greeting" } #[text s!"{service.heading}: {service.format name}"],
    DOM.button { onPress := some (count.modify (· + 1)) } #[text s!"Count {count.value}"]]

def OtherGreeting : Component Unit := component fun _ => do
  let service ← useContext otherFormatter "other-formatter"
  pure <| text service.heading

end Examples.Libraries
