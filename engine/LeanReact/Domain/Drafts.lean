import LeanDb.Model
import LeanReact.Forms

namespace LeanReact.Domain
open LeanDb.Model Ontology

private theorem fieldSmaller (entry : String × WireSchema) : sizeOf entry.2 < sizeOf entry := by
  rcases entry with ⟨name, schema⟩
  simp +arith

/-- References (milestone-1 structured form, or decision-15 bare integer) are bound, never edited. -/
def boundReference (version : String) : Bool := version == "entity-id/1" || version == "ref/2"

def rawSchema : WireSchema → WireSchema
  | .named _ version body => if boundReference version then .named ⟨"domain", "bound-reference"⟩ version body else rawSchema body
  | value => value

def initialRaw : WireSchema → Lean.Json
  | .named _ version body => if boundReference version then .null else initialRaw body
  | .record fields => .mkObj (fields.attach.map fun entry => (entry.val.1, initialRaw entry.val.2))
  | .variant ((tag, _) :: _) => .str tag
  | .boolean => .bool false
  | .unit => .null
  | .list _ | .array _ => .arr #[]
  | _ => .str ""

termination_by schema => sizeOf schema
decreasing_by
  all_goals simp_wf
  all_goals first
    | omega
    | have small := List.sizeOf_lt_of_mem entry.property
      have part := fieldSmaller entry.val
      omega

/-- Exact decimal draft text is kept until the canonical codec parses it. -/
def draftWire (schema : WireSchema) (raw : Lean.Json) : Lean.Json :=
  match schema with
  | .named _ version body =>
    if boundReference version then raw
    -- A time draft is exact epoch text; it is submitted in the transition form the codec accepts.
    else if version == "rfc3339/1" then
      match raw with
      | .str value => if (JsonWire.decimalInt? value).isSome then JsonWire.tagged "int" (.str value) else raw
      | _ => raw
    else draftWire body raw
  | .integer => match raw with | .str value => JsonWire.tagged "int" (.str value) | _ => raw
  | .natural => match raw with | .str value => JsonWire.tagged "nat" (.str value) | _ => raw
  | .variant cases => match raw with
    | .str tag => match cases.find? (fun entry => entry.1 == tag) with
      | some (_, .unit) => JsonWire.tagged tag .null
      | _ => .mkObj [("tag", .str tag), ("value", .null)]
    | _ => raw
  | .record fields => match raw with
    | .obj values => .mkObj (values.toList.map fun (key, value) =>
      (key, (fields.attach.find? (fun entry => entry.val.1 == key)).map (fun entry => draftWire entry.val.2 value) |>.getD value))
    | _ => raw
  | _ => raw

termination_by sizeOf schema
decreasing_by
  all_goals simp_wf
  all_goals first
    | omega
    | have small := List.sizeOf_lt_of_mem entry.property
      have part := fieldSmaller entry.val
      omega

def wireDraft (schema : WireSchema) (wire : Lean.Json) : Lean.Json :=
  match schema with
  | .named _ version body =>
    if boundReference version then wire
    else if version == "rfc3339/1" then
      match wire with
      | .str text => match parseRfc3339? text with | some seconds => .str (toString seconds) | none => wire
      | _ => wire
    else wireDraft body wire
  | .integer | .natural => match wire with
    -- Decision 15: a bare JSON integer; the tagged decimal form is still read.
    | .num number => if number.exponent == 0 then .str (toString number.mantissa) else wire
    | _ => (wire.getObjVal? "value").toOption.getD wire
  | .variant _ => (wire.getObjVal? "tag").toOption.getD wire
  | .record fields => match wire with
    | .obj values => .mkObj (values.toList.map fun (key, value) =>
      (key, (fields.attach.find? (fun entry => entry.val.1 == key)).map (fun entry => wireDraft entry.val.2 value) |>.getD value))
    | _ => wire
  | _ => wire

termination_by sizeOf schema
decreasing_by
  all_goals simp_wf
  all_goals first
    | omega
    | have small := List.sizeOf_lt_of_mem entry.property
      have part := fieldSmaller entry.val
      omega

def inputParser (codec : Codec I) : DraftParser Lean.Json I :=
  ⟨fun raw => codec.decode (draftWire codec.schema raw), fun value => wireDraft codec.schema (codec.encode value)⟩

/-- Total object update for controlled raw drafts; invalid nonobjects remain available to validation. -/
def updateField (raw : Lean.Json) (name : String) (value : Lean.Json) : Lean.Json :=
  match raw with
  | .obj values => .mkObj (values.toList.filter (fun entry => entry.1 != name) ++ [(name, value)])
  | _ => raw

/-- Bounds supplied by a typed screen remain wire values, and are not editable. -/
def bindFields (raw bound : Lean.Json) : Lean.Json :=
  match raw, bound with
  | .obj values, .obj bindings => .mkObj (values.toList.filter (fun entry => !bindings.contains entry.1) ++ bindings.toList)
  | _, _ => raw
end LeanReact.Domain
