import LeanDb.Transaction

namespace LeanAppNative

/-- Application-owned state that outlives requests. Never contains a `Conn`. -/
structure AppState (σ : Type) where
  private ref : IO.Ref σ
  private generation : IO.Ref Nat
  private pending : IO.Ref (Array (IO Unit))
  private invalidateFn : σ → IO σ

def AppState.new (initial : IO σ) (onInvalidate : σ → IO σ := pure) : IO (AppState σ) := do
  return ⟨← IO.mkRef (← initial), ← IO.mkRef 0, ← IO.mkRef #[], onInvalidate⟩

def AppState.get (s : AppState σ) : IO σ := s.ref.get
def AppState.set (s : AppState σ) (v : σ) : IO Unit := s.ref.set v
def AppState.modify (s : AppState σ) (f : σ → σ) : IO Unit := s.ref.modify f
def AppState.modifyGet (s : AppState σ) (f : σ → α × σ) : IO α := s.ref.modifyGet f
def AppState.currentGeneration (s : AppState σ) : IO Nat := s.generation.get

/-- Replace memory derived from a previous database file. -/
def AppState.invalidate (s : AppState σ) : IO Unit := do
  s.generation.modify (· + 1)
  s.pending.set #[]
  s.ref.set (← s.invalidateFn (← s.ref.get))

/-- Queue `act` to run only if the enclosing `AppState.transaction` commits. -/
def AppState.afterCommit (s : AppState σ) (act : IO Unit) : LeanDb.DbM Unit :=
  LeanDb.untrackedSqlite fun _ => s.pending.modify (·.push act)

/-- `LeanDb.transaction` that flushes `afterCommit` hooks iff the body commits. -/
def AppState.transaction (s : AppState σ) (act : LeanDb.DbM (LeanDb.Tx ε α)) :
    LeanDb.DbM (Except ε α) := do
  match ← LeanDb.transaction act with
  | .ok v =>
    let hooks ← s.pending.modifyGet fun hs => (hs, #[])
    for hook in hooks do hook
    return .ok v
  | .error e =>
    s.pending.set #[]
    return .error e

end LeanAppNative
