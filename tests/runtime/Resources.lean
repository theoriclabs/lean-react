import LeanReact
open LeanReact

private def check (condition : Bool) (message : String) : IO Unit :=
  unless condition do throw <| IO.userError message

def main : IO Unit := do
  let key := Key.string "tickets"
  let initial : ResourceTracker Nat String := {}
  let (old, first) := initial.begin key
  let (new, second) := first.begin key
  let newest := second.settle new (.ok 2)
  check ((newest.settle old (.ok 1)).state == .success new 2) "stale response overwrote newer success"
  check ((second.settle old (.error (.loader "old error"))).state == .loading new) "stale failure overwrote loading"
  check ((second.cancel.settle new (.ok 2)).state == .idle) "cancelled response accepted"
  let wrong := { new with key := Key.string "another" }
  check ((second.settle wrong (.ok 3)).state == .loading new) "wrong request key accepted"
  check ((newest.settle new (.ok 3)).state == .success new 2) "request settled twice"

  let loads ← IO.mkRef (#[] : Array Nat)
  let releases ← IO.mkRef (#[] : Array Nat)
  let lastRequest ← IO.mkRef (none : Option ResourceRequest)
  let loader := fun request : ResourceRequest => Action.ofIO do
    loads.modify (·.push request.token.generation)
    lastRequest.set (some request)
    (request.onCleanup ⟨do
      check (← request.cancelled.runIO) "cleanup ran before cancellation"
      releases.modify (·.push request.token.generation)⟩).runIO
    pure (.ok request.token.generation : Except String Nat)
  let prepared ← Reference.runHook (useResource key loader #[] true "resource")
  check (prepared.trace == #[⟨"resource", "resource"⟩]) "resource hook trace"
  check ((← loads.get).isEmpty) "resource loaded during render"
  Reference.runAction prepared.value.refresh
  check ((← loads.get).isEmpty) "resource loaded before commit"
  let dispose ← prepared.commit
  check ((← loads.get) == #[1]) "commit did not load"
  check ((← prepared.value.read.runIO) == .success { key, generation := 1 } 1) "native resource result"
  Reference.runAction prepared.value.refresh
  check ((← loads.get) == #[1, 2] && (← releases.get) == #[1]) "refresh/cleanup generations"
  Reference.runAction dispose
  Reference.runAction dispose
  check ((← releases.get) == #[1, 2]) "unmount did not clean each generation once"
  check ((← prepared.value.read.runIO) == .idle) "unmount state not idle"
  Reference.runAction prepared.value.refresh
  check ((← loads.get) == #[1, 2]) "unmounted resource refreshed"
  let some last := ← lastRequest.get | throw <| IO.userError "request missing"
  (last.onCleanup ⟨releases.modify (·.push 99)⟩).runIO
  check ((← releases.get) == #[1, 2, 99]) "late cleanup registration leaked"

  let disabled ← Reference.runHook (useResource key loader #[] false)
  let stopDisabled ← disabled.commit
  Reference.runAction disabled.value.refresh
  check ((← loads.get) == #[1, 2]) "disabled resource loaded"
  Reference.runAction stopDisabled
  let failure ← Reference.runHook (useResource key (fun _ => pure (.error "domain" : Except String Nat)))
  let stopFailure ← failure.commit
  check ((← failure.value.read.runIO) == .failure { key, generation := 1 } (.loader "domain")) "typed loader failure lost"
  Reference.runAction stopFailure
  let broken ← Reference.runHook (useResource key (fun _ => (⟨throw <| IO.userError "host exception"⟩ : Action (Except String Nat))))
  let stopBroken ← broken.commit
  match ← broken.value.read.runIO with
  | .failure _ (.exception _) => pure ()
  | _ => throw <| IO.userError "host exception not represented"
  Reference.runAction stopBroken
  let requestRefresh ← IO.mkRef (Action.pure ())
  let generations ← IO.mkRef (#[] : Array Nat)
  let reentrant ← Reference.runHook (useResource key fun request => Action.ofIO do
    generations.modify (·.push request.token.generation)
    (request.onCleanup ⟨do (← requestRefresh.get).runIO⟩).runIO
    pure (.ok request.token.generation : Except String Nat))
  let stopReentrant ← reentrant.commit
  requestRefresh.set reentrant.value.refresh
  Reference.runAction reentrant.value.refresh
  check ((← generations.get) == #[1, 2]) "cleanup refresh lost newer request ownership"
  Reference.runAction stopReentrant
  check ((← generations.get) == #[1, 2]) "cleanup refresh reloaded after unmount"
  -- Transport failures are a closed portable type; `failureAs` collapses the three failure shapes into two.
  check (match Resource.failureAs (.loader "domain" : ResourceFailure String) with | .ok "domain" => true | _ => false) "failureAs keeps loader errors"
  check (match Resource.failureAs (.call .unauthenticated : ResourceFailure String) with | .error .unauthenticated => true | _ => false) "failureAs surfaces call failures"
  check (match Resource.failureAs (.exception "boom" : ResourceFailure String) with | .error (.transport "boom") => true | _ => false) "failureAs reports host exceptions as transport"
  check (Contract.CallFailure.code (.incompatible ⟨"ns", "list", "1"⟩ ⟨"ns", "list", "2"⟩) == "contract.incompatible" &&
    Contract.CallFailure.code (.decode "decode.nat") == "decode.nat" && Contract.CallFailure.kind .cancelled == "cancelled") "CallFailure codes"
  IO.println "P06 resource reference checks passed (generations, stale results, refresh, failures, lifecycle, late cleanup, call failures)."
