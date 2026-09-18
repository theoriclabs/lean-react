import LeanContract.Transport

namespace Contract
open Ontology

/-- Protocol version carried by `hello`. -/
structure Protocol where
  n : Nat
  deriving Repr, BEq, DecidableEq, Inhabited

def Protocol.v1 : Protocol := ⟨1⟩

/-- Client-chosen subscription id; distinct from `EventSeq`. -/
structure SubId where
  n : Nat
  deriving Repr, BEq, DecidableEq, Inhabited

/-- Per-subscription, gap-free event sequence. -/
structure EventSeq where
  n : Nat
  deriving Repr, BEq, DecidableEq, Inhabited

def EventSeq.zero : EventSeq := ⟨0⟩
def EventSeq.succ (s : EventSeq) : EventSeq := ⟨s.n + 1⟩

structure MsgId where
  n : Nat
  deriving Repr, BEq, DecidableEq, Inhabited

inductive CloseReason where
  | revoked | gone | overflow | session
  deriving Repr, BEq, DecidableEq

def CloseReason.toString : CloseReason → String
  | .revoked => "revoked"
  | .gone => "gone"
  | .overflow => "overflow"
  | .session => "session"

def CloseReason.parse : String → Option CloseReason
  | "revoked" => some .revoked
  | "gone" => some .gone
  | "overflow" => some .overflow
  | "session" => some .session
  | _ => none

/-- Application-defined topic. Spaces cannot collide (`Topic.doc id` ≠ `Topic.user id`). -/
structure Topic where
  private mk ::
  space : String
  key : String
  deriving Repr, BEq, DecidableEq

def Topic.doc (id : String) : Topic := ⟨"doc", id⟩
def Topic.user (id : String) : Topic := ⟨"user", id⟩

instance : Hashable Topic where
  hash t := mixHash (hash t.space) (hash t.key)

def Topic.encode (t : Topic) : Lean.Json :=
  .mkObj [("space", .str t.space), ("key", .str t.key)]

def Topic.decode (json : Lean.Json) : Option Topic :=
  match json.getObjValAs? String "space", json.getObjValAs? String "key" with
  | .ok space, .ok key => some ⟨space, key⟩
  | _, _ => none

structure Channel (Params Event Inbound Ack Error Snapshot : Type) where
  identity : OperationId
  params : Codec Params
  event : Codec Event
  inbound : Codec Inbound
  ack : Codec Ack
  error : Codec Error
  snapshot : Codec Snapshot

/-- Wire frames, multiplexed over one socket. Payloads stay `Json` here; each
    channel's codecs decode them. -/
inductive Frame where
  | hello (protocol : Protocol) (csrf : String)
  | subscribe (sub : SubId) (channel : OperationId) (params : Lean.Json) (resume : Option Lean.Json)
  | subscribed (sub : SubId) (snapshot : Option Lean.Json)
  | event (sub : SubId) (seq : EventSeq) (payload : Lean.Json)
  | send (sub : SubId) (msgId : MsgId) (payload : Lean.Json)
  | ack (sub : SubId) (msgId : MsgId) (payload : Lean.Json)
  | fail (sub : SubId) (msgId : Option MsgId) (error : Lean.Json)
  | call (msgId : MsgId) (request : WireRequest)
  | reply (msgId : MsgId) (response : Lean.Json)
  | unsubscribe (sub : SubId)
  | closed (sub : SubId) (reason : CloseReason)

private def opJson (id : OperationId) : Lean.Json :=
  .mkObj [("namespace", .str id.namespaceName), ("name", .str id.name), ("version", .str id.version)]

private def opOfJson (json : Lean.Json) : Option OperationId :=
  match json.getObjValAs? String "namespace", json.getObjValAs? String "name",
        json.getObjValAs? String "version" with
  | .ok ns, .ok name, .ok version => some ⟨ns, name, version⟩
  | _, _, _ => none

private def optJson (o : Option Lean.Json) : Lean.Json :=
  match o with | some j => j | none => .null

private def kindJson : OperationKind → Lean.Json
  | .query => .str "query"
  | .command => .str "command"

private def kindOfJson : Lean.Json → Option OperationKind
  | .str "query" => some .query
  | .str "command" => some .command
  | _ => none

def WireRequest.toJson (r : WireRequest) : Lean.Json :=
  .mkObj [("channel", opJson r.operation), ("kind", kindJson r.kind), ("input", r.input)]

def WireRequest.ofJson (json : Lean.Json) : Option WireRequest := do
  let op ← (json.getObjVal? "channel").toOption >>= opOfJson
    <|> (json.getObjVal? "operation").toOption >>= opOfJson
  let kind ← (json.getObjVal? "kind").toOption >>= kindOfJson
  let input ← (json.getObjVal? "input").toOption
  some ⟨op, kind, input⟩

def Frame.encode : Frame → Lean.Json
  | .hello p csrf =>
    .mkObj [("tag", .str "hello"), ("protocol", .num p.n), ("csrf", .str csrf)]
  | .subscribe sub ch params resume =>
    .mkObj [("tag", .str "subscribe"), ("sub", .num sub.n), ("channel", opJson ch),
      ("params", params), ("resume", optJson resume)]
  | .subscribed sub snapshot =>
    .mkObj [("tag", .str "subscribed"), ("sub", .num sub.n), ("snapshot", optJson snapshot)]
  | .event sub seq payload =>
    .mkObj [("tag", .str "event"), ("sub", .num sub.n), ("seq", .num seq.n), ("payload", payload)]
  | .send sub msg payload =>
    .mkObj [("tag", .str "send"), ("sub", .num sub.n), ("msgId", .num msg.n), ("payload", payload)]
  | .ack sub msg payload =>
    .mkObj [("tag", .str "ack"), ("sub", .num sub.n), ("msgId", .num msg.n), ("payload", payload)]
  | .fail sub msg error =>
    .mkObj [("tag", .str "fail"), ("sub", .num sub.n),
      ("msgId", match msg with | some m => .num m.n | none => .null), ("error", error)]
  | .call msg request =>
    .mkObj [("tag", .str "call"), ("msgId", .num msg.n), ("request", request.toJson)]
  | .reply msg response =>
    .mkObj [("tag", .str "reply"), ("msgId", .num msg.n), ("response", response)]
  | .unsubscribe sub =>
    .mkObj [("tag", .str "unsubscribe"), ("sub", .num sub.n)]
  | .closed sub reason =>
    .mkObj [("tag", .str "closed"), ("sub", .num sub.n), ("reason", .str reason.toString)]

private def natField (json : Lean.Json) (name : String) : Option Nat :=
  (json.getObjValAs? Nat name).toOption

private def strField (json : Lean.Json) (name : String) : Option String :=
  (json.getObjValAs? String name).toOption

def Frame.decode (json : Lean.Json) : Option Frame := do
  let tag ← strField json "tag"
  match tag with
  | "hello" =>
    let n ← natField json "protocol"
    let csrf ← strField json "csrf"
    some (.hello ⟨n⟩ csrf)
  | "subscribe" =>
    let sub ← natField json "sub"
    let ch ← (json.getObjVal? "channel").toOption >>= opOfJson
    let params ← (json.getObjVal? "params").toOption
    let resume := match json.getObjVal? "resume" with | .ok .null => none | .ok j => some j | _ => none
    some (.subscribe ⟨sub⟩ ch params resume)
  | "subscribed" =>
    let sub ← natField json "sub"
    let snapshot := match json.getObjVal? "snapshot" with | .ok .null => none | .ok j => some j | _ => none
    some (.subscribed ⟨sub⟩ snapshot)
  | "event" =>
    let sub ← natField json "sub"
    let seq ← natField json "seq"
    let payload ← (json.getObjVal? "payload").toOption
    some (.event ⟨sub⟩ ⟨seq⟩ payload)
  | "send" =>
    let sub ← natField json "sub"
    let msg ← natField json "msgId"
    let payload ← (json.getObjVal? "payload").toOption
    some (.send ⟨sub⟩ ⟨msg⟩ payload)
  | "ack" =>
    let sub ← natField json "sub"
    let msg ← natField json "msgId"
    let payload ← (json.getObjVal? "payload").toOption
    some (.ack ⟨sub⟩ ⟨msg⟩ payload)
  | "fail" =>
    let sub ← natField json "sub"
    let msg := natField json "msgId"
    let error ← (json.getObjVal? "error").toOption
    some (.fail ⟨sub⟩ (msg.map (⟨·⟩)) error)
  | "call" =>
    let msg ← natField json "msgId"
    let request ← (json.getObjVal? "request").toOption >>= WireRequest.ofJson
    some (.call ⟨msg⟩ request)
  | "reply" =>
    let msg ← natField json "msgId"
    let response ← (json.getObjVal? "response").toOption
    some (.reply ⟨msg⟩ response)
  | "unsubscribe" =>
    let sub ← natField json "sub"
    some (.unsubscribe ⟨sub⟩)
  | "closed" =>
    let sub ← natField json "sub"
    let reason ← strField json "reason" >>= CloseReason.parse
    some (.closed ⟨sub⟩ reason)
  | _ => none

end Contract
