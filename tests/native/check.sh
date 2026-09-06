#!/usr/bin/env bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$project_dir"
if [[ "${1:-}" != "--no-build" ]]; then bash examples/native/build-cached.sh; fi
binary_dir="$project_dir/examples/native/.lake/cached/bin"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/tickets-native-check.XXXXXX")"
"$binary_dir/tickets_checks" "$test_dir/native.sqlite"
"$binary_dir/tickets_checks" --init "$test_dir/protocol.sqlite"
lake env lean --run tests/Run.lean protocol "$binary_dir/tickets_protocol" "$test_dir/protocol.sqlite"
"$binary_dir/tickets_server" --manifest > "$test_dir/manifest.json"
echo "PASS offline native checks. Retained artifacts: $test_dir"
