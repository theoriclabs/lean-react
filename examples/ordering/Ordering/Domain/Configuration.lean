import Ordering.Domain.Values

namespace Ordering

inductive Temperature where
  | hot | iced
  deriving Repr, BEq, DecidableEq
inductive Size where
  | small | regular | large
  deriving Repr, BEq, DecidableEq
inductive Milk where
  | whole | skim | oat | almond | soy
  deriving Repr, BEq, DecidableEq
inductive Shots where
  | single | double | triple
  deriving Repr, BEq, DecidableEq

structure Configuration where
  temperature : Temperature := .hot
  size : Size := .regular
  milk : Milk := .whole
  shots : Shots := .double
  decaf : Bool := false
  deriving Repr, BEq, DecidableEq

def Configuration.all : Array Configuration :=
  #[Temperature.hot, .iced].flatMap fun temperature =>
    #[Size.small, .regular, .large].flatMap fun size =>
      #[Milk.whole, .skim, .oat, .almond, .soy].flatMap fun milk =>
        #[Shots.single, .double, .triple].flatMap fun shots =>
          #[false, true].map fun decaf => { temperature, size, milk, shots, decaf }

def Configuration.admissible (c : Configuration) : Bool :=
  !(c.temperature == .iced && c.size == .small) && !(c.decaf && c.shots == .triple)

inductive ConfigurationError where
  | smallIced | decafTriple
  deriving Repr, BEq, DecidableEq

structure AdmissibleConfiguration where
  private mk ::
  value : Configuration
  valid : value.admissible = true

def Configuration.check (c : Configuration) : Except ConfigurationError AdmissibleConfiguration :=
  if h : c.admissible = true then .ok ⟨c, h⟩
  else if c.temperature == .iced && c.size == .small then .error .smallIced
  else .error .decafTriple

inductive Choice where
  | temperature (value : Temperature)
  | size (value : Size)
  | milk (value : Milk)
  | shots (value : Shots)
  | decaf (value : Bool)
  deriving Repr, BEq, DecidableEq

def Choice.matches : Choice → Configuration → Bool
  | .temperature v, c => c.temperature == v
  | .size v, c => c.size == v
  | .milk v, c => c.milk == v
  | .shots v, c => c.shots == v
  | .decaf v, c => c.decaf == v

abbrev Pattern := List Choice
def Pattern.matches (p : Pattern) (c : Configuration) : Bool := p.all (fun v => v.matches c)

end Ordering
