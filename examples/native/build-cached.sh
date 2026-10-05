#!/usr/bin/env bash
# Build the four native Tickets executables with Lake (LeanDB, LeanAPI and leanontology are
# path dependencies on the sibling checkouts; leanhttp/leanws are the adapter's pinned clones).
# The binaries are in examples/native/.lake/build/bin.
set -euo pipefail
native_dir="$(cd "$(dirname "$0")" && pwd)"
cd "$native_dir"
LEAN_NUM_THREADS="${LEAN_NUM_THREADS:-2}" lake build tickets_server tickets_protocol tickets_checks tickets_http_checks
echo "Built $native_dir/.lake/build/bin/{tickets_server,tickets_protocol,tickets_checks,tickets_http_checks}"
