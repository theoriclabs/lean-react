import LeanOntology

namespace LeanApp.Domain
open Ontology

deriving instance DecidableEq for Except

private def asciiWhitespace (c : Char) : Bool :=
  let value := c.toNat
  value == 32 || value == 9 || value == 10 || value == 13

private def trimAscii (raw : String) : String :=
  String.ofList ((raw.toList.dropWhile asciiWhitespace).reverse.dropWhile asciiWhitespace).reverse

private def lowerAscii (raw : String) : String :=
  String.ofList (raw.toList.map fun c =>
    if c.toNat ≥ 65 && c.toNat ≤ 90 then Char.ofNat (c.toNat + 32) else c)

private def utf8Bytes (raw : String) : Nat :=
  raw.toList.foldl (fun count c => count +
    if c.toNat < 128 then 1 else if c.toNat < 2048 then 2 else if c.toNat < 65536 then 3 else 4) 0

private def checkedText (code : String) (limit : Nat) (nonempty trim : Bool)
    (raw : String) : Validation String :=
  let value := if trim then trimAscii raw else raw
  if nonempty && value.isEmpty then Validation.fail (code ++ ".empty")
  else if value.length > limit then Validation.fail (code ++ ".too_long")
  else .ok value

private def normalizeName := checkedText "name" 120 true true
private def normalizeTitle := checkedText "title" 120 true true
private def normalizeText := checkedText "text" 10000 false false
private def normalizeEmail (raw : String) : Validation String :=
  let value := lowerAscii (trimAscii raw)
  let chars := value.toList
  let atMarks := chars.filter (fun c => c.toNat == 64)
  if atMarks.length != 1 || (chars.head?.map (fun c => c.toNat == 64)).getD true then
    Validation.fail "email.invalid_mailbox"
  else if (chars.reverse.head?.map (fun c => c.toNat == 64)).getD true then
    Validation.fail "email.invalid_mailbox"
  else if chars.any (fun c => c.toNat > 127 || asciiWhitespace c || c.toNat < 33 || c.toNat == 127) then
    Validation.fail "email.invalid_mailbox"
  else .ok value
private def normalizePassword (raw : String) : Validation String :=
  if raw.length < 15 || raw.length > 128 || utf8Bytes raw > 1024 then Validation.fail "password.invalid_length"
  else .ok raw

structure Name where
  private mk ::
  value : String
  canonical : normalizeName value = .ok value
  deriving BEq, DecidableEq, Repr

/-- Canonicality is checked rather than assumed from constructor privacy. -/
def Name.parse (raw : String) : Validation Name := do
  let value ← normalizeName raw
  if proof : normalizeName value = .ok value then pure ⟨value, proof⟩
  else Validation.fail "scalar.noncanonical_normalizer"

theorem Name.parse_value (value : Name) : Name.parse value.value = .ok value := by
  rcases value with ⟨text, canonical⟩
  simp [Name.parse, canonical, bind, Except.bind, pure, Except.pure]

structure Title where
  private mk ::
  value : String
  canonical : normalizeTitle value = .ok value
  deriving BEq, DecidableEq, Repr

/-- Canonicality is checked rather than assumed from constructor privacy. -/
def Title.parse (raw : String) : Validation Title := do
  let value ← normalizeTitle raw
  if proof : normalizeTitle value = .ok value then pure ⟨value, proof⟩
  else Validation.fail "scalar.noncanonical_normalizer"

theorem Title.parse_value (value : Title) : Title.parse value.value = .ok value := by
  rcases value with ⟨text, canonical⟩
  simp [Title.parse, canonical, bind, Except.bind, pure, Except.pure]

structure Text where
  private mk ::
  value : String
  canonical : normalizeText value = .ok value
  deriving BEq, DecidableEq, Repr

/-- Canonicality is checked rather than assumed from constructor privacy. -/
def Text.parse (raw : String) : Validation Text := do
  let value ← normalizeText raw
  if proof : normalizeText value = .ok value then pure ⟨value, proof⟩
  else Validation.fail "scalar.noncanonical_normalizer"

theorem Text.parse_value (value : Text) : Text.parse value.value = .ok value := by
  rcases value with ⟨text, canonical⟩
  simp [Text.parse, canonical, bind, Except.bind, pure, Except.pure]

structure Email where
  private mk ::
  value : String
  canonical : normalizeEmail value = .ok value
  deriving BEq, DecidableEq, Repr

/-- Canonicality is checked rather than assumed from constructor privacy. -/
def Email.parse (raw : String) : Validation Email := do
  let value ← normalizeEmail raw
  if proof : normalizeEmail value = .ok value then pure ⟨value, proof⟩
  else Validation.fail "scalar.noncanonical_normalizer"

theorem Email.parse_value (value : Email) : Email.parse value.value = .ok value := by
  rcases value with ⟨text, canonical⟩
  simp [Email.parse, canonical, bind, Except.bind, pure, Except.pure]

structure Password where
  private mk ::
  value : String
  canonical : normalizePassword value = .ok value
  deriving BEq, DecidableEq

/-- Canonicality is checked rather than assumed from constructor privacy. -/
def Password.parse (raw : String) : Validation Password := do
  let value ← normalizePassword raw
  if proof : normalizePassword value = .ok value then pure ⟨value, proof⟩
  else Validation.fail "scalar.noncanonical_normalizer"

theorem Password.parse_value (value : Password) : Password.parse value.value = .ok value := by
  rcases value with ⟨text, canonical⟩
  simp [Password.parse, canonical, bind, Except.bind, pure, Except.pure]

def int64Min : Int := -9223372036854775808
def int64Max : Int := 9223372036854775807

structure Instant where
  private mk ::
  value : Int
  valid : int64Min ≤ value ∧ value ≤ int64Max
  deriving BEq, DecidableEq, Repr

def Instant.ofEpochSeconds (value : Int) : Validation Instant :=
  if proof : int64Min ≤ value ∧ value ≤ int64Max then .ok ⟨value, proof⟩
  else Validation.fail "instant.out_of_range"

theorem Instant.ofEpochSeconds_value (value : Instant) : Instant.ofEpochSeconds value.value = .ok value := by
  rcases value with ⟨seconds, valid⟩
  simp [Instant.ofEpochSeconds, valid]

/-- Input is UTC epoch seconds, never a local date-time or a JS number. -/
def Instant.parse (raw : String) : Validation Instant := do
  match JsonWire.decimalInt? raw with
  | none => Validation.fail "instant.invalid_epoch_seconds"
  | some value =>
    if toString value != raw then Validation.fail "instant.noncanonical_epoch_seconds"
    else Instant.ofEpochSeconds value

instance : LT Instant := ⟨fun a b => a.value < b.value⟩
instance (a b : Instant) : Decidable (a < b) := inferInstanceAs (Decidable (a.value < b.value))
instance : LE Instant := ⟨fun a b => a.value ≤ b.value⟩
instance (a b : Instant) : Decidable (a ≤ b) := inferInstanceAs (Decidable (a.value ≤ b.value))

instance : Wire Name := ⟨Codec.string.checked Name.parse Name.value⟩
instance : Wire Title := ⟨Codec.string.checked Title.parse Title.value⟩
instance : Wire Text := ⟨Codec.string.checked Text.parse Text.value⟩
instance : Wire Email := ⟨Codec.string.checked Email.parse Email.value⟩
instance : Wire Password := ⟨Codec.string.checked Password.parse Password.value⟩

abbrev Ref := EntityId

instance (priority := 1100) : BEq (Ref T) := ⟨fun a b => a.scope == b.scope && a.key == b.key⟩

/-- One checked storage-key policy for native and browser callers. -/
def Ref.parse [HasTypeId T] (key : String) (scope : String := "default") : Validation (Ref T) := do
  match JsonWire.decimalInt? key with
  | none => Validation.fail "identity.invalid_key" [.key "key"]
  | some value =>
    if value ≤ 0 || value > int64Max then Validation.fail "identity.key_out_of_range" [.key "key"]
    else if toString value != key then Validation.fail "identity.noncanonical_key" [.key "key"]
    else EntityId.parse scope key

/-- The milestone-1 structured identity form `{"type":…,"scope":…,"key":…}`. Kept for
internal checks and accepted on decode during the decision-15 transition. -/
def refCodec [HasTypeId T] : Codec (Ref T) :=
  (Codec.entityId (HasTypeId.typeId (α := T))).checked
    (fun ref => Ref.parse ref.key ref.scope.value) id

/-- An exact positive JSON integer (no fraction), as its canonical decimal text. -/
def jsonPositiveInteger? : Lean.Json → Option String
  | .num ⟨mantissa, exponent⟩ =>
    let scale := (10 : Int) ^ exponent
    if mantissa > 0 && mantissa % scale == 0 then some (toString (mantissa / scale)) else none
  | _ => none

/-- Decision 15: a reference on the public wire is a bare JSON integer; the endpoint contract
already fixes its type. Non-default scopes never cross the boundary: they encode in the old
structured form, which the decoder then refuses. The old form is accepted on decode (default
scope only) during the transition. -/
def publicRefCodec [HasTypeId T] : Codec (Ref T) where
  schema := .named (HasTypeId.typeId (α := T)) "ref/2" .natural
  encode ref :=
    match ref.scope.value == "default", JsonWire.decimalInt? ref.key with
    | true, some key => .num ⟨key, 0⟩
    | _, _ => refCodec.encode ref
  decode value :=
    match value with
    | .obj _ => do
      let ref ← refCodec.decode value
      if ref.scope.value != "default" then Validation.fail "identity.non_default_scope" [.key "scope"]
      pure ref
    | _ => match jsonPositiveInteger? value with
      | some key => Ref.parse key
      | none => Validation.fail "identity.expected_integer"

/-- Domain code uses this more specific checked identity codec. -/
instance (priority := 1100) [HasTypeId T] : Wire (Ref T) := ⟨publicRefCodec⟩

/-! ## UTC calendar (proleptic Gregorian), exact for the whole signed-64-bit range -/

/-- Days since 1970-01-01 of a civil date (H. Hinnant's `days_from_civil`). -/
def daysFromCivil (year : Int) (month day : Nat) : Int :=
  let y := if month ≤ 2 then year - 1 else year
  let era := y / 400
  let yoe := y - era * 400
  let mp : Int := if month > 2 then month - 3 else month + 9
  let doy := (153 * mp + 2) / 5 + day - 1
  let doe := yoe * 365 + yoe / 4 - yoe / 100 + doy
  era * 146097 + doe - 719468

/-- Civil date of a day count (`civil_from_days`): (year, month, day). -/
def civilFromDays (days : Int) : Int × Nat × Nat :=
  let z := days + 719468
  let era := z / 146097
  let doe := z - era * 146097
  let yoe := (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
  let doy := doe - (365 * yoe + yoe / 4 - yoe / 100)
  let mp := (5 * doy + 2) / 153
  let day := (doy - (153 * mp + 2) / 5 + 1).toNat
  let month := (if mp < 10 then mp + 3 else mp - 9).toNat
  let year := yoe + era * 400 + (if month ≤ 2 then 1 else 0)
  (year, month, day)

private def pad (width : Nat) (value : Nat) : String :=
  let text := toString value
  String.ofList (List.replicate (width - text.length) '0') ++ text

/-- RFC 3339 UTC at second precision, e.g. `2026-10-17T19:00:00Z`. Years outside 0000–9999
use the ISO 8601 expanded form (`+275760-…`, `-000001-…`). -/
def formatRfc3339 (seconds : Int) : String :=
  let days := seconds / 86400
  let second := (seconds % 86400).toNat
  let (year, month, day) := civilFromDays days
  let yearText :=
    if 0 ≤ year && year ≤ 9999 then pad 4 year.toNat
    else (if year < 0 then "-" else "+") ++ pad 6 year.natAbs
  yearText ++ "-" ++ pad 2 month ++ "-" ++ pad 2 day ++ "T" ++ pad 2 (second / 3600) ++ ":" ++
    pad 2 (second % 3600 / 60) ++ ":" ++ pad 2 (second % 60) ++ "Z"

private def digits? (chars : List Char) : Option Nat :=
  if chars.isEmpty || !chars.all (fun c => 48 ≤ c.toNat && c.toNat ≤ 57) then none
  else some (chars.foldl (fun acc c => acc * 10 + (c.toNat - 48)) 0)

private def daysInMonth (year : Int) (month : Nat) : Nat :=
  let leap := (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
  match month with
  | 2 => if leap then 29 else 28
  | 4 | 6 | 9 | 11 => 30
  | _ => 31

/-- Strict canonical RFC 3339 UTC (the exact output of `formatRfc3339`) to epoch seconds. -/
def parseRfc3339? (text : String) : Option Int := do
  let chars := text.toList
  guard (chars.length ≥ 20 && chars.getLast? == some 'Z')
  let body := chars.dropLast
  -- …-MM-DDTHH:MM:SS has a fixed 15-character tail after the year.
  let yearChars := body.take (body.length - 15)
  let tail := body.drop (body.length - 15)
  let (month, day, hour, minute, second) ← match tail with
    | ['-', m₁, m₂, '-', d₁, d₂, 'T', h₁, h₂, ':', n₁, n₂, ':', s₁, s₂] => do
      pure (← digits? [m₁, m₂], ← digits? [d₁, d₂], ← digits? [h₁, h₂], ← digits? [n₁, n₂], ← digits? [s₁, s₂])
    | _ => none
  let year : Int ← match yearChars with
    | '+' :: rest => do guard (rest.length ≥ 6); pure (Int.ofNat (← digits? rest))
    | '-' :: rest => do guard (rest.length ≥ 6); pure (-Int.ofNat (← digits? rest))
    | rest => do guard (rest.length == 4); pure (Int.ofNat (← digits? rest))
  guard (1 ≤ month && month ≤ 12 && 1 ≤ day && day ≤ daysInMonth year month && hour < 24 && minute < 60 && second < 60)
  let seconds := daysFromCivil year month day * 86400 + hour * 3600 + minute * 60 + second
  -- Canonical only: one text per instant (no `+002026`, no `-000000`).
  guard (formatRfc3339 seconds == text)
  pure seconds

/-- Decision 15: `Time` on the public wire is an RFC 3339 UTC string at second precision over
the signed-64-bit range. The milestone-1 `{"tag":"int","value":"…"}` form is accepted on
decode during the transition. -/
def publicInstantCodec : Codec Instant where
  schema := .named { packageName := "leanapp", name := "Time" } "rfc3339/1" .string
  encode instant := .str (formatRfc3339 instant.value)
  decode value :=
    match value with
    | .str text => match parseRfc3339? text with
      | some seconds => Instant.ofEpochSeconds seconds
      | none => Validation.fail "instant.invalid_rfc3339"
    | _ => (Codec.int.checked Instant.ofEpochSeconds Instant.value).decode value

def Instant.rfc3339 (instant : Instant) : String := formatRfc3339 instant.value

/-- Display text in UTC, e.g. `2026-10-17 19:00 UTC` (seconds shown only when nonzero). -/
def Instant.format (instant : Instant) : String :=
  let seconds := instant.value
  let second := (seconds % 86400).toNat
  let (year, month, day) := civilFromDays (seconds / 86400)
  let yearText :=
    if 0 ≤ year && year ≤ 9999 then pad 4 year.toNat
    else (if year < 0 then "-" else "+") ++ pad 6 year.natAbs
  yearText ++ "-" ++ pad 2 month ++ "-" ++ pad 2 day ++ " " ++ pad 2 (second / 3600) ++ ":" ++
    pad 2 (second % 3600 / 60) ++ (if second % 60 == 0 then "" else ":" ++ pad 2 (second % 60)) ++ " UTC"

/-- Checked text is shown as its value: `text book.title` (a `String` is expected, the
coercion applies), or `toString book.title` / `s!"{book.title}"`. -/
instance : Coe Name String := ⟨Name.value⟩
instance : Coe Title String := ⟨Title.value⟩
instance : Coe Text String := ⟨Text.value⟩
instance : Coe Email String := ⟨Email.value⟩
instance : ToString Name := ⟨Name.value⟩
instance : ToString Title := ⟨Title.value⟩
instance : ToString Text := ⟨Text.value⟩
instance : ToString Email := ⟨Email.value⟩
/-- An instant prints in the readable UTC form of `Instant.format`. -/
instance : ToString Instant := ⟨Instant.format⟩

/-- A reference prints as its key, as in a path: `s!"/books/{book}"`. -/
instance : ToString (Ontology.EntityId T) := ⟨Ontology.EntityId.key⟩

instance : Wire Instant := ⟨publicInstantCodec⟩

/-! ## Authentication values (DDD-LAPI-06): server-only, no `Wire`, no `Repr` -/

/-- A password's KDF hash. It has no `Wire` and no `Repr`, so no endpoint can return it and no
log line can print it; its text is sealed (`Trusted.passwordHashText` is the adapter API). -/
structure PasswordHash where
  private mk ::
  private encoded : String

/-- Storage (not wire) representation, for the portable reference backend's rows. -/
def PasswordHash.storageCodec : Codec PasswordHash where
  schema := .named { packageName := "leanapp", name := "PasswordHash" } "storage/1" .string
  encode hash := .str hash.encoded
  decode value := do pure ⟨← JsonWire.string value⟩

/-- A started session. On the wire it is the signed-in profile's reference (a bare integer):
the token itself is set as a cookie, or added to a token-mode reply, by the server after
commit — never part of the domain value. -/
structure Session where
  private mk ::
  profileKey : String
  deriving BEq, Repr

def Session.profile [HasTypeId T] (session : Session) : Validation (Ref T) := Ref.parse session.profileKey

instance : Wire Session := ⟨{
  schema := .named { packageName := "leanapp", name := "Session" } "ref/2" .natural
  encode := fun session => match JsonWire.decimalInt? session.profileKey with
    | some key => .num ⟨key, 0⟩
    | none => .str session.profileKey
  decode := fun value => match jsonPositiveInteger? value with
    | some key => pure ⟨key⟩
    | none => Validation.fail "session.expected_profile" }⟩

namespace Trusted
/-- Adapter boundary: wrap a hash produced by the runtime's KDF. -/
def passwordHash (encoded : String) : PasswordHash := ⟨encoded⟩
/-- Adapter boundary: the stored hash text, for verification by the runtime. -/
def passwordHashText (hash : PasswordHash) : String := hash.encoded
/-- Adapter boundary: the session the runtime started for `profile`. -/
def session (profile : Ref T) : Session := ⟨profile.key⟩
end Trusted

inductive Disclosure (α : Type) where
  | visible (value : α)
  | hidden
  deriving BEq, DecidableEq, Repr

def disclosureCodec (payload : Codec α) : Codec (Disclosure α) where
  schema := .variant [("visible", payload.schema), ("hidden", .unit)]
  encode
    | .visible value => JsonWire.tagged "visible" (payload.encode value)
    | .hidden => .str "hidden"
  decode value := do
    if let .str "hidden" := value then return .hidden
    let tag ← JsonWire.stringField "tag" value
    match tag with
    | "hidden" => do
      JsonWire.object ["tag", "value"] value
      let _ ← Codec.field "value" Codec.unit value
      pure .hidden
    | "visible" => do
      JsonWire.object ["tag", "value"] value
      .visible <$> Codec.field "value" payload value
    | _ => Validation.fail "decode.unknown_tag" [.key "tag"]

instance [Wire α] : Wire (Disclosure α) := ⟨disclosureCodec Wire.codec⟩
end LeanApp.Domain
