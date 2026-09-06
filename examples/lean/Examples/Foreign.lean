import LeanReact

namespace Examples.Foreign
open LeanReact

structure ButtonProps where
  label : String
  onPress : Action Unit
  decoration : Element

/-- Native reference for a separately imported React component. -/
def thirdPartyButton (props : ButtonProps) : Element :=
  DOM.button { onPress := some props.onPress } #[text props.label, props.decoration]

def Interop : Component Unit := Component.named "Interop" <| component fun _ => do
  let count ← useState 0 "interop-count"
  pure <| thirdPartyButton {
    label := "Foreign React button"
    onPress := count.modify (· + 1)
    decoration := DOM.span {} #[text (toString count.value)]
  }

end Examples.Foreign
