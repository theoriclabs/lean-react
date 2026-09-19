#!/bin/sh
set -eu
cd "$(dirname "$0")/../.."
build_dir="$PWD/tests/runtime/lean-build"
mkdir -p "$build_dir/LeanReact" "$build_dir/LeanOntology" "$build_dir/LeanContract" "$build_dir/Examples/Tickets"
export LEAN_PATH="$build_dir${LEAN_PATH:+:$LEAN_PATH}"
lean -R engine -o "$build_dir/LeanOntology/Path.olean" engine/LeanOntology/Path.lean
lean -R engine -o "$build_dir/LeanOntology/Validation.olean" engine/LeanOntology/Validation.lean
lean -R engine -o "$build_dir/LeanOntology/Identity.olean" engine/LeanOntology/Identity.lean
lean -R engine -o "$build_dir/LeanOntology/Schema.olean" engine/LeanOntology/Schema.lean
lean -R engine -o "$build_dir/LeanOntology/Codec.olean" engine/LeanOntology/Codec.lean
lean -R engine -o "$build_dir/LeanOntology/Descriptor.olean" engine/LeanOntology/Descriptor.lean
lean -R engine -o "$build_dir/LeanOntology/Query.olean" engine/LeanOntology/Query.lean
lean -R engine -o "$build_dir/LeanOntology.olean" engine/LeanOntology.lean
# Resources carry the portable Contract.CallFailure, so the contract's operation identities are needed too.
lean -R engine -o "$build_dir/LeanContract/Operation.olean" engine/LeanContract/Operation.lean
lean -R engine -o "$build_dir/LeanContract/CallFailure.olean" engine/LeanContract/CallFailure.lean
# Channels (useChannel) and streams (useStream) depend on the contract's channel protocol.
lean -R engine -o "$build_dir/LeanContract/Transport.olean" engine/LeanContract/Transport.lean
lean -R engine -o "$build_dir/LeanContract/Channel.olean" engine/LeanContract/Channel.lean
lean -R examples/lean -o "$build_dir/Examples/Tickets/Domain.olean" examples/lean/Examples/Tickets/Domain.lean
lean -R engine -o "$build_dir/LeanReact/Core.olean" engine/LeanReact/Core.lean
lean -R engine -o "$build_dir/LeanReact/Cell.olean" engine/LeanReact/Cell.lean
lean -R engine -o "$build_dir/LeanReact/DOM.olean" engine/LeanReact/DOM.lean
lean -R engine -o "$build_dir/LeanReact/Reference.olean" engine/LeanReact/Reference.lean
lean -R engine -o "$build_dir/LeanReact/Forms.olean" engine/LeanReact/Forms.lean
lean -R engine -o "$build_dir/LeanReact/Resources.olean" engine/LeanReact/Resources.lean
lean -R engine -o "$build_dir/LeanReact/Handle.olean" engine/LeanReact/Handle.lean
lean -R engine -o "$build_dir/LeanReact/Router.olean" engine/LeanReact/Router.lean
lean -R engine -o "$build_dir/LeanReact/Channels.olean" engine/LeanReact/Channels.lean
lean -R engine -o "$build_dir/LeanReact/Streams.olean" engine/LeanReact/Streams.lean
lean -R engine -o "$build_dir/LeanReact.olean" engine/LeanReact.lean
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
