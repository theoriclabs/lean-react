import LeanApi.Publication
def wrong [Monad m] (cap : LeanApi.Publication.ReadCapability m Option) : m Unit :=
  cap.liftIO (IO.println "not a read capability")
