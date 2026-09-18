import LeanAppNative.Auth.Http
import Cafe

namespace LeanAppNative.Cafe
open LeanApp Contract Ontology LeanDb

structure RecipeRow where
  publicId : String
  actor : String
  tenant : String
  label : String
  temperature : String
  size : String
  milk : String
  shots : String
  decaf : Bool
  deriving LeanDb.Entity

def base : Base := { name := "proof_and_pour", tables := Auth.tables ++ [.of RecipeRow] }

structure Save where
  name : String
  configuration : _root_.Cafe.Draft

structure Recipe where
  id : String
  name : String
  configuration : _root_.Cafe.Draft
  priceMinor : String

def draftCodec : Codec _root_.Cafe.Draft where
  schema := .record [("temperature", .string), ("size", .string), ("milk", .string),
    ("shots", .string), ("decaf", .boolean)]
  encode d := .mkObj [("temperature", .str d.temperature), ("size", .str d.size),
    ("milk", .str d.milk), ("shots", .str d.shots), ("decaf", .bool d.decaf)]
  decode value := do
    JsonWire.object ["temperature", "size", "milk", "shots", "decaf"] value
    let d := _root_.Cafe.Draft.mk (← Codec.field "temperature" Codec.string value)
      (← Codec.field "size" Codec.string value) (← Codec.field "milk" Codec.string value)
      (← Codec.field "shots" Codec.string value) (← Codec.field "decaf" Codec.bool value)
    let .ok _ := d.configuration | Validation.fail "cafe.invalid_configuration"
    pure d

instance : Wire Save where
  codec := {
    schema := .record [("name", .string), ("configuration", draftCodec.schema)]
    encode d := .mkObj [("name", .str d.name), ("configuration", draftCodec.encode d.configuration)]
    decode value := do
      JsonWire.object ["name", "configuration"] value
      let name ← Codec.field "name" Codec.string value
      let name := name.trimAscii.toString
      if name.isEmpty || name.length > 60 then Validation.fail "cafe.invalid_name"
      pure ⟨name, ← Codec.field "configuration" draftCodec value⟩ }

instance : Wire Recipe where
  codec := {
    schema := .record [("id", .string), ("name", .string),
      ("configuration", draftCodec.schema), ("priceMinor", .string)]
    encode r := .mkObj [("id", .str r.id), ("name", .str r.name),
      ("configuration", draftCodec.encode r.configuration), ("priceMinor", .str r.priceMinor)]
    decode value := do
      JsonWire.object ["id", "name", "configuration", "priceMinor"] value
      pure ⟨← Codec.field "id" Codec.string value, ← Codec.field "name" Codec.string value,
        ← Codec.field "configuration" draftCodec value, ← Codec.field "priceMinor" Codec.string value⟩ }

private def asRecipe (r : RecipeRow) : Except String Recipe := do
  let draft : _root_.Cafe.Draft := ⟨r.temperature, r.size, r.milk, r.shots, r.decaf⟩
  let price ← _root_.Cafe.price draft
  pure ⟨r.publicId, r.label, draft, toString price.minor⟩

private def rows (p : Principal) : DbM (Array (Stored RecipeRow)) :=
  selectP [RecipeRow] (.and (.eq (.here RecipeRow.Field.actor) .eq p.actor)
    (.eq (.here RecipeRow.Field.tenant) .eq p.tenant))

private def db (conn : Conn) (action : DbM α) : IO α := do
  let .ok result ← DbM.run conn action | throw (IO.userError "cafe storage unavailable")
  pure result

private def listRecipes (conn : Conn) (p : Principal) : IO (Array Recipe) := db conn do
  let stored ← rows p
  stored.mapM fun row => match asRecipe row.val with
    | .ok r => pure r | .error _ => throw (.sqlite "invalid stored recipe")

private def saveRecipe (conn : Conn) (p : Principal) (input : Save) : IO (Except String Recipe) := do
  let .ok amount := _root_.Cafe.price input.configuration | return .error "invalid_configuration"
  let id ← Auth.Crypto.randomToken
  db conn <| transaction do
    if (← rows p).size ≥ 40 then return .abort "recipe_limit"
    let c := input.configuration
    discard <| insert RecipeRow ⟨id, p.actor, p.tenant, input.name, c.temperature, c.size, c.milk, c.shots, c.decaf⟩
    return .commit ⟨id, input.name, c, toString amount.minor⟩

private def deleteRecipe (conn : Conn) (p : Principal) (id : String) : IO (Except String Unit) := db conn <| transaction do
  -- Matching both actor and tenant makes guessed IDs indistinguishable from missing IDs.
  untrackedSqlite fun handle => do
    let stmt ← handle.prepare s!"DELETE FROM {quoteIdent (Entity.tableName RecipeRow)} WHERE publicId = ? AND actor = ? AND tenant = ?"
    stmt.bindText 1 id
    stmt.bindText 2 p.actor
    stmt.bindText 3 p.tenant
    discard stmt.step
  return .commit ()

inductive Read : Type → Type where
  | recipes : Read (Array Recipe)
inductive Write : Type → Type where
  | save (input : Save) : Write (Except String Recipe)
  | delete (id : String) : Write (Except String Unit)

private def performWrite (conn : Conn) (p : Principal) : {α : Type} → Write α → IO α
  | _, .save input => saveRecipe conn p input
  | _, .delete id => deleteRecipe conn p id

private def applicationFor (conn : Option Conn) : Validation (Application IO) := do
  let listOp : Operation .query Unit (Array Recipe) String ← Operation.canonical .query ⟨"cafe", "list", "1"⟩
  let saveOp : Operation .command Save Recipe String ← Operation.canonical .command ⟨"cafe", "save", "1"⟩
  let deleteOp : Operation .command String Unit String ← Operation.canonical .command ⟨"cafe", "delete", "1"⟩
  let listBinding : Binding IO Read Write listOp := { Policy.authenticated with
    http := { path := "/api/recipes/list" }
    handler := fun _ cap _ => return .ok (← cap.read .recipes) }
  let saveBinding : Binding IO Read Write saveOp := { Policy.authenticated with
    http := { path := "/api/recipes/save" }
    handler := fun _ cap input => cap.write (.save input) }
  let deleteBinding : Binding IO Read Write deleteOp := { Policy.authenticated with
    http := { path := "/api/recipes/delete" }
    handler := fun _ cap input => cap.write (.delete input) }
  let read := fun (context : RequestContext) => {
    read := fun .recipes => do
      let some conn := conn | throw (IO.userError "inert template")
      let some p := context.principal | throw (IO.userError "unauthenticated")
      listRecipes conn p : ReadCapability IO Read }
  let write := fun (context : RequestContext) => {
    toRead := read context
    write := fun {α} (request : Write α) => do
      let some conn := conn | throw (IO.userError "inert template")
      let some p := context.principal | throw (IO.userError "unauthenticated")
      performWrite conn p request : CommandCapability IO Read Write }
  Application.create "proof-and-pour" [{ name := "recipes", exports := [
    listBinding.approve read, saveBinding.approve write, deleteBinding.approve write] }]

def application (conn : Conn) := applicationFor (some conn)

def host (service : Auth.Service) (origin : String) (development : Bool := false) : IO Auth.Host := do
  let .ok codecs := Http.codecs | throw (IO.userError "invalid codecs")
  let .ok app := applicationFor none | throw (IO.userError "invalid cafe application")
  let .ok saveOp := (Operation.canonical .command ⟨"cafe", "save", "1"⟩ : Validation (Operation .command Save Recipe String))
    | throw (IO.userError "invalid save contract")
  let .ok template := Server.create app codecs {
    maxBodyBytes := 8192, errorStatuses := [Http.ErrorStatus.ofOperation saveOp (fun _ => 422)] }
    | throw (IO.userError "invalid server")
  let .ok host := Auth.Host.create service template application origin development
    | throw (IO.userError "invalid authentication origin/configuration")
  pure host

end LeanAppNative.Cafe
