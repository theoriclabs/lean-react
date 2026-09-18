#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
app_build_dir="$(mktemp -d "$PWD/.lake/app-check.XXXXXX")"
lake build LeanApp
lake env lean -R tests/app -o "$app_build_dir/AclFixture.olean" tests/app/AclFixture.lean
export LEAN_PATH="$app_build_dir:$(lake env printenv LEAN_PATH)"
lean --run tests/app/Main.lean
for test in RejectInput RejectOutput RejectError RejectReadWrite RejectReadIO RejectContextJson RejectContextConstructor RejectContextUpdate RejectWeakenedRole; do
  if [[ "$test" == RejectWeakenedRole ]]; then
    if lean --run "tests/app/$test.lean" > "$app_build_dir/$test.log" 2>&1; then
      echo "FAIL: $test unexpectedly passed the ACL matrix" >&2
      exit 1
    fi
  elif lean "tests/app/$test.lean" > "$app_build_dir/$test.log" 2>&1; then
    echo "FAIL: $test unexpectedly typechecked" >&2
    exit 1
  fi
  case "$test" in
    RejectInput|RejectOutput|RejectError) expected='type mismatch|Type mismatch' ;;
    RejectReadWrite) expected='Invalid field.*write|invalid field.*write' ;;
    RejectReadIO) expected='Invalid field.*liftIO|invalid field.*liftIO' ;;
    RejectContextJson) expected='FromJson.*RequestContext' ;;
    RejectContextConstructor|RejectContextUpdate) expected='private|Invalid.*constructor|invalid.*constructor' ;;
    RejectWeakenedRole) expected='acl.matrix_failed' ;;
  esac
  if ! rg -q "$expected" "$app_build_dir/$test.log"; then
    cat "$app_build_dir/$test.log" >&2
    echo "FAIL: $test failed for an unexpected reason" >&2
    exit 1
  fi
  echo "PASS: expected rejection $test"
done
echo "Diagnostics: $app_build_dir"
