namespace Ordering

inductive Currency where
  | usd | eur
  deriving Repr, BEq, DecidableEq

/-- Exact, nonnegative minor units. No implicit currency conversion or rounding. -/
structure Money (currency : Currency) where
  minor : Nat
  deriving Repr, BEq, DecidableEq

def Money.add (a b : Money c) : Money c := ⟨a.minor + b.minor⟩
def Money.scale (a : Money c) (quantity : Nat) : Money c := ⟨a.minor * quantity⟩

theorem Money.scale_one (a : Money c) : a.scale 1 = a := by
  cases a
  simp [Money.scale]

inductive StockError where
  | invalidCapacity | zeroQuantity | insufficientCapacity | insufficientReserved
  deriving Repr, BEq, DecidableEq

/-- Reconstruction and every update establish the bound; the constructor is private. -/
structure Stock where
  private mk ::
  capacity : Nat
  reserved : Nat
  fits : reserved ≤ capacity

def Stock.fromRaw (capacity reserved : Nat) : Except StockError Stock :=
  if h : reserved ≤ capacity then .ok ⟨capacity, reserved, h⟩
  else .error .invalidCapacity

def Stock.empty (capacity : Nat) : Stock := ⟨capacity, 0, Nat.zero_le _⟩

def Stock.reserve (stock : Stock) (quantity : Nat) : Except StockError Stock :=
  if quantity == 0 then .error .zeroQuantity
  else if h : stock.reserved + quantity ≤ stock.capacity then
    .ok ⟨stock.capacity, stock.reserved + quantity, h⟩
  else .error .insufficientCapacity

def Stock.release (stock : Stock) (quantity : Nat) : Except StockError Stock :=
  if quantity == 0 then .error .zeroQuantity
  else if quantity ≤ stock.reserved then
    .ok ⟨stock.capacity, stock.reserved - quantity,
      Nat.le_trans (Nat.sub_le _ _) stock.fits⟩
  else .error .insufficientReserved

theorem Stock.reserved_le_capacity (stock : Stock) : stock.reserved ≤ stock.capacity :=
  stock.fits

end Ordering
