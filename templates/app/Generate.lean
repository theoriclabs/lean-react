import LeanReact.Compiler
import {{Name}}.UI.App

/-! `lake env lean Generate.lean` compiles the screen and the shared title rule to
`web/generated/app.mjs` (plus `.d.ts` and a manifest). The adapter specifier is resolved by
esbuild's alias in `scripts/build.mjs`. -/
run_meta do
  IO.FS.createDirAll "web/generated"
  LeanJS.writeModule "web/generated/app.mjs" #[`{{Name}}.UI.App, `{{Name}}.Title.parse]
    (LeanReact.Compiler.options "@leanapp/engine/adapters/leanjs-react.mjs")
