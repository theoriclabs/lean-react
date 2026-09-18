import LeanApp.Application
import LeanDb.Runtime

namespace LeanAppNative
open LeanApp Ontology

/-- Connection-per-call interpreters (LA-07). A handler never sees a bare `Conn`
    except inside one of these closures. -/
structure Capabilities where
  withWriter : {α : Type} → (LeanDb.Conn → IO α) → IO (Except LeanDb.Runtime.AdmissionError α)
  withReader : {α : Type} → (LeanDb.Conn → IO α) → IO (Except LeanDb.Runtime.AdmissionError α)

/-- Preserve today's `Conn → Application` factories when the host passes `Capabilities`. -/
def Factory.ofConn (factory : LeanDb.Conn → Validation (Application IO))
    (_caps : Capabilities) (conn : LeanDb.Conn) : Validation (Application IO) :=
  factory conn

def Capabilities.ofService (service : LeanDb.Runtime.Service) : Capabilities where
  withWriter := service.withConnection
  withReader := service.withConnection

end LeanAppNative
