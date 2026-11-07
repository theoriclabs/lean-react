/- Issue #55: an endpoint whose only argument is the actor has `Input := Unit`. `load`, `call`
   and `form` accept it: `Unit` is a record with no fields, and its input is `()`. -/
import LeanReact.Domain
open LeanDb.Model LeanApi.Core LeanReact

namespace ActorOnly

structure Member where
  name : Name
  deriving Entity

structure Viewer where
  private mk ::
  id : Ref Member
  deriving Principal

entity_operations Member

def memberCount (me : Viewer) : ReadOp Empty Nat := do
  let _ := me
  return (← Member.select).length

def api : Api := [
  get "/members/count" memberCount
]

/-- info: ActorOnly.api.memberCount : Endpoint memberCount.Input Empty Nat -/
#guard_msgs in #check api.memberCount

-- Was: `failed to synthesize instance HasRecord memberCount.Input`.
def countPage : Element :=
  load api.memberCount (onError := nofun) fun count => DOM.p {} #[text (toString count)]

def countButton : Action Unit :=
  call api.memberCount (onError := nofun)

def countForm : Element :=
  form api.memberCount (onError := nofun)

-- No path fields: the bindings are `{}`, and the input decodes as `()` instead of failing
-- `decode.expected_null` ("Invalid address.").
#guard (LeanReact.Domain.endpointBindings api.memberCount []) == Lean.Json.mkObj []
#guard (LeanReact.Domain.endpointInput api.memberCount.operation.contract.inputCodec
  (LeanReact.Domain.endpointBindings api.memberCount [])).isOk
-- Records still decode their path object.
#guard !(LeanReact.Domain.endpointInput (Ontology.Codec.unit) (Lean.Json.str "x")).isOk
#guard (HasRecord.record (T := Unit)).fields.length == 0

end ActorOnly
