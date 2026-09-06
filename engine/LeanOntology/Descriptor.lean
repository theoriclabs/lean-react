import LeanOntology.Codec

namespace Ontology

/-- Typed semantic metadata. Reflection does not grant a codec or a setter. -/
structure ValueDescriptor (α : Type) where
  identity : TypeId
  displayName : String := ""

def ValueDescriptor.toJson (value : ValueDescriptor α) : Lean.Json :=
  .mkObj [("identity", value.identity.toJson), ("displayName", .str value.displayName)]

structure RecordDescriptor (α : Type) where
  identity : TypeId
  Field : Type
  Value : Field → Type
  fields : List Field
  fieldName : Field → String
  valueDescriptor : (field : Field) → ValueDescriptor (Value field)
  get : (field : Field) → α → Value field
  replace? : (field : Field) → Option (α → Value field → α) := fun _ => none

def RecordDescriptor.path (record : RecordDescriptor α) (field : record.Field) :
    FieldPath α (record.Value field) :=
  FieldPath.field record.identity (record.fieldName field) (record.get field)

def RecordDescriptor.lens? (record : RecordDescriptor α) (field : record.Field) :
    Option (Lens α (record.Value field)) :=
  (record.replace? field).map fun set => ⟨record.path field, set⟩

/-- Runtime discovery returns an existential package, never a cast from a string. -/
structure SomeField (α : Type) where
  Value : Type
  descriptor : ValueDescriptor Value
  path : FieldPath α Value

def RecordDescriptor.findField (record : RecordDescriptor α) (name : String) : Option (SomeField α) :=
  match record.fields.find? (fun field => record.fieldName field == name) with
  | none => none
  | some field => some ⟨record.Value field, record.valueDescriptor field, record.path field⟩

def RecordDescriptor.validate (record : RecordDescriptor α) : Validation Unit :=
  JsonWire.uniqueNames (record.fields.map record.fieldName)

/-- Only portable metadata is exported; getters and setters remain local typed values. -/
def RecordDescriptor.toJson (record : RecordDescriptor α) : Lean.Json :=
  .mkObj [("identity", record.identity.toJson), ("kind", .str "record"),
    ("fields", .arr (record.fields.map (fun field => Lean.Json.mkObj
      [("name", .str (record.fieldName field)),
       ("value", (record.valueDescriptor field).toJson),
       ("writable", .bool (record.replace? field).isSome)])).toArray)]

/-- Selection is total and retains the selected payload's type. -/
structure VariantDescriptor (α : Type) where
  identity : TypeId
  Case : Type
  Payload : Case → Type
  cases : List Case
  tag : Case → String
  payloadDescriptor : (variant : Case) → ValueDescriptor (Payload variant)
  inject : (variant : Case) → Payload variant → α
  select : α → (variant : Case) × Payload variant

structure VariantDescriptor.Laws (variant : VariantDescriptor α) : Prop where
  inject_select : ∀ value, variant.inject (variant.select value).1 (variant.select value).2 = value
  select_inject : ∀ tag payload, variant.select (variant.inject tag payload) = ⟨tag, payload⟩
  complete : ∀ value, (variant.select value).1 ∈ variant.cases

def VariantDescriptor.toJson (variant : VariantDescriptor α) : Lean.Json :=
  .mkObj [("identity", variant.identity.toJson), ("kind", .str "variant"),
    ("cases", .arr (variant.cases.map (fun tag => Lean.Json.mkObj
      [("tag", .str (variant.tag tag)), ("payload", (variant.payloadDescriptor tag).toJson)])).toArray)]

/-- Manual typed variants support arbitrary payloads without deriving machinery. -/
def Codec.variant (variant : VariantDescriptor α)
    (payload : (tag : variant.Case) → Codec (variant.Payload tag))
    (version : String := "1") : Validation (Codec α) := do
  JsonWire.uniqueNames (variant.cases.map variant.tag)
  pure {
    schema := .named variant.identity version
      (.variant (variant.cases.map (fun tag => (variant.tag tag, (payload tag).schema))))
    encode := fun value =>
      let selected := variant.select value
      JsonWire.tagged (variant.tag selected.1) ((payload selected.1).encode selected.2)
    decode := fun value => do
      JsonWire.object ["tag", "value"] value
      let tag ← JsonWire.stringField "tag" value
      match variant.cases.find? (fun candidate => variant.tag candidate == tag) with
      | none => Validation.fail "decode.unknown_tag" [.key "tag"] [("actual", tag)]
      | some candidate =>
        let decoded ← Validation.prependPath [.variant tag] (Codec.field "value" (payload candidate) value)
        pure (variant.inject candidate decoded)
  }

/-- Presentations are ordinary values independent of reflection, storage, and codecs. -/
structure Presentation (α : Type u) (Output : Type v) where
  render : α → Output

def Presentation.contramap (view : Presentation β Output) (project : α → β) : Presentation α Output :=
  ⟨fun value => view.render (project value)⟩

def Presentation.map (view : Presentation α β) (render : β → γ) : Presentation α γ :=
  ⟨fun value => render (view.render value)⟩

end Ontology
