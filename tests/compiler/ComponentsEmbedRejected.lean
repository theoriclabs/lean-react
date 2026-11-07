import Lean

namespace ComponentSpikeRejected

-- A child view has its own message type, so this attempt indexes Html by Msg.
-- Nesting that index under List is rejected by Lean before LeanJS sees it.
/--
error: (kernel) invalid nested inductive datatype 'List', nested inductive datatypes parameters cannot contain local variables.
-/
#guard_msgs in
inductive Html : Type → Type 1 where
  | text {Msg : Type} (value : String) : Html Msg
  | node {Msg : Type} (tag : String) (children : List (Html Msg)) : Html Msg
  | embed {ParentMsg : Type} (Props Model Msg : Type)
      (props : Props) (init : Props → Model) (update : Msg → Model → Model)
      (view : Model → Html Msg) (toParent : Msg → Option ParentMsg) : Html ParentMsg

run_meta do
  IO.FS.writeFile "tests/compiler/components-embed-generated.json" <| (Lean.Json.mkObj [
    ("status", .str "kernel-rejected"), ("fallback", .str "host-erased-child"),
    ("reason", .str "indexed Html under List cannot contain the local message index")]).compress

end ComponentSpikeRejected
