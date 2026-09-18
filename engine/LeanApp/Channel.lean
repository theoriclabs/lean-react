import LeanApp.Binding
import LeanContract.Channel

namespace LeanApp
open Contract Ontology

/-- Subscribe-time policy yields evidence `Ev` that inbound/snapshot handlers cannot invent. -/
structure ChannelBinding (m : Type → Type) (Read Write : Type → Type)
    (ch : Channel P E I A Err S) (Ev : Type) where
  policy : RequestContext → ReadCapability m Read → P → m (CallResult Ev Empty)
  topics : RequestContext → P → List Topic
  onSubscribe : RequestContext → Capability m Read Write .query → Ev → P → m (Except Err S)
  onInbound : RequestContext → Capability m Read Write .command → Ev → P → I → m (Except Err A)
  published : PublicMetadata := {}
  describePolicy : String := ""

/-- Runtime dispatch record after codecs have been applied. Hosts keep these, not the typed binding. -/
structure ApprovedChannel (m : Type → Type) where
  identity : OperationId
  published : PublicMetadata
  /-- Decode subscribe params, run policy, return topics + snapshot json or a fail payload. -/
  subscribe : RequestContext → Lean.Json → m (CallResult (List Topic × Option Lean.Json) Lean.Json)
  inbound : RequestContext → Lean.Json → Lean.Json → m (CallResult Lean.Json Lean.Json)

def ChannelBinding.approve [Monad m] (binding : ChannelBinding m Read Write ch Ev)
    (provideQuery : RequestContext → Capability m Read Write .query)
    (provideCommand : RequestContext → Capability m Read Write .command) :
    ApprovedChannel m :=
  let published := if binding.describePolicy.isEmpty then binding.published
    else { binding.published with describePolicy := binding.describePolicy }
  { identity := ch.identity
    published := published
    subscribe := fun context paramsJson => do
      match ch.params.decode paramsJson with
      | .error errors => return .error (.decode errors)
      | .ok params =>
        match ← binding.policy context (Capability.toRead (provideQuery context)) params with
        | .error e => return .error (e.mapDomain Empty.elim)
        | .ok ev =>
          match ← binding.onSubscribe context (provideQuery context) ev params with
          | .error err => return .error (.domain (ch.error.encode err))
          | .ok snap =>
            return .ok (binding.topics context params, some (ch.snapshot.encode snap))
    inbound := fun context paramsJson payload => do
      match ch.params.decode paramsJson, ch.inbound.decode payload with
      | .error errors, _ => return .error (.decode errors)
      | _, .error errors => return .error (.decode errors)
      | .ok params, .ok msg =>
        match ← binding.policy context (Capability.toRead (provideCommand context)) params with
        | .error e => return .error (e.mapDomain Empty.elim)
        | .ok ev =>
          match ← binding.onInbound context (provideCommand context) ev params msg with
          | .error err => return .error (.domain (ch.error.encode err))
          | .ok ack => return .ok (ch.ack.encode ack) }

def ApprovedChannel.toJson (ch : ApprovedChannel m) : Lean.Json :=
  .mkObj [("namespace", .str ch.identity.namespaceName), ("name", .str ch.identity.name),
    ("version", .str ch.identity.version), ("kind", .str "channel"),
    ("metadata", ch.published.toJson)]

end LeanApp
