import LeanApp.Domain.Scalars

namespace LeanReact.Domain.DateInput
open LeanApp.Domain

private def pad (width value : Nat) : String :=
  let text := toString value
  String.ofList (List.replicate (width - text.length) '0') ++ text

private def leap (year : Nat) : Bool := year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
private def monthLength (year month : Nat) : Nat :=
  if month == 2 then if leap year then 29 else 28
  else if [4, 6, 9, 11].contains month then 30 else 31

/-- Gregorian civil date to exact epoch day, using floor division for pre-epoch years. -/
private def dayNumber (year month day : Nat) : Int :=
  let y := (year : Int) - if month ≤ 2 then 1 else 0
  let era := y / 400
  let yoe := y - era * 400
  let m := (month : Int) + if month > 2 then -3 else 9
  let doy := (153 * m + 2) / 5 + (day : Int) - 1
  era * 146097 + yoe * 365 + yoe / 4 - yoe / 100 + doy - 719468

private def split (separator : Char) (raw : String) : List String :=
  let (parts, last) := raw.toList.foldl (fun (state : List String × List Char) c =>
    if c == separator then (state.1 ++ [String.ofList state.2.reverse], [])
    else (state.1, c :: state.2)) ([], [])
  parts ++ [String.ofList last.reverse]

/-- UTC datetime-local editor text. Invalid text remains unchanged for the checked scalar codec. -/
def epochDraft (raw : String) : String :=
  if raw.length != 16 && raw.length != 19 && (raw.length < 21 || raw.length > 23) then raw else
  let parsed : Option Int := do
    let dateAndTime := split 'T' raw
    let [date, time] := dateAndTime | none
    let [year, month, day] := split '-' date | none
    let clock := split ':' time
    let [hour, minute, second] := if clock.length == 2 then clock ++ ["00"] else clock | none
    let second ← match split '.' second with
      | [whole] => some whole
      | [whole, fraction] => if !fraction.isEmpty && fraction.toList.all (fun c => c == '0') then some whole else none
      | _ => none
    if year.length != 4 || month.length != 2 || day.length != 2 || hour.length != 2 || minute.length != 2 || second.length != 2 then none else do
      let y ← Ontology.JsonWire.decimalDigits? year.toList
      let m ← Ontology.JsonWire.decimalDigits? month.toList
      let d ← Ontology.JsonWire.decimalDigits? day.toList
      let h ← Ontology.JsonWire.decimalDigits? hour.toList
      let n ← Ontology.JsonWire.decimalDigits? minute.toList
      let s ← Ontology.JsonWire.decimalDigits? second.toList
      if y < 1 || m < 1 || m > 12 || d < 1 || d > monthLength y m || h > 23 || n > 59 || s > 59 then none
      else some (dayNumber y m d * 86400 + (h : Int) * 3600 + (n : Int) * 60 + (s : Int))
  parsed.map toString |>.getD raw

/-- Exact Gregorian UTC display; even signed-64-bit endpoints never pass through a JS Number. -/
def formatEpoch (seconds : Int) : String :=
  let days := seconds / 86400
  let z := days + 719468
  let era := z / 146097
  let doe := z - era * 146097
  let yoe := (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
  let y := yoe + era * 400
  let doy := doe - (365 * yoe + yoe / 4 - yoe / 100)
  let mp := (5 * doy + 2) / 153
  let d := doy - (153 * mp + 2) / 5 + 1
  let m := mp + if mp < 10 then 3 else -9
  let year := y + if m ≤ 2 then 1 else 0
  let time := seconds % 86400
  let yearText := if year < 0 then "-" ++ pad 4 year.natAbs else pad 4 year.toNat
  yearText ++ "-" ++ pad 2 m.toNat ++ "-" ++ pad 2 d.toNat ++ "T" ++
    pad 2 (time / 3600).toNat ++ ":" ++ pad 2 ((time % 3600) / 60).toNat ++ ":" ++ pad 2 (time % 60).toNat

def editorText (raw : String) : String :=
  match Instant.parse raw with | .ok value => formatEpoch value.value | .error _ => raw

end LeanReact.Domain.DateInput
