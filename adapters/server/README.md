# LeanReact server adapter

Import `LeanReactServer` from a native application to serve its LeanReact
`App` through LeanAPI. The adapter registers HTML pages and browser assets
alongside the typed API routes. LeanAPI still owns authentication, storage,
migrations, and the HTTP server.

The browser entry is `browser/App.mjs`. In the application’s bundle directory,
stage it beside `domain.mjs`, `operations.mjs`, and `pages.json`. Run the
application with `LEANAPP_EMIT_CLIENT` set to that directory to generate the
route client and page metadata, then bundle the entry with esbuild. The
adapter serves `app.mjs` from the application’s bundle directory or the
directory set by `LEANREACT_BROWSER_DIR`.

The adapter is a separate Lake library. The LeanReact UI and LeanJS libraries
can build and run without importing it.
