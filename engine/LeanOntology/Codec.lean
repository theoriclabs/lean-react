import LeanOntology.Identity
import LeanOntology.Schema
import Std.Data.TreeMap

namespace Ontology

abbrev WireValue := Lean.Json

/-- Interpretation values are first-class; no instance is needed to compose codecs. -/
structure Codec (α : Type) where
  schema : WireSchema
  encode : α → WireValue
  decode : WireValue → Validation α

structure Codec.Laws (codec : Codec α) : Prop where
  roundTrip : ∀ value, codec.decode (codec.encode value) = .ok value

/-- A convenience for the canonical interpretation only. -/
class Wire (α : Type) where
  codec : Codec α

namespace JsonWire

def object (keys : List String) (value : WireValue) : Validation Unit := do
  match value with
  | .obj fields =>
    for (key, _) in fields.toList do
      if !keys.contains key then
        throw (ValidationErrors.single "decode.unknown_field" [.key key])
  | _ => Validation.fail "decode.expected_object"

def get (key : String) (value : WireValue) : Validation WireValue :=
  match value with
  | .obj fields => match fields.get? key with
    | some field => .ok field
    | none => Validation.fail "decode.missing_field" [.key key]
  | _ => Validation.fail "decode.expected_object"

def string (value : WireValue) : Validation String :=
  match value with
  | .str text => .ok text
  | _ => Validation.fail "decode.expected_string"

def stringField (key : String) (value : WireValue) : Validation String := do
  let field ← get key value
  Validation.prependPath [.key key] (string field)

def tagged (tag : String) (value : WireValue) : WireValue :=
  .mkObj [("tag", .str tag), ("value", value)]

def checkTag (expected : String) (value : WireValue) : Validation Unit := do
  let actual ← stringField "tag" value
  if actual != expected then
    Validation.fail "decode.unknown_tag" [.key "tag"] [("expected", expected), ("actual", actual)]

def uniqueNames (names : List String) : Validation Unit := do
  let mut seen : List String := []
  for name in names do
    if name.isEmpty then
      throw (ValidationErrors.single "schema.empty_name")
    if seen.contains name then
      throw (ValidationErrors.single "schema.duplicate_name" [] [("name", name)])
    seen := name :: seen

end JsonWire

namespace Codec

def canonical [Wire α] : Codec α := Wire.codec

def encodeJson (codec : Codec α) (value : α) : String := (codec.encode value).compress

def decodeJson (codec : Codec α) (text : String) : Validation α := do
  let value ← (Lean.Json.parse text).mapError fun message =>
    ValidationErrors.single "decode.invalid_json" [] [("detail", message)]
  codec.decode value

/-- Total forward mapping, checked inverse; validation failures keep their structure. -/
def checked (codec : Codec α) (construct : α → Validation β) (project : β → α) : Codec β where
  schema := codec.schema
  encode value := codec.encode (project value)
  decode value := codec.decode value >>= construct

def xmap (codec : Codec α) (construct : α → β) (project : β → α) : Codec β :=
  codec.checked (fun value => .ok (construct value)) project

def named (codec : Codec α) (identity : TypeId) (version : String := "1") : Codec α :=
  { codec with schema := .named identity version codec.schema }

def validated (codec : Codec α) (validate : Validator α) : Codec α :=
  codec.checked (fun value => do validate value; pure value) id

def string : Codec String := ⟨.string, .str, JsonWire.string⟩

def bool : Codec Bool where
  schema := .boolean
  encode := .bool
  decode
    | .bool value => .ok value
    | _ => Validation.fail "decode.expected_boolean"

def unit : Codec Unit where
  schema := .unit
  encode _ := .null
  decode
    | .null => .ok ()
    | _ => Validation.fail "decode.expected_null"

private def decimal (tag : String) (value : WireValue) : Validation String := do
  JsonWire.object ["tag", "value"] value
  JsonWire.checkTag tag value
  JsonWire.stringField "value" value

def nat : Codec Nat where
  schema := .natural
  encode value := JsonWire.tagged "nat" (.str (toString value))
  decode value := do
    let text ← decimal "nat" value
    match text.toNat? with
    | some number =>
      if toString number == text then pure number
      else Validation.fail "decode.noncanonical_integer" [.key "value"]
    | none => Validation.fail "decode.invalid_natural" [.key "value"]

def int : Codec Int where
  schema := .integer
  encode value := JsonWire.tagged "int" (.str (toString value))
  decode value := do
    let text ← decimal "int" value
    match text.toInt? with
    | some number =>
      if toString number == text then pure number
      else Validation.fail "decode.noncanonical_integer" [.key "value"]
    | none => Validation.fail "decode.invalid_integer" [.key "value"]

def field (name : String) (codec : Codec α) (value : WireValue) : Validation α := do
  let item ← JsonWire.get name value
  Validation.prependPath [.key name] (codec.decode item)

def option (codec : Codec α) : Codec (Option α) where
  schema := .option codec.schema
  encode
    | none => .mkObj [("tag", .str "none")]
    | some value => JsonWire.tagged "some" (codec.encode value)
  decode value := do
    let tag ← JsonWire.stringField "tag" value
    match tag with
    | "none" => do JsonWire.object ["tag"] value; pure none
    | "some" => do
      JsonWire.object ["tag", "value"] value
      some <$> field "value" codec value
    | _ => Validation.fail "decode.unknown_tag" [.key "tag"] [("actual", tag)]

def product (left : Codec α) (right : Codec β) : Codec (α × β) where
  schema := .product left.schema right.schema
  encode value := .arr #[left.encode value.1, right.encode value.2]
  decode
    | .arr values =>
      if h : values.size = 2 then
        Validation.map2 Prod.mk
          (Validation.prependPath [.index 0] (left.decode values[0]))
          (Validation.prependPath [.index 1] (right.decode values[1]))
      else Validation.fail "decode.expected_pair"
    | _ => Validation.fail "decode.expected_array"

def array (codec : Codec α) : Codec (Array α) where
  schema := .array codec.schema
  encode values := .arr (values.map codec.encode)
  decode
    | .arr values => Id.run do
      let mut result : Validation (Array α) := .ok #[]
      for index in [:values.size] do
        let item := Validation.prependPath [.index index] (codec.decode values[index]!)
        result := Validation.map2 Array.push result item
      return result
    | _ => Validation.fail "decode.expected_array"

def list (codec : Codec α) : Codec (List α) :=
  { (array codec).xmap Array.toList List.toArray with schema := .list codec.schema }

def sum (left : Codec α) (right : Codec β) : Codec (Sum α β) where
  schema := .variant [("left", left.schema), ("right", right.schema)]
  encode
    | .inl value => JsonWire.tagged "left" (left.encode value)
    | .inr value => JsonWire.tagged "right" (right.encode value)
  decode value := do
    JsonWire.object ["tag", "value"] value
    let tag ← JsonWire.stringField "tag" value
    match tag with
    | "left" => Sum.inl <$> field "value" left value
    | "right" => Sum.inr <$> field "value" right value
    | _ => Validation.fail "decode.unknown_tag" [.key "tag"] [("actual", tag)]

def except (error : Codec ε) (success : Codec α) : Codec (Except ε α) :=
  (sum error success).xmap
    (fun value => match value with | .inl e => .error e | .inr a => .ok a)
    (fun value => match value with | .error e => .inl e | .ok a => .inr a)

def patch (codec : Codec α) : Codec (PatchField α) :=
  (option codec).xmap
    (fun value => match value with | none => .keep | some a => .set a)
    (fun value => match value with | .keep => none | .set a => some a)

/-- Maps use arrays of pairs, retaining typed keys and rejecting duplicate decoded keys. -/
def map [Ord κ] (key : Codec κ) (value : Codec ν) : Codec (Std.TreeMap κ ν) :=
  { ((list (product key value)).checked (fun entries => do
      let mut result : Std.TreeMap κ ν := {}
      let mut index := 0
      for (k, v) in entries do
        if result.contains k then
          throw (ValidationErrors.single "decode.duplicate_key" [.index index, .index 0])
        result := result.insert k v
        index := index + 1
      pure result) Std.TreeMap.toList) with schema := .map key.schema value.schema }

/-- The expected type identity is explicit. Optionally restrict references to one scope. -/
def entityId (identity : TypeId) (expectedScope : Option IdentitySpace := none) : Codec (EntityId α) where
  schema := .named identity "entity-id/1" (.record
    [("type", .record [("package", .string), ("name", .string)]),
     ("scope", .string), ("key", .string)])
  encode value := .mkObj [("type", identity.toJson),
    ("scope", .str value.scope.value), ("key", .str value.key)]
  decode value := do
    JsonWire.object ["type", "scope", "key"] value
    let wireType ← JsonWire.get "type" value
    let actual ← Validation.prependPath [.key "type"] (do
      JsonWire.object ["package", "name"] wireType
      let packageName ← JsonWire.stringField "package" wireType
      let name ← JsonWire.stringField "name" wireType
      pure (TypeId.mk packageName name))
    if actual != identity then
      throw (ValidationErrors.single "identity.type_mismatch" [.key "type"])
    let scopeText ← JsonWire.stringField "scope" value
    let scope ← Validation.prependPath [.key "scope"] (IdentitySpace.parse scopeText)
    if let some expected := expectedScope then
      if scope != expected then
        throw (ValidationErrors.single "identity.scope_mismatch" [.key "scope"])
    let key ← JsonWire.stringField "key" value
    Validation.prependPath [.key "key"] (EntityId.ofParts scope key)

end Codec

/-- Applicative object fields: the source powers encoding; the result powers construction. -/
structure RecordFields (Source Value : Type) where
  schema : List (String × WireSchema)
  encode : Source → List (String × WireValue)
  decode : WireValue → Validation Value

namespace RecordFields

def pure (value : β) : RecordFields α β := ⟨[], fun _ => [], fun _ => .ok value⟩

def field (name : String) (codec : Codec β) (get : α → β) : RecordFields α β :=
  ⟨[(name, codec.schema)], fun source => [(name, codec.encode (get source))], Codec.field name codec⟩

def map (f : β → γ) (fields : RecordFields α β) : RecordFields α γ :=
  { fields with decode := fun value => f <$> fields.decode value }

def apply (functions : RecordFields α (β → γ)) (values : RecordFields α β) : RecordFields α γ :=
  ⟨functions.schema ++ values.schema, fun source => functions.encode source ++ values.encode source,
    fun value => Validation.map2 (fun f a => f a) (functions.decode value) (values.decode value)⟩

def product (left : RecordFields α β) (right : RecordFields α γ) : RecordFields α (β × γ) :=
  (left.map Prod.mk).apply right

end RecordFields

/-- Checked construction rejects ambiguous fields; decoding rejects unknown and missing keys. -/
def Codec.record (identity : TypeId) (fields : RecordFields α α)
    (version : String := "1") : Validation (Codec α) := do
  let names := fields.schema.map Prod.fst
  JsonWire.uniqueNames names
  pure {
    schema := .named identity version (.record fields.schema)
    encode := fun value => .mkObj (fields.encode value)
    decode := fun value => do
      JsonWire.object names value
      fields.decode value
  }

instance : Wire String := ⟨Codec.string⟩
instance : Wire Bool := ⟨Codec.bool⟩
instance : Wire Unit := ⟨Codec.unit⟩
instance : Wire Nat := ⟨Codec.nat⟩
instance : Wire Int := ⟨Codec.int⟩
instance [Wire α] : Wire (Option α) := ⟨Codec.option Wire.codec⟩
instance [Wire α] : Wire (Array α) := ⟨Codec.array Wire.codec⟩
instance [Wire α] : Wire (List α) := ⟨Codec.list Wire.codec⟩
instance [Wire α] [Wire β] : Wire (α × β) := ⟨Codec.product Wire.codec Wire.codec⟩
instance [Wire α] [Wire β] : Wire (Sum α β) := ⟨Codec.sum Wire.codec Wire.codec⟩
instance [Wire ε] [Wire α] : Wire (Except ε α) := ⟨Codec.except Wire.codec Wire.codec⟩
instance [Wire α] : Wire (PatchField α) := ⟨Codec.patch Wire.codec⟩
instance [Ord κ] [Wire κ] [Wire ν] : Wire (Std.TreeMap κ ν) := ⟨Codec.map Wire.codec Wire.codec⟩
instance [HasTypeId α] : Wire (EntityId α) := ⟨Codec.entityId (HasTypeId.typeId (α := α))⟩

end Ontology
