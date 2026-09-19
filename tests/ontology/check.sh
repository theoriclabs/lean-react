#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/../.."
ontology_build_dir="$(mktemp -d "${TMPDIR:-/tmp}/leanreact-ontology.XXXXXX")"
export LEAN_PATH="$ontology_build_dir${LEAN_PATH:+:$LEAN_PATH}"
mkdir -p "$ontology_build_dir/LeanOntology" "$ontology_build_dir/LeanContract" "$ontology_build_dir/tests/ontology"

lean --version
for module in \
  LeanOntology/Path LeanOntology/Validation LeanOntology/Identity LeanOntology/Schema \
  LeanOntology/Codec LeanOntology/Descriptor LeanOntology/Query LeanOntology \
  LeanContract/Operation LeanContract/Transport LeanContract/CallFailure LeanContract/Channel LeanContract tests/ontology/Fixtures; do
  if [[ "$module" == tests/* ]]; then source_dir="."; else source_dir="engine"; fi
  lean -R "$source_dir" -o "$ontology_build_dir/$module.olean" "$source_dir/$module.lean"
done

lean --run tests/ontology/Main.lean

for module in RejectReference RejectPath RejectFieldValue RejectOperationKind \
  RejectOperationInput RejectOperationOutput RejectOperationError; do
  if lean "tests/ontology/$module.lean" > "$ontology_build_dir/$module.log" 2>&1; then
    echo "FAIL: $module unexpectedly typechecked" >&2
    exit 1
  fi
  if ! rg -q 'type mismatch|Type mismatch' "$ontology_build_dir/$module.log"; then
    cat "$ontology_build_dir/$module.log" >&2
    echo "FAIL: $module failed for an unexpected reason" >&2
    exit 1
  fi
  echo "PASS expected type rejection: $module"
done

echo "Build artifacts and rejection diagnostics: $ontology_build_dir"
