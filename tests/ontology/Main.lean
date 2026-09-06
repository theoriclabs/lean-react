import tests.ontology.Fixtures

open Ontology Contract OntologyTests

private instance [BEq ε] [BEq α] : BEq (Except ε α) where
  beq
    | .ok a, .ok b => a == b
    | .error a, .error b => a == b
    | _, _ => false

private def check (label : String) (condition : Bool) : IO Unit :=
  unless condition do throw (IO.userError s!"FAIL: {label}")

private def equal [BEq α] [Repr α] (label : String) (actual expected : α) : IO Unit :=
  unless actual == expected do
    throw (IO.userError s!"FAIL: {label}\nactual: {repr actual}\nexpected: {repr expected}")

private def expectOk [Repr ε] (label : String) (result : Except ε α) : IO α :=
  match result with
  | .ok value => pure value
  | .error error => throw (IO.userError s!"FAIL: {label}: {repr error}")

private def reject (label : String) (result : Validation α) (code : String)
    (path : FieldPathId := []) : IO Unit := do
  match result with
  | .ok _ => throw (IO.userError s!"FAIL: {label}: unexpectedly accepted")
  | .error errors =>
    equal (label ++ " code") errors.first.code code
    equal (label ++ " path") errors.first.path path

private def roundTrip [BEq α] [Repr α] (label : String) (codec : Codec α) (value : α) : IO Unit := do
  let decoded ← expectOk label (codec.decodeJson (codec.encodeJson value))
  equal label decoded value

private def testPaths : IO Unit := do
  let workspace : Workspace := ⟨sample, "inbox"⟩
  let path := workspaceTicket.toFieldPath.comp (ticketTitle.toFieldPath.comp titleValue)
  equal "composed path value" (path.get workspace) sample.title.value
  equal "path metadata order" path.identity
    [.field ⟨"tests", "Workspace"⟩ "ticket", .field ⟨"tests", "Ticket"⟩ "title",
     .field ⟨"tests", "Title"⟩ "value"]
  let left := (workspaceTicket.toFieldPath.comp ticketTitle.toFieldPath).comp titleValue
  equal "path associativity" left.identity path.identity
  equal "path identity" (path.comp FieldPath.id).identity path.identity
  let lens := workspaceTicket.comp ticketTitle
  let updated := lens.set workspace ⟨"Edited"⟩
  equal "composed replacement" updated.ticket.title.value "Edited"
  equal "replacement preserves sibling" updated.label "inbox"
  equal "replacement preserves other field" updated.ticket.priority sample.priority
  equal "lens get/set" (lens.set workspace (lens.get workspace)) workspace
  equal "lens set/set" (lens.set (lens.set workspace ⟨"A"⟩) ⟨"B"⟩) (lens.set workspace ⟨"B"⟩)
  equal "lens modify" ((lens.modify (fun title => ⟨title.value ++ "!"⟩) workspace).ticket.title.value)
    "Compose foundations!"
  let validator := (Validator.check "text.empty" (fun (s : String) => !s.isEmpty)).and
    (Validator.check "text.short" (fun s => s.length > 3))
  let invalid := { workspace with ticket := { sample with title := ⟨""⟩ } }
  match (Validator.atPath path validator) invalid with
  | .ok _ => throw (IO.userError "FAIL: validation should accumulate")
  | .error errors =>
    equal "validation count" errors.toList.length 2
    equal "typed error paths" (errors.toList.map ValidationError.path) [path.identity, path.identity]
    equal "validation codes" (errors.toList.map ValidationError.code) ["text.empty", "text.short"]
  IO.println "PASS paths, optional lens laws, and structured validation"

private def testNumbers : IO Unit := do
  let huge : Nat := 2^256 + 9007199254740993
  for n in [0, 1, 9007199254740993, huge, 10^200] do
    roundTrip "exact Nat JSON" Codec.nat n
  for n in [(0 : Int), 1, -1, Int.ofNat huge, -(Int.ofNat huge)] do
    roundTrip "exact Int JSON" Codec.int n
  check "Nat encodes decimal string" (Codec.nat.encode huge == JsonWire.tagged "nat" (.str (toString huge)))
  reject "raw numeric transport" (Codec.nat.decode (.num 9007199254740993)) "decode.expected_object"
  reject "wrong numeric tag" (Codec.int.decode (Codec.nat.encode 1)) "decode.unknown_tag" [.key "tag"]
  reject "leading zero" (Codec.nat.decode (JsonWire.tagged "nat" (.str "001")))
    "decode.noncanonical_integer" [.key "value"]
  reject "negative zero" (Codec.int.decode (JsonWire.tagged "int" (.str "-0")))
    "decode.noncanonical_integer" [.key "value"]
  reject "negative natural" (Codec.nat.decode (JsonWire.tagged "nat" (.str "-1")))
    "decode.invalid_natural" [.key "value"]
  reject "integer exponent" (Codec.int.decode (JsonWire.tagged "int" (.str "1e3")))
    "decode.invalid_integer" [.key "value"]
  reject "number in decimal field" (Codec.nat.decode (JsonWire.tagged "nat" (.num 1)))
    "decode.expected_string" [.key "value"]
  reject "extra integer field" (Codec.nat.decode (.mkObj
    [("tag", .str "nat"), ("value", .str "1"), ("extra", .null)])) "decode.unknown_field" [.key "extra"]
  reject "invalid JSON" (Codec.nat.decodeJson "{") "decode.invalid_json"
  let textNat := Codec.string.checked
    (fun text => match text.toNat? with
      | some n => if toString n == text then .ok n else Validation.fail "natural.invalid"
      | none => Validation.fail "natural.invalid") toString
  roundTrip "alternative Nat codec" textNat huge
  roundTrip "canonical instance remains available" (Codec.canonical : Codec Nat) huge
  check "two encodings coexist" (textNat.encode huge != Codec.nat.encode huge)
  reject "canonical codec rejects alternate encoding" (Codec.nat.decode (textNat.encode huge))
    "decode.expected_object"
  let bounded := Codec.nat.checked
    (fun n => if n < 10 then .ok n else Validation.fail "small.out_of_range") id
  reject "checked numeric mapping" (bounded.decode (Codec.nat.encode 10)) "small.out_of_range"
  IO.println "PASS exact integers, malformed JSON, and explicit/canonical codecs"

private def testCombinators : IO Unit := do
  let nested := Codec.option (Codec.option Codec.nat)
  let values : List (Option (Option Nat)) := [none, some none, some (some (2^128))]
  for value in values do roundTrip "nested option" nested value
  check "none differs from some none" (nested.encode none != nested.encode (some none))
  check "some none differs from some some" (nested.encode (some none) != nested.encode (some (some 0)))
  roundTrip "some unit null payload" (Codec.option Codec.unit) (some ())
  reject "null is not none" (nested.decode .null) "decode.expected_object"
  reject "missing option payload" (nested.decode (.mkObj [("tag", .str "some")]))
    "decode.missing_field" [.key "value"]
  reject "none cannot carry payload" (nested.decode (JsonWire.tagged "none" .null))
    "decode.unknown_field" [.key "value"]
  reject "unknown option tag" (nested.decode (JsonWire.tagged "missing" .null))
    "decode.unknown_tag" [.key "tag"]
  let compound := Codec.product (Codec.list nested) (Codec.array (Codec.sum Codec.string Codec.int))
  roundTrip "product/list/array/sum composition" compound (values, #[.inl "λ🧪", .inr (-(2^128))])
  roundTrip "empty list" (Codec.list Codec.nat) []
  roundTrip "empty array" (Codec.array Codec.string) #[]
  roundTrip "Except success" (Codec.except Codec.string Codec.nat) (.ok (2^80))
  roundTrip "Except error" (Codec.except Codec.string Codec.nat) (.error "missing")
  reject "pair arity" ((Codec.product Codec.nat Codec.nat).decode (.arr #[])) "decode.expected_pair"
  match (Codec.product Codec.string Codec.bool).decode (.arr #[.null, .null]) with
  | .ok _ => throw (IO.userError "FAIL: malformed pair accepted")
  | .error errors =>
    equal "product accumulates paths" (errors.toList.map ValidationError.path) [[.index 0], [.index 1]]
  match (Codec.array Codec.nat).decode (.arr #[.null, Codec.nat.encode 1, .null]) with
  | .ok _ => throw (IO.userError "FAIL: malformed array accepted")
  | .error errors =>
    equal "array accumulates paths" (errors.toList.map ValidationError.path) [[.index 0], [.index 2]]
  let patches := Codec.patch (Codec.option Codec.string)
  for patch in [PatchField.keep, .set none, .set (some "owner")] do
    roundTrip "patch omission/clearing" patches patch
  equal "patch keep" (PatchField.keep.apply (some "old")) (some "old")
  equal "patch clear" ((PatchField.set none).apply (some "old")) none
  check "keep differs from clear" (patches.encode .keep != patches.encode (.set none))
  let mapCodec := Codec.map Codec.nat (Codec.option Codec.string)
  let dict : Std.TreeMap Nat (Option String) := ({} : Std.TreeMap Nat (Option String))
    |>.insert (2^128) (some "huge") |>.insert 2 none
  let decoded ← expectOk "typed map" (mapCodec.decodeJson (mapCodec.encodeJson dict))
  equal "typed map round trip" decoded.toList dict.toList
  let duplicate := (Codec.list (Codec.product Codec.nat (Codec.option Codec.string))).encode
    [(2, none), (2, some "duplicate")]
  reject "duplicate map key" (mapCodec.decode duplicate) "decode.duplicate_key" [.index 1, .index 0]
  reject "object is not typed map entries" (mapCodec.decode (.mkObj [])) "decode.expected_array"
  IO.println "PASS products, maps, options, lists, arrays, alternatives, and patches"

private def testIdentity : IO Unit := do
  let user ← expectOk "user identity" (EntityId.parse (α := User) "workspace-A" "17")
  let other ← expectOk "second scope" (EntityId.parse (α := User) "workspace-B" "17")
  check "scope participates in identity" (user != other)
  let codec : Codec (EntityId User) := Codec.canonical
  roundTrip "nominal entity codec" codec user
  let ticketCodec : Codec (EntityId Ticket) := Codec.canonical
  reject "nominal reference mismatch" (ticketCodec.decode (codec.encode user))
    "identity.type_mismatch" [.key "type"]
  let scopeCodec : Codec (EntityId User) := Codec.entityId ⟨"tests", "User"⟩ (some user.scope)
  roundTrip "scope restricted reference" scopeCodec user
  reject "wrong reference scope" (scopeCodec.decode (codec.encode other))
    "identity.scope_mismatch" [.key "scope"]
  reject "empty scope" (EntityId.parse (α := User) "" "17") "identity.empty_scope"
  reject "empty key" (EntityId.parse (α := User) "workspace-A" "") "identity.empty_key"
  reject "wire empty scope" (codec.decode (.mkObj [("type", (TypeId.mk "tests" "User").toJson),
    ("scope", .str ""), ("key", .str "17")])) "identity.empty_scope" [.key "scope"]
  IO.println "PASS scoped and nominal entity references"

private def testDescriptors : IO Unit := do
  let ticket ← expectOk "record builder" ticketCodec
  let event ← expectOk "variant builder" eventCodec
  let user ← expectOk "record reference" (EntityId.parse (α := User) "workspace" "123")
  roundTrip "record with reference" ticket { sample with owner := some user, priority := 2^128 }
  roundTrip "record with absent reference" ticket sample
  for value in [Event.created (2^128), .renamed ⟨"new title"⟩, .archived] do
    roundTrip "variant payload" event value
  reject "unknown variant" (event.decode (JsonWire.tagged "future" .null))
    "decode.unknown_tag" [.key "tag"]
  reject "invalid variant payload" (event.decode (JsonWire.tagged "renamed" (.str "")))
    "title.empty" [.variant "renamed", .key "value"]
  let parsed ← expectOk "human title normalization" (Title.parse "  hello  ")
  equal "human parser trims" parsed.value "hello"
  reject "wire decoder does not normalize" (titleCodec.decode (.str "  hello  ")) "title.noncanonical"
  reject "unchecked constructor does not imply roundtrip law" (titleCodec.decode (titleCodec.encode ⟨""⟩))
    "title.empty"
  reject "missing record field" (ticket.decode (.mkObj [("title", .str "ok"),
    ("priority", Codec.nat.encode 1)])) "decode.missing_field" [.key "owner"]
  reject "unknown record field" (ticket.decode (.mkObj (ticketFields.encode sample ++ [("extra", .null)])))
    "decode.unknown_field" [.key "extra"]
  match ticket.decode (.mkObj []) with
  | .ok _ => throw (IO.userError "FAIL: missing record fields accepted")
  | .error errors =>
    equal "record accumulates missing fields" (errors.toList.map ValidationError.path)
      [[.key "title"], [.key "priority"], [.key "owner"]]
  let duplicate := RecordFields.product (RecordFields.field "same" Codec.nat Prod.fst)
    (RecordFields.field "same" Codec.nat Prod.snd)
  reject "duplicate record names" (Codec.record (α := Nat × Nat) ⟨"tests", "Pair"⟩ duplicate)
    "schema.duplicate_name"
  let emptyField := RecordFields.field "" Codec.nat (id : Nat → Nat)
  reject "empty record name" (Codec.record ⟨"tests", "Bad"⟩ emptyField) "schema.empty_name"
  let duplicateVariant := { eventDescriptor with cases := [.created, .created] }
  reject "duplicate variant tags" (Codec.variant duplicateVariant eventPayload) "schema.duplicate_name"
  let _ ← expectOk "descriptor validation" ticketDescriptor.validate
  equal (α := Nat) "typed descriptor read" ((ticketDescriptor.path .priority).get sample) 3
  check "descriptor can withhold setter" (ticketDescriptor.lens? .title).isNone
  let lens : Lens Ticket Nat ← match ticketDescriptor.lens? .priority with
    | some lens => pure lens
    | none => throw (IO.userError "FAIL: descriptor setter missing")
  equal "descriptor writable field" (lens.set sample 8).priority 8
  check "existential discovery finds field" (ticketDescriptor.findField "title").isSome
  check "unknown discovery remains absent" (ticketDescriptor.findField "not-a-field").isNone
  check "portable schema is JSON" (Lean.Json.parse ticket.schema.toJson.compress).isOk
  check "portable record descriptor" (Lean.Json.parse ticketDescriptor.toJson.compress).isOk
  check "portable variant descriptor" (Lean.Json.parse eventDescriptor.toJson.compress).isOk
  let compact : Presentation Ticket String := ⟨fun value => value.title.value⟩
  let detailed : Presentation Ticket String := ⟨fun value => s!"{value.title.value} [{value.priority}]"⟩
  check "two presentations coexist" (compact.render sample != detailed.render sample)
  equal "presentation composition" ((compact.contramap Workspace.ticket).render ⟨sample, "board"⟩)
    sample.title.value
  IO.println "PASS manual record/variant descriptors, newtypes, and presentations"

private def testContracts : IO Unit := do
  let ops ← expectOk "operation descriptors" operations
  let router ← expectOk "allowlisted router" (testRouter ops)
  let interpreter := router.transport.interpreter
  let direct := duplicateTicket localService 17
  equal "direct orchestration" direct.priority 14
  let remote ← expectOk "wire-backed orchestration"
    ((duplicateTicket (interpretedService interpreter ops) 17).run)
  equal "wire-backed orchestration result" remote.priority 104
  equal "shared orchestration copies title" remote.title direct.title
  let secondLocal : TicketService Id := { localService with create := fun value => value }
  equal "two explicit dictionaries in same monad" (duplicateTicket secondLocal 17).priority 4
  match interpreter.call ops.get 0 with
  | .error (.domain (.missing id)) => equal "typed missing payload" id 0
  | _ => throw (IO.userError "FAIL: missing domain error lost")
  match interpreter.call ops.create { sample with priority := 999 } with
  | .error (.domain (.conflict current)) => equal "typed conflict payload" current sample
  | _ => throw (IO.userError "FAIL: conflict domain error lost")
  equal "operation kind retained" ops.get.kind .query
  equal "command kind retained" ops.create.kind .command
  equal "manifest includes only registered operations" router.manifest.length 2
  check "manifest serializes" (Lean.Json.parse ops.get.describe.toJson.compress).isOk
  reject "invalid operation identity"
    (Operation.create .query ⟨"", "get", "1"⟩ Codec.nat Codec.nat Codec.string) "operation.empty_identity"
  let route := Route.ofHandler (m := Id) ops.get (fun _ => .ok sample)
  reject "duplicate route identity" (Router.create [route, route]) "operation.duplicate_identity"
  let request : WireRequest := ⟨ops.get.identity, .query, Codec.nat.encode 17⟩
  match router.transport.send { request with kind := .command } with
  | .error (.protocol error) => equal "runtime kind mismatch" error.code "operation.kind_mismatch"
  | _ => throw (IO.userError "FAIL: mismatched operation kind accepted")
  let unknown := { request with operation := { request.operation with name := "private-operation" } }
  match router.transport.send unknown with
  | .error (.protocol error) => equal "allowlist rejects unknown operation" error.code "operation.not_found"
  | _ => throw (IO.userError "FAIL: unknown operation accepted")
  match route.invoke { request with operation := { request.operation with version := "2" } } with
  | .error (.incompatible mismatch) => equal "version mismatch retains identity" mismatch.expected ops.get.identity
  | _ => throw (IO.userError "FAIL: mismatched identity accepted")
  let handler : Handler (StateM Nat) ops.get := fun _ => do
    modify (· + 1)
    pure (.ok sample)
  let (bad, count) := (serve ops.get handler { request with input := .null }).run 0
  equal "invalid input cannot run handler" count 0
  check "invalid input gives decode failure" (match bad with | .error (.decode _) => true | _ => false)
  let (_, count) := (serve ops.get handler request).run 0
  equal "valid input runs handler once" count 1
  let malformed : Transport Id := ⟨fun _ => .ok (.success .null)⟩
  check "malformed success remains decode error"
    (match malformed.interpreter.call ops.get 17 with | .error (.decode _) => true | _ => false)
  let malformedDomain : Transport Id := ⟨fun _ => .ok (.domainError .null)⟩
  check "malformed domain error remains decode error"
    (match malformedDomain.interpreter.call ops.get 17 with | .error (.decode _) => true | _ => false)
  let offline : Transport Id := ⟨fun _ => .error (.transport ⟨"offline", "fixture"⟩)⟩
  match offline.interpreter.call ops.get 17 with
  | .error (.transport error) => equal "transport error preserved" error.code "offline"
  | _ => throw (IO.userError "FAIL: transport error lost")
  let unauthorized : Transport Id := ⟨fun _ => .error .unauthenticated⟩
  check "authentication error preserved"
    (match unauthorized.interpreter.call ops.get 17 with | .error .unauthenticated => true | _ => false)
  let cancelled : Transport Id := ⟨fun _ => .error .cancelled⟩
  check "cancellation error preserved"
    (match cancelled.interpreter.call ops.get 17 with | .error .cancelled => true | _ => false)
  IO.println "PASS typed operations/errors, shared service orchestration, and transport interpretation"

def main : IO Unit := do
  testPaths
  testNumbers
  testCombinators
  testIdentity
  testDescriptors
  testContracts
  IO.println "All ontology and contract executable checks passed."
