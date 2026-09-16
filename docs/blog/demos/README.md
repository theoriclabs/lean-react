# LeanReact blog demos

These are standalone static pages for the introduction post. Each page runs compiled Lean components with React. No backend or external JavaScript service is required.

From the repository root, run `npm run build:blog` to rebuild the HTML, browser bundle, and `dist/` output. Edit the components in `examples/lean/Examples/Blog.lean`, the page styles in `examples/blog/style.css`, and the page templates in `scripts/build-blog.mjs`.

The counter, loading-state, and editor source panels come directly from the blog's code blocks. Keep those examples and the demo components in sync when changing behavior.

The HTML and `assets/` directory can be served from any static host, including a subdirectory. The Sites configuration selects `dist/`. Preserve its existing project ID when updating the hosted demos.
