#!/usr/bin/env bash
# The TunaKit floor check: a build that imports TunaKit symbols its declared minimum TunaKit lacks,
# or a minimum Tuna that ships an older TunaKit, fails packaging; a correct floor passes. Runs on
# fixture symbol lists in a warm cache, so it must never touch the network.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURES="$ROOT/tests/fixtures/tunakit-floor"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/tuna tunakit floor test.XXXXXX")"

cleanup() {
  /bin/rm -rf "$SANDBOX"
}

trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

fail() {
  echo "tunakit-floor-test: $*" >&2
  exit 1
}

cp -R "$FIXTURES/cache" "$SANDBOX/cache"
# Any download attempt fails loudly instead of reaching GitHub.
export TUNAKIT_REPO_URL="$SANDBOX/no-network"

check() {
  "$ROOT/scripts/check-tunakit-floor.py" --cache-dir "$SANDBOX/cache" \
    --tuna-versions "$FIXTURES/tuna-tunakit-versions.tsv" "$@" 2>&1
}

expect_pass() {
  local output
  output="$(check "$@")" || fail "expected pass for $*, got: $output"
  [[ "$output" == *"TunaKit floor OK"* ]] || fail "missing OK line for $*: $output"
}

expect_fail() {
  local expected="$1"
  shift
  local output
  if output="$(check "$@")"; then
    fail "expected failure for $*, got: $output"
  fi
  [[ "$output" == *"$expected"* ]] || fail "expected '$expected' for $*, got: $output"
}

# A build using only what TunaKit 1.21.0 exports passes at 1.21.0.
expect_pass --imports-file "$FIXTURES/imports-1.21.txt" --min-tuna 0.95 --min-tunakit 1.21.0

# A build using a 1.22.0 symbol passes at the right floor...
expect_pass --imports-file "$FIXTURES/imports-1.22.txt" --min-tuna 0.96 --min-tunakit 1.22.0

# ...and fails at 1.21.0, naming the symbol and the first TunaKit (and Tuna) that has it.
expect_fail 'missing from its minimum TunaKit 1.21.0' \
  --imports-file "$FIXTURES/imports-1.22.txt" --min-tuna 0.95 --min-tunakit 1.21.0
expect_fail '_$s7TunaKit28CatalogAsyncPreviewProvidingPAAE06cachesdE0Sbvg' \
  --imports-file "$FIXTURES/imports-1.22.txt" --min-tuna 0.95 --min-tunakit 1.21.0
expect_fail 'First TunaKit with them: 1.22.0 (Tuna 0.96)' \
  --imports-file "$FIXTURES/imports-1.22.txt" --min-tuna 0.95 --min-tunakit 1.21.0

# A symbol no known release exports asks for a raised minimum without guessing a version.
printf '%s\n' '_$s7TunaKit13NotYetShippedCMa' >"$SANDBOX/imports-unknown.txt"
expect_fail 'Raise the minimum TunaKit' \
  --imports-file "$SANDBOX/imports-unknown.txt" --min-tuna 0.96 --min-tunakit 1.22.0

# The minimum Tuna must ship the minimum TunaKit.
expect_fail 'Tuna 0.95 ships TunaKit 1.21.0, older than the declared minimum TunaKit 1.22.0: raise the minimum Tuna to 0.96' \
  --imports-file "$FIXTURES/imports-1.22.txt" --min-tuna 0.95 --min-tunakit 1.22.0
# A later Tuna inherits the newest TunaKit it is known to ship.
expect_pass --imports-file "$FIXTURES/imports-1.22.txt" --min-tuna 0.110 --min-tunakit 1.22.0
expect_fail 'No known Tuna ships TunaKit 1.23.0' \
  --imports-file "$FIXTURES/imports-1.22.txt" --min-tuna 0.200 --min-tunakit 1.23.0

# A cold cache with no reachable TunaKit repository reports why the check couldn't run.
expect_fail 'TunaKit floor check could not run' \
  --imports-file "$FIXTURES/imports-1.22.txt" --min-tuna 0.95 --min-tunakit 1.20.0

# --- A real Mach-O bundle -------------------------------------------------------------------------
# Link a tiny framework against a stand-in TunaKit so the dyld_info import parsing is exercised:
# strong imports from TunaKit count, weak ones and other libraries don't.

ARCH="$(uname -m)"
FRAMEWORKS="$SANDBOX/frameworks"
KIT="$FRAMEWORKS/TunaKit.framework/Versions/A"
EXT="$SANDBOX/Example.framework"
mkdir -p "$KIT" "$EXT/Resources"
printf 'void tk_old(void) {}\nvoid tk_new(void) {}\nvoid tk_optional(void) {}\n' >"$SANDBOX/kit.c"
clang -arch "$ARCH" -dynamiclib -o "$KIT/TunaKit" \
  -install_name @rpath/TunaKit.framework/Versions/A/TunaKit "$SANDBOX/kit.c"
ln -s A "$FRAMEWORKS/TunaKit.framework/Versions/Current"
ln -s Versions/Current/TunaKit "$FRAMEWORKS/TunaKit.framework/TunaKit"
cat >"$SANDBOX/ext.c" <<'EOF'
void tk_old(void);
void tk_new(void);
__attribute__((weak_import)) void tk_optional(void);
void run(void) { tk_old(); tk_new(); if (tk_optional) tk_optional(); }
EOF
clang -arch "$ARCH" -dynamiclib -o "$EXT/Example" -F "$FRAMEWORKS" -framework TunaKit "$SANDBOX/ext.c"
python3 - "$EXT/Resources/Info.plist" <<'PY'
import plistlib
import sys

with open(sys.argv[1], "wb") as fh:
    plistlib.dump({"CFBundleExecutable": "Example", "CFBundleIdentifier": "com.example"}, fh)
PY

mkdir -p "$SANDBOX/cache/1.21.0" "$SANDBOX/cache/1.22.0"
printf '%s\n' _tk_old >"$SANDBOX/cache/1.21.0/$ARCH.exports"
printf '%s\n' _tk_old _tk_new >"$SANDBOX/cache/1.22.0/$ARCH.exports"

expect_pass --bundle "$EXT" --min-tuna 0.96 --min-tunakit 1.22.0
expect_fail $'missing from its minimum TunaKit 1.21.0:\n  _tk_new\nFirst TunaKit with them: 1.22.0' \
  --bundle "$EXT" --min-tuna 0.95 --min-tunakit 1.21.0

echo "TunaKit floor tests passed."
