import LeanContract.Http
import LeanApp.Binding

/-! Browser client generation from the public manifest: `operations.mjs` (codecs derived from each
operation's `WireSchema`, accepted by `defineHttpOperation`), `operations.d.ts`/`.d.mts` (input,
output and error types with a typed `call` overload per operation) and `manifest.json` (the exact
`/api/manifest` body, embedded so a stale bundle is refused with `incompatible`).

Only schema-describable shapes are generated. A codec whose `decode` validates beyond its schema
(a title length, a status name) is still validated on the server; the client checks the shape. -/
namespace Contract.Generate
open Ontology LeanApp

private def quote (text : String) : String := (Lean.Json.str text).compress

private def identifier (text : String) : String :=
  let cleaned := String.map (fun c => if c.isAlphanum && c.toNat < 128 then c else '_') text
  if cleaned.isEmpty || cleaned.front.isDigit then "_" ++ cleaned else cleaned

private def typeKey (identity : TypeId) : String := s!"{identity.packageName}.{identity.name}"

private def aliasName (identity : TypeId) : String := identifier (typeKey identity)

private def pascal (text : String) : String :=
  match identifier text |>.toList with
  | [] => "Operation"
  | c :: rest => String.ofList (c.toUpper :: rest)

/-- Named schemas in first-visit order; a conflicting body for one identity is an error. -/
private partial def collectNamed (schema : WireSchema) (acc : Array (TypeId × String × WireSchema)) :
    Except String (Array (TypeId × String × WireSchema)) := do
  match schema with
  | .option v | .list v | .array v => collectNamed v acc
  | .product l r | .map l r => collectNamed r (← collectNamed l acc)
  | .record fields | .variant fields =>
    fields.foldlM (fun acc (_, child) => collectNamed child acc) acc
  | .named identity version body =>
    match acc.find? (·.1 == identity) with
    | some (_, priorVersion, prior) =>
      if priorVersion == version && prior == body then pure acc
      else throw s!"generate.conflicting_named_schema {typeKey identity}"
    | none =>
      let acc ← collectNamed body acc
      pure (acc.push (identity, version, body))
  | _ => pure acc

private def isEntityId (version : String) : Bool := version == "entity-id/1"

/-- JavaScript codec expression over `LeanContract/Codecs.mjs`; named types refer to `types`. -/
private partial def codec (schema : WireSchema) : String :=
  match schema with
  | .unit => "unit"
  | .boolean => "bool"
  | .string => "str"
  | .natural => "nat"
  | .integer => "int"
  | .option v => s!"option({codec v})"
  | .list v | .array v => s!"array({codec v})"
  | .product l r => s!"product({codec l}, {codec r})"
  | .map k v => s!"entries({codec k}, {codec v})"
  | .record fields =>
    "record([" ++ ", ".intercalate (fields.map fun (name, child) => s!"[{quote name}, {codec child}]") ++ "])"
  | .variant cases =>
    "variant([" ++ ", ".intercalate (cases.map fun (tag, child) => s!"[{quote tag}, {codec child}]") ++ "])"
  | .named identity version _ =>
    if isEntityId version then s!"entityId({quote identity.packageName}, {quote identity.name})"
    else s!"types.{aliasName identity}"
  | .ref identity => s!"ref(types, {quote (aliasName identity)})"

/-- TypeScript type expression. Options and variants are tagged unions; integers are `bigint`. -/
private partial def tsType (schema : WireSchema) : String :=
  match schema with
  | .unit => "null"
  | .boolean => "boolean"
  | .string => "string"
  | .natural | .integer => "bigint"
  | .option v => s!"Option<{tsType v}>"
  | .list v | .array v => s!"{tsType v}[]"
  | .product l r => s!"[{tsType l}, {tsType r}]"
  | .map k v => s!"[{tsType k}, {tsType v}][]"
  | .record [] => "Record<string, never>"
  | .record fields => "{ " ++ "; ".intercalate (fields.map fun (name, child) => s!"{quote name}: {tsType child}") ++ " }"
  | .variant [] => "never"
  | .variant cases =>
    " | ".intercalate (cases.map fun (tag, child) => s!"\{ tag: {quote tag}; value: {tsType child} }")
  | .named identity _ _ | .ref identity => aliasName identity

/-- A schema-shaped sample, used to evaluate a status policy per variant tag. -/
private partial def sample (schema : WireSchema) : Option Lean.Json :=
  match schema with
  | .unit => some .null
  | .boolean => some (.bool false)
  | .string => some (.str "")
  | .natural => some (JsonWire.tagged "nat" (.str "0"))
  | .integer => some (JsonWire.tagged "int" (.str "0"))
  | .option _ => some (.mkObj [("tag", .str "none")])
  | .list _ | .array _ | .map _ _ => some (.arr #[])
  | .product l r => do pure (.arr #[← sample l, ← sample r])
  | .record fields => do
    let values ← fields.mapM fun (name, child) => do pure (name, ← sample child)
    pure (.mkObj values)
  | .variant ((tag, child) :: _) => do pure (JsonWire.tagged tag (← sample child))
  | .variant [] => none
  | .named identity version body =>
    if isEntityId version then
      some (.mkObj [("type", identity.toJson), ("scope", .str "sample"), ("key", .str "sample")])
    else sample body
  | .ref _ => none

private partial def stripNamed : WireSchema → WireSchema
  | .named _ _ body => stripNamed body
  | schema => schema

/-- Statuses per error tag, evaluated through the Lean policy. A policy that needs a decodable
payload beyond the schema sample must be declared with `ErrorStatus.ofTags`. -/
private def errorStatuses (op : PublicOperation) (policy : Http.ErrorStatus) :
    Except String (Option (List (String × Nat)) × Option Nat) := do
  let identity := s!"{op.operation.identity.namespaceName}.{op.operation.identity.name}"
  let evaluate : String → Lean.Json → Except String Nat := fun tag value =>
    match policy.decodeStatus value with
    | .ok status => pure status
    | .error _ => throw s!"generate.status_undecidable {identity} {tag}: \
        declare the table with Contract.Http.ErrorStatus.ofTags"
  match stripNamed op.operation.error with
  | .variant cases =>
    let table ← cases.mapM fun (tag, child) => do
      let payload := (sample child).getD .null
      pure (tag, ← evaluate tag (JsonWire.tagged tag payload))
    pure (some table, none)
  | other =>
    let payload := (sample other).getD .null
    pure (none, some (← evaluate "value" payload))

private structure Emitted where
  key : String
  op : PublicOperation
  statuses : Option (List (String × Nat)) × Option Nat

private def operationKeys (ops : List PublicOperation) : List String :=
  ops.map fun op =>
    let name := op.operation.identity.name
    if (ops.filter (·.operation.identity.name == name)).length == 1 then identifier name
    else identifier s!"{op.operation.identity.namespaceName}_{name}"

private def identityLiteral (identity : OperationId) : String :=
  s!"\{ namespace: {quote identity.namespaceName}, name: {quote identity.name}, version: {quote identity.version} }"

private def kindLiteral : OperationKind → String
  | .query => "\"query\""
  | .command => "\"command\""

private def javascript (emitted : List Emitted) (named : Array (TypeId × String × WireSchema))
    (manifest : Lean.Json) (manifestPath runtime : String) : String :=
  let types := named.filter (fun (_, version, _) => !isEntityId version) |>.toList.map fun (identity, _, body) =>
    s!"types.{aliasName identity} = named({quote (typeKey identity)}, {codec body});"
  let operations := emitted.map fun e =>
    let op := e.op
    let status := match e.statuses with
      | (some table, _) =>
        "statusByTag({ " ++ ", ".intercalate (table.map fun ((tag, status) : String × Nat) => s!"{quote tag}: {status}") ++ " })"
      | (none, some status) => s!"() => {status}"
      | (none, none) => ""
    let errorPolicy := if status.isEmpty then "" else
      s!",\n      decodeError: value => error.decode(value, []), errorStatus: {status}"
    let cap := match op.http.maxBodyBytes with | some cap => toString cap | none => "null"
    s!"  {e.key}: (() => \{
    const input = {codec op.operation.input}, output = {codec op.operation.output}, error = {codec op.operation.error};
    return defineHttpOperation(\{
      identity: {identityLiteral op.operation.identity}, kind: {kindLiteral op.operation.kind}, path: {quote op.http.path},
      maxBodyBytes: {cap}, describePolicy: {quote op.metadata.describePolicy}, input, output, error,
      encodeInput: value => input.encode(value, []), decodeOutput: value => output.decode(value, []){errorPolicy},
    });
  })(),"
  "// Generated by LeanContract.Generate from the public manifest. Do not edit; regenerate instead.\n" ++
  s!"import \{ CallFailure, defineHttpOperation, decodeHttpReply, createHttpClient } from {quote (runtime ++ "/Fetch.mjs")};\n" ++
  s!"import \{ unit, bool, str, nat, int, option, array, product, entries, record, variant, entityId, named, ref, statusByTag, canonical } from {quote (runtime ++ "/Codecs.mjs")};\n" ++
  "export { CallFailure, decodeHttpReply, canonical };\n\n" ++
  "export const types = {};\n" ++ "\n".intercalate types ++ "\n" ++
  "Object.freeze(types);\n\n" ++
  s!"export const manifestPath = {quote manifestPath};\n" ++
  s!"export const manifest = Object.freeze({manifest.compress});\n\n" ++
  "export const operations = Object.freeze({\n" ++ "\n".intercalate operations ++ "\n});\n\n" ++
  "// `verify` compares the served manifest with the embedded one before the first request.\n" ++
  "export function createClient({ verify = false, ...options } = {}) {\n" ++
  "  const client = createHttpClient({ ...options, operations: Object.values(operations) });\n" ++
  "  const fetchImpl = options.fetch ?? globalThis.fetch, baseURL = options.baseURL ?? '';\n" ++
  "  let verified = null;\n" ++
  "  async function verifyManifest() {\n" ++
  "    let served;\n" ++
  "    try { served = await (await fetchImpl(`${baseURL}${manifestPath}`, { credentials: 'same-origin', redirect: 'error' })).json(); }\n" ++
  "    catch (cause) { throw new CallFailure('transport', 'manifest.unavailable', cause); }\n" ++
  "    if (canonical(served) !== canonical(manifest))\n" ++
  "      throw new CallFailure('incompatible', 'contract.stale_manifest', { expected: manifest, received: served });\n" ++
  "  }\n" ++
  "  return Object.freeze({\n" ++
  "    manifest, operations, verifyManifest,\n" ++
  "    async call(identity, input, callOptions) {\n" ++
  "      if (verify) await (verified ??= verifyManifest().catch(error => { verified = null; throw error; }));\n" ++
  "      return client.call(identity, input, callOptions);\n" ++
  "    },\n" ++
  "  });\n" ++
  "}\n"

private def declarations (emitted : List Emitted) (named : Array (TypeId × String × WireSchema))
    (codecs : Http.Codecs) : String :=
  let aliases := named.toList.map fun (identity, _, body) =>
    s!"export type {aliasName identity} = {tsType body};"
  let opTypes := emitted.map fun e =>
    let name := pascal e.key
    let error := if e.statuses == (none, none) then "never" else tsType e.op.operation.error
    s!"export type {name}Input = {tsType e.op.operation.input};\n" ++
    s!"export type {name}Output = {tsType e.op.operation.output};\n" ++
    s!"export type {name}Error = {error};"
  let identityType := fun (identity : OperationId) =>
    s!"\{ readonly namespace: {quote identity.namespaceName}; readonly name: {quote identity.name}; readonly version: {quote identity.version} }"
  let opDecls := emitted.map fun e =>
    let name := pascal e.key
    s!"  readonly {e.key}: HttpOperation<{identityType e.op.operation.identity}, {name}Input, {name}Output, {name}Error>;"
  let overloads := emitted.map fun e =>
    let name := pascal e.key
    s!"  call(identity: {identityType e.op.operation.identity}, input: {name}Input, options?: CallOptions): Promise<Result<{name}Output, {name}Error>>;"
  "// Generated by LeanContract.Generate from the public manifest. Do not edit; regenerate instead.\n" ++
  "export type Option<T> = { tag: \"none\" } | { tag: \"some\"; value: T };\n" ++
  "export type Result<T, E> = { readonly ok: true; readonly value: T } | { readonly ok: false; readonly error: E };\n" ++
  "export interface Codec<T> { encode(value: T, path?: (string | number)[]): unknown; decode(value: unknown, path?: (string | number)[]): T }\n" ++
  "export interface HttpOperation<Identity, Input, Output, Error> {\n" ++
  "  readonly identity: Identity; readonly kind: \"query\" | \"command\"; readonly path: string;\n" ++
  "  readonly maxBodyBytes: number | null; readonly describePolicy: string;\n" ++
  "  readonly input: Codec<Input>; readonly output: Codec<Output>; readonly error: Codec<Error>;\n" ++
  "  readonly encodeInput: (input: Input) => unknown; readonly decodeOutput: (value: unknown) => Output;\n" ++
  "  readonly decodeError?: (value: unknown) => Error; readonly errorStatus?: (error: Error) => number;\n" ++
  "}\n" ++
  "export declare class CallFailure extends Error {\n" ++
  "  readonly kind: \"transport\" | \"protocol\" | \"decode\" | \"incompatible\" | \"unauthenticated\" | \"forbidden\" | \"cancelled\";\n" ++
  "  readonly code: string; readonly detail: unknown;\n" ++
  "}\n" ++
  "export interface CallOptions { readonly signal?: AbortSignal }\n" ++
  "export interface ClientOptions { readonly baseURL?: string; readonly fetch?: typeof fetch; readonly verify?: boolean }\n" ++
  "export interface ManifestOperation {\n" ++
  "  readonly namespace: string; readonly name: string; readonly version: string; readonly kind: \"query\" | \"command\";\n" ++
  "  readonly input: unknown; readonly output: unknown; readonly error: unknown;\n" ++
  "  readonly http: { readonly path: string; readonly method: string; readonly maxBodyBytes: number | null };\n" ++
  "  readonly metadata: { readonly title: string; readonly description: string; readonly describePolicy: string;\n" ++
  "    readonly publish: { readonly topicField: string; readonly topicPrefix: string; readonly eventName: string; readonly alsoToActorField: string | null } | null;\n" ++
  "    readonly issuesStreamTicket: boolean };\n" ++
  "}\n" ++
  "export interface Manifest { readonly operations: readonly ManifestOperation[] }\n" ++
  s!"export type WireOperationId = {tsType codecs.operationId.schema};\n" ++
  s!"export type WireDecodeErrors = {tsType codecs.errors.schema};\n\n" ++
  "\n".intercalate aliases ++ "\n\n" ++ "\n".intercalate opTypes ++ "\n\n" ++
  "export declare const types: Readonly<Record<string, Codec<unknown>>>;\n" ++
  "export declare const manifestPath: string;\n" ++
  "export declare const manifest: Manifest;\n" ++
  "export declare const operations: {\n" ++ "\n".intercalate opDecls ++ "\n};\n" ++
  "export interface Client {\n" ++ "\n".intercalate overloads ++ "\n" ++
  "  readonly manifest: Manifest; readonly operations: typeof operations;\n" ++
  "  verifyManifest(): Promise<void>;\n" ++
  "}\n" ++
  "export declare function createClient(options?: ClientOptions): Client;\n" ++
  "export declare function decodeHttpReply<Identity, Input, Output, Error>(operation: HttpOperation<Identity, Input, Output, Error>, status: number, body: unknown): Result<Output, Error>;\n" ++
  "export declare function canonical(value: unknown): string;\n"

/-- `runtime` is the import path of `engine/LeanContract` relative to `out`;
`manifestPath` must match the server's `ServerConfig.manifestPath`. -/
def emitClient (ops : List PublicOperation) (codecs : Http.Codecs) (statuses : List Http.ErrorStatus)
    (out : System.FilePath) (runtime : String := "../../engine/LeanContract")
    (manifestPath : String := "/api/manifest") : IO Unit := do
  let keys := operationKeys ops
  let emitted ← (ops.zip keys).mapM fun (op, key) => do
    let statuses ← match statuses.find? (·.identity == op.operation.identity) with
      | some policy => IO.ofExcept (errorStatuses op policy)
      | none => pure (none, none)
    pure ({ key, op, statuses } : Emitted)
  let schemas := ops.flatMap (fun op => [op.operation.input, op.operation.output, op.operation.error]) ++
    [codecs.operationId.schema, codecs.errors.schema]
  let named ← IO.ofExcept (schemas.foldlM (fun acc s => collectNamed s acc) #[])
  let manifest := PublicOperation.manifest ops
  IO.FS.createDirAll out
  IO.FS.writeFile (out / "operations.mjs") (javascript emitted named manifest manifestPath runtime)
  let types := declarations emitted named codecs
  IO.FS.writeFile (out / "operations.d.ts") types
  IO.FS.writeFile (out / "operations.d.mts") types
  IO.FS.writeFile (out / "manifest.json") manifest.compress

end Contract.Generate
