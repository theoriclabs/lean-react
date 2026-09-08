import LeanApp
def wrong [Monad m] (cap : LeanApp.ReadCapability m Option) : m Unit :=
  cap.liftIO (IO.println "not a read capability")
