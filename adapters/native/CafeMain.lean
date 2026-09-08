import LeanAppNative.Cafe

def main : IO UInt32 := do
  let path := (← IO.getEnv "LEANAPP_DB_PATH").getD "/data/cafe.sqlite"
  let portText := (← IO.getEnv "LEANAPP_BACKEND_PORT").getD "4181"
  let some port := portText.toNat? | throw (IO.userError "invalid backend port")
  if port == 0 || port > 65535 then throw (IO.userError "invalid backend port")
  let development := (← IO.getEnv "LEANAPP_DEVELOPMENT") == some "1"
  let origin := (← IO.getEnv "LEANAPP_ORIGIN").getD ""
  let instanceConfig := LeanDb.Instance.ofPath path
  let .ok session ← LeanDb.Cli.Session.open LeanAppNative.Cafe.base instanceConfig
    | throw (IO.userError "cafe database unavailable")
  let runtime ← LeanDb.Runtime.Service.new LeanAppNative.Cafe.base instanceConfig session true
  try
    let .ok auth ← LeanAppNative.Auth.Service.new runtime | throw (IO.userError "authentication unavailable")
    let host ← LeanAppNative.Cafe.host auth origin development
    Std.Async.Async.block do
      let server ← host.serve (.v4 ⟨Std.Net.IPv4Addr.ofParts 127 0 0 1, port.toUInt16⟩)
      server.waitShutdown
    return 0
  finally runtime.close
