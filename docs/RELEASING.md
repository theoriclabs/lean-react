# Releasing

LeanJS reads Lean's compiler IR, so every LeanReact release supports exactly one Lean minor version. The README's [Lean versions](../README.md#lean-versions) table maps each Lean version to its tags.

## A release for a Lean version

1. Move `lean-toolchain` to the new Lean release, update the pinned LeanOntology, LeanDB and LeanAPI revisions to ones built for it, and update the Lean version LeanJS stamps into generated modules (`engine/LeanJS/Compiler.lean`).
2. Bump `version` in `lakefile.toml` (a new minor version for a new Lean minor version) and add a row for it to the README's table.
3. `node scripts/check-versions.mjs` checks the three agree; `npm test` runs it.
4. Merge, then tag the merge commit and push the tag:

   ```sh
   git tag v0.3.0 origin/main
   git push origin v0.3.0
   ```

The [release workflow](../.github/workflows/release.yml) checks the tag matches `lakefile.toml`, builds and tests the tagged commit, and publishes a GitHub release that names the Lean version.

## Lean release candidates

[`lean-rc.yml`](../.github/workflows/lean-rc.yml) runs weekly (and on demand). It finds the newest `leanprover/lean4` release candidate; when that is newer than `lean-toolchain`, it builds against it and runs the compiler and runtime suites. A failure there is a heads-up for the next Lean version, not a broken `main`.
