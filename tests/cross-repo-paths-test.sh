#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"

assert_missing_root_fails() {
  local expected_status="$1"
  shift
  local output status
  set +e
  output="$(env -u TUNA_ROOT "$@" 2>&1)"
  status=$?
  set -e

  [[ "$status" -eq "$expected_status" ]] || {
    echo "Expected exit $expected_status without TUNA_ROOT, got $status" >&2
    echo "$output" >&2
    exit 1
  }
  [[ "$output" == *"TUNA_ROOT"* ]] || {
    echo "Expected TUNA_ROOT guidance, got: $output" >&2
    exit 1
  }
}

assert_missing_root_fails 64 "$ROOT/scripts/prepare-local-tunakit-package.sh"
assert_missing_root_fails 2 make -C "$ROOT" ext-local TARGET=MyMindExtension TUNA_ROOT=

if rg -q '\$ROOT/\.\./Tuna|TUNA_ROOT:-\$ROOT/\.\./Tuna' \
  "$ROOT/Makefile" "$ROOT/scripts/prepare-local-tunakit-package.sh" "$ROOT/scripts/ext-package.sh"
then
  echo "Cross-repository tooling still contains an implicit sibling Tuna path." >&2
  exit 1
fi

echo "Cross-repository path tests passed."
