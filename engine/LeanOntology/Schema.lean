import LeanOntology.Path
import Lean.Data.Json

namespace Ontology

/-- A portable description of the explicit wire interpretation, not a storage schema. -/
inductive WireSchema where
  | unit | boolean | string | natural | integer
  | option (value : WireSchema)
  | list (value : WireSchema)
  | array (value : WireSchema)
  | product (left right : WireSchema)
  | map (key value : WireSchema)
  | record (fields : List (String × WireSchema))
  | variant (cases : List (String × WireSchema))
  | named (identity : TypeId) (version : String) (body : WireSchema)
  | ref (identity : TypeId)
  deriving Repr, BEq

def TypeId.toJson (identity : TypeId) : Lean.Json :=
  .mkObj [("package", .str identity.packageName), ("name", .str identity.name)]

/-- References permit a separately assembled recursive schema graph. -/
partial def WireSchema.toJson (schema : WireSchema) : Lean.Json :=
  let node := fun (kind : String) (fields : List (String × Lean.Json)) =>
    Lean.Json.mkObj (("kind", .str kind) :: fields)
  let children := fun (items : List (String × WireSchema)) =>
    Lean.Json.arr (items.map (fun (name, value) =>
      Lean.Json.mkObj [("name", .str name), ("schema", value.toJson)])).toArray
  match schema with
  | .unit => node "unit" []
  | .boolean => node "boolean" []
  | .string => node "string" []
  | .natural => node "tagged-natural" []
  | .integer => node "tagged-integer" []
  | .option value => node "tagged-option" [("value", value.toJson)]
  | .list value => node "list" [("value", value.toJson)]
  | .array value => node "array" [("value", value.toJson)]
  | .product left right => node "product" [("left", left.toJson), ("right", right.toJson)]
  | .map key value => node "entries-map" [("key", key.toJson), ("value", value.toJson)]
  | .record fields => node "record" [("fields", children fields)]
  | .variant cases => node "variant" [("cases", children cases)]
  | .named identity version body => node "named"
      [("identity", identity.toJson), ("version", .str version), ("body", body.toJson)]
  | .ref identity => node "ref" [("identity", identity.toJson)]

end Ontology
