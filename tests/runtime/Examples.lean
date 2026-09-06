import LeanReact

open LeanReact

namespace LeanReactExamples

structure CounterModel where
  count : Nat
  increment : Action Unit

def useCounter (initial : Nat) : Hook CounterModel := do
  let count ← useState initial (site := "count")
  pure { count := count.value, increment := count.modify (· + 1) }

def Counter : Component Unit := component fun _ => do
  let model ← useCounter 0
  pure <| DOM.button { onPress := some model.increment }
    #[text s!"Count: {model.count}"]

def CounterPanel : Component Nat := component fun initial => do
  let model ← useCounter initial
  pure <| DOM.div { className := some "counter-panel" } #[
    DOM.h2 {} #[text s!"Total {model.count}"],
    DOM.button { onPress := some model.increment } #[text "Add one"]
  ]

structure ListProps (α : Type) where
  items : Array α
  key : α → Key
  row : α → Element
  empty : Element := text "Nothing here yet"

def ListView (α : Type) : Component (ListProps α) := component fun props =>
  pure <| if props.items.isEmpty then props.empty
    else keyedEach props.items props.key props.row

structure CardProps where
  title : String
  onOpen : String → Action Unit
  footer : String → Element := fun _ => empty

def Card : Component CardProps := component fun props =>
  pure <| DOM.article {} #[
    DOM.h2 {} #[text props.title],
    props.footer props.title,
    DOM.button { onPress := some (props.onOpen props.title) } #[text "Open"]
  ]

def cards (names : Array String) (openCard : String → Action Unit) : Element :=
  element (ListView String) {
    items := names
    key := Key.string
    row := fun name => element Card {
      title := name
      onOpen := openCard
      footer := fun title => DOM.span {} #[text s!"About {title}"]
    }
  }

structure PickerProps where
  selected : Bool
  onChange : Bool → Action Unit

def Picker : Component PickerProps := component fun props =>
  pure <| DOM.input {
    type := .checkbox
    checked := some props.selected
    ariaLabel := some "Selected"
    onChange := some fun event => props.onChange event.checked
  }

def LocalPicker : Component Unit := component fun _ => do
  let selection ← useState false (site := "selection")
  pure <| element Picker { selected := selection.value, onChange := selection.set }

structure Theme where
  label : String
  deriving TypeName

def theme : Context Theme := createContext "LeanReactExamples.theme" { label := "Default" }

def ThemeLabel : Component Unit := component fun _ => do
  let current ← useContext theme (site := "theme")
  pure <| text current.label

def themed : Element := element (provider theme) {
  value := { label := "Scoped" }
  children := fragment #[element ThemeLabel (), element Counter ()]
}

-- A host adapter supplies this function. Setup and cleanup are both deferred actions.
structure SubscriptionProps where
  topic : String
  subscribe : String → Action (Action Unit)

def Subscription : Component SubscriptionProps := component fun props => do
  useEffect #[.string props.topic] (props.subscribe props.topic) (site := "subscription")
  pure <| text s!"Subscribed to {props.topic}"

end LeanReactExamples
