#!/usr/bin/env bash
# make test-extensions skips an extension whose deployment target is newer than the host macOS
# (TUNA_HOST_MACOS_VERSION fakes the host) instead of failing to run its tests.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/tuna-macos-skip-test.XXXXXX")"
trap '/bin/rm -rf "$SANDBOX"' EXIT

fail() {
  echo "macos-test-skip-test: $*" >&2
  exit 1
}

project() {
  local name="$1" target="$2"
  mkdir -p "$SANDBOX/$name/$name.xcodeproj"
  cat >"$SANDBOX/$name/$name.xcodeproj/project.pbxproj" <<EOF
			productType = "com.apple.product-type.bundle.unit-test";
				MACOSX_DEPLOYMENT_TARGET = 15.0;
				MACOSX_DEPLOYMENT_TARGET = $target;
EOF
}

needs() {
  TUNA_HOST_MACOS_VERSION="$1" "$ROOT/scripts/needs-newer-macos.sh" "$SANDBOX/$2/$2.xcodeproj/project.pbxproj"
}

project FutureExtension 26.0
project CurrentExtension 15.4

[[ "$(needs 15.7.1 FutureExtension)" == 26.0 ]] || fail "26.0 should be needed on macOS 15.7.1"
! needs 26.0 FutureExtension >/dev/null || fail "26.0 runs on macOS 26.0"
! needs 27.2.1 FutureExtension >/dev/null || fail "26.0 runs on macOS 27.2.1"
! needs 15.4 CurrentExtension >/dev/null || fail "15.4 runs on macOS 15.4"
needs 15.3.9 CurrentExtension >/dev/null || fail "15.4 should be needed on macOS 15.3.9"
needs 9.9 CurrentExtension >/dev/null || fail "versions compare numerically, not as text"

# Through make: the only extension needs a newer macOS, so nothing runs xcodebuild and it passes.
/bin/rm -rf "$SANDBOX/CurrentExtension"
ln -s "$ROOT/scripts" "$SANDBOX/scripts"
make --no-print-directory -f "$ROOT/Makefile" -C "$SANDBOX" test-extensions \
  TUNA_HOST_MACOS_VERSION=15.0 >"$SANDBOX/out" 2>&1 || { cat "$SANDBOX/out" >&2; fail "make failed"; }
grep -q '=== FutureExtension tests skipped: needs macOS 26.0 (host 15.0) ===' "$SANDBOX/out" \
  || { cat "$SANDBOX/out" >&2; fail "missing skip line"; }
grep -q 'skipped, needs newer macOS: FutureExtension' "$SANDBOX/out" \
  || { cat "$SANDBOX/out" >&2; fail "missing skip summary"; }

echo "macOS test skip test passed."
