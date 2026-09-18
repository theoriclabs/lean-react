import LeanApp

/-! In-memory document with owner/editor/viewer roles, shared by the ACL matrix and its negative test. -/
namespace AclFixture
open LeanApp LeanApp.Policy LeanApp.Testing Contract Ontology

inductive Role where
  | viewer | editor | owner
  deriving Repr, BEq, DecidableEq, Ord

instance : ToString Role := ⟨fun | .viewer => "viewer" | .editor => "editor" | .owner => "owner"⟩
instance : LE Role := leOfOrd

def roles : List Role := [.viewer, .editor, .owner]

structure Document where
  tenant : String := "fixture"
  owner : String := "alice"
  editors : List String := ["bob"]
  viewers : List String := ["carol"]
  text : String := "draft"

inductive ReadOp : Type → Type where
  | document : ReadOp Document
inductive WriteOp : Type → Type where
  | replace (text : String) : WriteOp Unit

abbrev Fixture := StateM Document

def reads : ReadCapability Fixture ReadOp where
  read op := match op with | .document => get

def commands : CommandCapability Fixture ReadOp WriteOp where
  toRead := reads
  write op := match op with | .replace text => modify fun d => { d with text }

/-- The application's single role resolution: read the resource, then place the caller. -/
def roleOf {α : Type} (context : RequestContext) (cap : ReadCapability Fixture ReadOp) (_ : α) :
    Fixture (Option Role) := do
  let some p := context.principal | return none
  let doc ← cap.read .document
  if p.tenant != doc.tenant then return none
  if p.actor == doc.owner then return some .owner
  if doc.editors.contains p.actor then return some .editor
  if doc.viewers.contains p.actor then return some .viewer
  return none

def readIdentity : OperationId := ⟨"doc", "read", "1"⟩
def editIdentity : OperationId := ⟨"doc", "edit", "1"⟩

def minimums (id : OperationId) : Option Role :=
  if id == readIdentity then some .viewer else if id == editIdentity then some .editor else none

def sample (id : OperationId) : Lean.Json :=
  if id == editIdentity then .str "revised" else .null

/-- `weakened` drops the role check from `edit`; the matrix must notice. -/
def application (weakened : Bool := false) : Validation (Application Fixture) := do
  let read : Operation .query Unit String String ← Operation.canonical .query readIdentity
  let edit : Operation .command String String String ← Operation.canonical .command editIdentity
  let readBinding : BindingE Fixture ReadOp WriteOp read (AtLeast Role .viewer) :=
    BindingE.atLeast Role.viewer roleOf { path := "/doc/read" }
      (fun _ cap _ _ => return .ok (← cap.read .document).text)
  if weakened then
    let editBinding : Binding Fixture ReadOp WriteOp edit := { authenticated with
      http := { path := "/doc/edit" }
      handler := fun _ cap text => do cap.write (.replace text); return .ok text }
    Application.create "acl" [{ name := "documents", exports := [
      readBinding.approve (fun _ => reads), editBinding.approve (fun _ => commands)] }]
  else
    let editBinding : BindingE Fixture ReadOp WriteOp edit (AtLeast Role .editor) :=
      BindingE.atLeast Role.editor roleOf { path := "/doc/edit" }
        (fun _ cap _ text => do cap.write (.replace text); return .ok text)
    Application.create "acl" [{ name := "documents", exports := [
      readBinding.approve (fun _ => reads), editBinding.approve (fun _ => commands)] }]

/-- Deliberately local issuance for the fixture, not authentication. -/
def contexts : Testing.Fixture Role where
  context
    | .anonymous => .anonymous "anonymous"
    | .role .owner | .owner => TrustedNative.issueContext ⟨"alice", "fixture", 1⟩ "owner"
    | .role .editor => TrustedNative.issueContext ⟨"bob", "fixture", 1⟩ "editor"
    | .role .viewer => TrustedNative.issueContext ⟨"carol", "fixture", 1⟩ "viewer"
    | .otherTenant => TrustedNative.issueContext ⟨"alice", "elsewhere", 1⟩ "other-tenant"

def matrix (app : Application Fixture) : Array (AclCase Role) :=
  exhaustiveMatrix app roles minimums sample

def failures (app : Application Fixture) : Array (Failure Role) :=
  (runMatrix app contexts (matrix app)).run' {}

end AclFixture
