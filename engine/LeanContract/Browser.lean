import LeanContract.Operation
import LeanContract.Http

namespace Contract.Browser
/-- Generic JSON ABI helpers. Host adapters never need DTO-specific tree constructors. -/
def jsonObject (fields : Array (String × Lean.Json)) : Lean.Json := .mkObj fields.toList

def jsonEntries : Lean.Json → Option (Array (String × Lean.Json))
  | .obj fields => some fields.toList.toArray
  | _ => none

def jsonNumber (mantissa : Int) (exponent : Nat) : Lean.Json := .num ⟨mantissa, exponent⟩

def decodeErrors (wire : Lean.Json) : Ontology.Validation Ontology.DecodeErrors := do
  let codec ← Http.validationErrorsCodec
  codec.decode wire

/-- Closed framework channels; domain failures are decoded with the operation's exact Error codec. -/
def frameworkError (kind code : String) (expected received : OperationId) : CallError E :=
  match kind with
  | "unauthenticated" => .unauthenticated
  | "forbidden" => .forbidden
  | "transport" => .transport ⟨code, ""⟩
  | "protocol" => .protocol ⟨code, none, ""⟩
  | "decode" => .decode (Ontology.ValidationErrors.single code)
  | "incompatible" => .incompatible ⟨expected, received⟩
  | "cancelled" => .cancelled
  | _ => .protocol ⟨"client.unknown_failure", none, ""⟩
end Contract.Browser
