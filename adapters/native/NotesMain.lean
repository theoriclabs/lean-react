import LeanAppNative.Notes

def main : IO UInt32 := do
  let path := (← IO.getEnv "LEANAPP_DB_PATH").getD "/data/notes.sqlite"
  let some port := ((← IO.getEnv "LEANAPP_BACKEND_PORT").getD "4191").toNat?
    | throw (IO.userError "invalid backend port")
  if port == 0 || port > 65535 then throw (IO.userError "invalid backend port")
  let development := (← IO.getEnv "LEANAPP_DEVELOPMENT") == some "1"
  let origin := (← IO.getEnv "LEANAPP_ORIGIN").getD ""
  let config := LeanDb.Instance.ofPath path
  let .ok session ← LeanDb.Cli.Session.open LeanAppNative.Notes.base config
    | throw (IO.userError "notes database unavailable")
  let runtime ← LeanDb.Runtime.Service.new LeanAppNative.Notes.base config session true
  try
    let .ok auth ← LeanAppNative.Auth.Service.new runtime | throw (IO.userError "authentication unavailable")
    let host ← LeanAppNative.Notes.host auth origin development
    Std.Async.Async.block do
      let server ← host.serve (.v4 ⟨Std.Net.IPv4Addr.ofParts 127 0 0 1, port.toUInt16⟩)
      server.waitShutdown
    return 0
  finally runtime.close
