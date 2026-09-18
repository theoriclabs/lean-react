import LeanContract.Operation

namespace Contract

/-- Transport-level failure of a remote call, mirroring the host `CallFailure` class in `Fetch.mjs`
(`kind` → constructor, `code` → payload). Portable data with no IO: components match on it instead of on
strings. Domain errors are not here; they stay in the operation's `Except`. -/
inductive CallFailure where
  | unauthenticated
  | forbidden
  | incompatible (expected received : OperationId)
  | decode (code : String)
  | protocol (code : String)
  | transport (code : String)
  | cancelled
  deriving Repr, BEq, DecidableEq

namespace CallFailure

/-- The host `kind` string. -/
def kind : CallFailure → String
  | .unauthenticated => "unauthenticated"
  | .forbidden => "forbidden"
  | .incompatible .. => "incompatible"
  | .decode _ => "decode"
  | .protocol _ => "protocol"
  | .transport _ => "transport"
  | .cancelled => "cancelled"

/-- The host `code` string, as `Fetch.mjs` produces it. -/
def code : CallFailure → String
  | .unauthenticated => "auth.required"
  | .forbidden => "auth.forbidden"
  | .incompatible .. => "contract.incompatible"
  | .decode code | .protocol code | .transport code => code
  | .cancelled => "request.cancelled"

/-- The same failure in the richer native `CallError`, for code shared with a Lean interpreter. -/
def toCallError : CallFailure → CallError ε
  | .unauthenticated => .unauthenticated
  | .forbidden => .forbidden
  | .incompatible expected received => .incompatible ⟨expected, received⟩
  | .decode code => .decode (Ontology.ValidationErrors.single code)
  | .protocol code => .protocol { code }
  | .transport code => .transport { code }
  | .cancelled => .cancelled

end CallFailure

end Contract
