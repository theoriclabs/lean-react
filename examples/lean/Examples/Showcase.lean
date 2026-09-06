import LeanReact

namespace Examples.Showcase
open LeanReact

def counterView (count : Nat) (increment reset : Action Unit) : Element :=
  DOM.div { className := some "hero-demo" } #[
    DOM.div { className := some "demo-label" } #[text "A small component, with its own state."],
    DOM.div { className := some "hero-counter" } #[
      node "strong" #[.string "id" "hero-count"] #[text (toString count)],
      DOM.button { ariaLabel := some "Increment live counter", onPress := some increment } #[text "+1"]],
    DOM.div { className := some "demo-bottom" } #[
      DOM.span {} #[text "Go on. Give it a click."],
      DOM.button { onPress := some reset } #[text "Reset"]]]

def Counter : Component Unit := component fun _ => do
  let count ← useState 0 "count"
  pure <| counterView count.value
    (count.modify (· + 1))
    (count.set 0)

end Examples.Showcase
