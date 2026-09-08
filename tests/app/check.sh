#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
app_build_dir="$(mktemp -d "$PWD/.lake/app-check.XXXXXX")"
lake build LeanApp
lake env lean --run tests/app/Main.lean
for test in RejectInput RejectOutput RejectError RejectReadWrite RejectReadIO RejectContextJson RejectContextConstructor RejectContextUpdate; do
  if lake env lean "tests/app/$test.lean" > "$app_build_dir/$test.log" 2>&1; then
    echo "FAIL: $test unexpectedly typechecked" >&2
    exit 1
  fi
  case "$test" in
    RejectInput|RejectOutput|RejectError) expected='type mismatch|Type mismatch' ;;
    RejectReadWrite) expected='Invalid field.*write|invalid field.*write' ;;
    RejectReadIO) expected='Invalid field.*liftIO|invalid field.*liftIO' ;;
    RejectContextJson) expected='FromJson.*RequestContext' ;;
    RejectContextConstructor|RejectContextUpdate) expected='private|Invalid.*constructor|invalid.*constructor' ;;
  esac
  if ! rg -q "$expected" "$app_build_dir/$test.log"; then
    cat "$app_build_dir/$test.log" >&2
    echo "FAIL: $test failed for an unexpected reason" >&2
    exit 1
  fi
  echo "PASS: expected rejection $test"
done
echo "Diagnostics: $app_build_dir"
