#!/bin/sh
set -eu
cd "$(dirname "$0")/../.."
build_dir="$PWD/tests/runtime/lean-build"
mkdir -p "$build_dir"
# LeanReact core and the Tickets example domain; LeanOntology and LeanContract come from the
# required packages (leanontology, leanapi).
lake build LeanReact Examples.Tickets.Domain
export LEAN_PATH="$(lake env printenv LEAN_PATH)"
if ! lean tests/runtime/Probe.lean > "$build_dir/typechecks.log" 2>&1; then
  cat "$build_dir/typechecks.log"
  exit 1
fi
echo "LeanReact typechecks passed (generic APIs and 6 expected rejections)."
lean tests/runtime/Examples.lean
lean --run tests/runtime/Reference.lean
lean --run tests/runtime/Router.lean
lean --run tests/runtime/Forms.lean
lean --run tests/runtime/Resources.lean
if ! lean tests/runtime/P06Types.lean > "$build_dir/p06-typechecks.log" 2>&1; then
  cat "$build_dir/p06-typechecks.log"
  exit 1
fi
echo "P06 typechecks passed (generic APIs and 5 expected rejections)."
lean tests/runtime/P06Examples.lean
