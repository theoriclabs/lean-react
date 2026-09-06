import LeanJS

namespace Corpus
structure Ticket where
  title : String
  priority : Nat
  approved : True

inductive Status where
  | waiting
  | active (owner : String) (weight : Nat)
  | done (count : Nat)

class Score (α : Type) where
  score : α → Nat

structure Service (α : Type) where
  fetch : Nat → α
  score : α → Nat
  adjust : Nat → Nat

def twice (f : α → α) (x : α) : α := f (f x)
def capture (base : Nat) : Nat → Nat := fun x => base + x * 2
def useCapture (base x : Nat) : Nat := twice (capture base) x

def runService (service : Service α) (key : Nat) : Nat :=
  service.adjust (service.score (service.fetch key))

def serviceA : Service Ticket :=
  { fetch := fun n => ⟨"ticket", n + 1, trivial⟩, score := Ticket.priority, adjust := fun n => n * 2 }
def serviceB (bias : Nat) : Service Nat :=
  { fetch := fun n => n * 3, score := fun n => n + bias, adjust := fun n => n - 1 }

def services (key : Nat) : Nat := runService serviceA key + runService (serviceB 7) key

def genericScore [Score α] (x : α) : Nat := Score.score x + 5
instance : Score Ticket := ⟨fun t => t.priority * 3⟩
def ticketScore (n : Nat) := genericScore (Ticket.mk "score" n trivial)

def updateTicket (t : Ticket) (delta : Nat) : Ticket := {t with priority := t.priority + delta}
def titleCheck (t : Ticket) : Option String :=
  if t.title.length > 4 then some (t.title ++ "!") else none

def statusScore : Status → Nat
  | .waiting => 0
  | .active owner weight => owner.length + weight
  | .done count => count * 10

def sum : List Nat → Nat
  | [] => 0
  | x :: xs => x + sum xs

def mapCaptured (bias : Nat) (xs : List Nat) : List Nat := xs.map (fun x => x + bias)
def fibonacci : Nat → Nat
  | 0 => 0
  | 1 => 1
  | n+2 => fibonacci n + fibonacci (n+1)

def countdown (n : Nat) : Nat :=
  if n = 0 then 0 else n + countdown (n-1)
termination_by n

def natural (a b : Nat) : Nat := (a * a + b) / 3 + a % (b+1) + (b-a)
def signed (a b : Int) : Int := (a * 3 - b) / b + a % b

def text (s : String) := s ++ ":" ++ toString s.length
def chars (s : String) := String.ofList s.toList.reverse

def arrayWork (xs : Array Nat) (bias : Nat) := (xs.map (fun x => x + bias)).push bias
def arrayFold (xs : Array Nat) (start stop : Nat) : Nat :=
  xs.foldl (fun acc x => acc * 10 + x) 7 start stop

def arrayFilter (xs : Array Nat) (minimum start stop : Nat) : Array Nat :=
  xs.filter (fun x => x > minimum) start stop

def arrayRead (xs : Array Nat) (i : Nat) := xs[i]?.getD 777
def arraySet (xs : Array Nat) (i x : Nat) := xs.set! i x

def scan [Monad m] (visit : Nat → m Nat) (xs : Array Nat) : m Nat := do
  let mut result := 0
  for x in xs do
    if x == 0 then break
    if x == 1 then continue
    result := result + (← visit x)
  return result

def scanId (visit : Nat → Nat) (xs : Array Nat) : Nat := scan (m := Id) visit xs
def scanExcept (xs : Array Nat) : Except String Nat :=
  scan (fun x => if x > 8 then .error s!"too big: {x}" else .ok (x * 2)) xs

def arrayFoldM (xs : Array Nat) (start stop : Nat) : Option Nat :=
  xs.foldlM (fun acc x => if x == 0 then none else some (acc * 10 + x)) 7 start stop

def arrayFind (visit : Nat → Bool) (xs : Array Nat) : Option Nat := xs.find? visit

def nativeReference (offset : Nat) (f : Nat → Nat) (x : Nat) := f x + offset
def viaIntrinsic (offset x : Nat) := nativeReference offset (fun y => y * 2) x

def genericProgram [Monad m] (fetch : Nat → m Nat) (adjust : Nat → m Nat) (key : Nat) : m Nat := do
  let a ← fetch key
  let b ← adjust a
  pure (b + 1)

def programId (key : Nat) : Nat :=
  genericProgram (m := Id) (fun x => x * 3) (fun x => x - 1) key

def programOption (key : Nat) : Option Nat :=
  genericProgram (fun x => if x > 5 then some (x * 3) else none) (fun x => some (x - 1)) key

def classifyText (a b : String) : Nat :=
  if a == b then 0 else if a < b then 1 else 2

def integerParts (i : Int) : Nat :=
  match i with
  | .ofNat n => n * 2
  | .negSucc n => n * 2 + 1

def nestedOption (x : Option (Option Nat)) : Nat :=
  match x with
  | none => 1
  | some none => 2
  | some (some n) => n + 3

def bindFirst (f : Nat → Nat → Nat) (x : Nat) : Nat → Nat := f x

def observation : String :=
  String.intercalate "|" [
    toString (natural 123456789012345678901234567890 17),
    toString (signed (-123456789012345678901234567890) 7),
    text "A😀é中", toString (useCapture 7 4), toString (services 8),
    toString (ticketScore 11), toString (statusScore (.active "😀a" 6)),
    toString (sum (mapCaptured 4 [1,2,3])), toString (fibonacci 12),
    toString (countdown 20)]

end Corpus
