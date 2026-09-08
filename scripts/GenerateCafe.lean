import LeanJS
import Cafe

run_meta do
  IO.FS.createDirAll "examples/cafe/generated"
  LeanJS.writeModule "examples/cafe/generated/domain.mjs" #[`Cafe.preview]
