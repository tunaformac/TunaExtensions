#!/usr/bin/env bash
# scripts/auto-release plan: which extensions CI may release on its own. Runs on the extension-risk
# fixtures with store versions from a file, so it never touches the network.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURES="$ROOT/tests/fixtures/extension-risk"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/tuna auto release test.XXXXXX")"
REPO="$SANDBOX/repo"

cleanup() {
  /bin/rm -rf "$SANDBOX"
}

trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

fail() {
  echo "auto-release-test: $*" >&2
  exit 1
}

g() {
  git -C "$REPO" -c user.name=Test -c user.email=test@example.com "$@"
}

commit_diff() {
  g apply --index "$FIXTURES/$1.diff"
  g commit -qm "$1"
}

bump_acme() {
  sed -i.bak "s#<string>0.1</string>#<string>$1</string>#" "$REPO/AcmeExtension/Info.plist"
  rm "$REPO/AcmeExtension/Info.plist.bak"
  g commit -qam "Bump Acme to $1"
}

store() {
  printf '%s\n' "$1" >"$SANDBOX/store.json"
}

# plan EXPECTED_RELEASE [EXPECTED_MANUAL_REASON]: plans the last commit as a push.
plan() {
  local expected_release="$1"
  local expected_reason="${2:-}"
  "$ROOT/scripts/auto-release" plan --repo "$REPO" --before HEAD~1 --head HEAD \
    --store-versions "$SANDBOX/store.json" --json-out "$SANDBOX/plan.json" \
    --github-output "$SANDBOX/github-output" >"$SANDBOX/summary.md"
  local release
  release="$(python3 -c 'import json,sys; print(" ".join(e["dir"] for e in json.load(open(sys.argv[1]))["release"]))' "$SANDBOX/plan.json")"
  [[ "$release" == "$expected_release" ]] \
    || fail "$(g log -1 --format=%s): released '$release', expected '$expected_release'"
  if [[ -n "$expected_reason" ]]; then
    grep -qF -- "$expected_reason" "$SANDBOX/summary.md" \
      || fail "$(g log -1 --format=%s): summary lacks '$expected_reason': $(cat "$SANDBOX/summary.md")"
  fi
  grep -qx "targets=$expected_release" "$SANDBOX/github-output" || fail "targets output is wrong"
  : >"$SANDBOX/github-output"
}

cp -R "$FIXTURES/base" "$REPO"
g init -q
g add -A
g commit -qm base
g tag -a extensions/com.brnbw.tuna.plugins.acme/v0.1 -m "Acme 0.1"
g tag -a extensions/com.brnbw.tuna.plugins.other/v1.0 -m "Other 1.0"
BASE="$(g rev-parse HEAD)"

# A clean update with a newer version is released; an equal or missing store version isn't.
commit_diff clean-update
store '{"com.brnbw.tuna.plugins.acme": "0.1", "com.brnbw.tuna.plugins.other": "1.0"}'
plan AcmeExtension
grep -q "Would release\|Releasing" "$SANDBOX/summary.md" || fail "summary doesn't list the release"
store '{"com.brnbw.tuna.plugins.acme": "0.2", "com.brnbw.tuna.plugins.other": "1.0"}'
plan ""
store '{"com.brnbw.tuna.plugins.acme": null, "com.brnbw.tuna.plugins.other": "1.0"}'
plan "" "admission: not in the store yet"
store '{"com.brnbw.tuna.plugins.acme": "0.3", "com.brnbw.tuna.plugins.other": "1.0"}'
plan ""

# A push that changes shared files releases nothing.
store '{"com.brnbw.tuna.plugins.acme": "0.1", "com.brnbw.tuna.plugins.other": "1.0"}'
printf '\ttrue\n' >>"$REPO/Makefile"
g commit -qam "Touch the Makefile"
plan "" "this push changed shared files (Makefile)"

# An extension changed together with something outside it, earlier on main, needs the maintainer.
g checkout -q -b mixed "$BASE"
printf 'More.\n' >>"$REPO/AcmeExtension/STORE.md"
printf 'More.\n' >>"$REPO/README.md"
g commit -qam "Acme listing and README together"
bump_acme 0.2
plan "" "also changed README.md"

# A risky change that wasn't released still blocks a later clean version bump.
g checkout -q -b cumulative "$BASE"
commit_diff apple-events
bump_acme 0.2
plan "" "new Apple Events target: Finder"

# A whole merged pull request counts as one change.
g checkout -q -b merged "$BASE"
g checkout -q -b topic
printf 'More.\n' >>"$REPO/AcmeExtension/STORE.md"
g commit -qam "Acme listing"
printf 'More.\n' >>"$REPO/README.md"
g commit -qam "README"
g checkout -q merged
g merge -q --no-ff topic -m "Merge topic"
bump_acme 0.2
plan "" "also changed README.md"

# An extension without an XCTest target always needs the maintainer.
g checkout -q -b untested "$BASE"
sed -i.bak "s#<string>1.0</string>#<string>1.1</string>#" "$REPO/OtherExtension/Info.plist"
rm "$REPO/OtherExtension/Info.plist.bak"
g commit -qam "Bump Other to 1.1"
store '{"com.brnbw.tuna.plugins.acme": "0.1", "com.brnbw.tuna.plugins.other": "1.0"}'
plan "" "no XCTest target (P11)"

# Without the published version's tag there is nothing to diff from.
g checkout -q -b untagged "$BASE"
bump_acme 0.2
store '{"com.brnbw.tuna.plugins.acme": "0.0.9", "com.brnbw.tuna.plugins.other": "1.0"}'
plan "" "no annotated release tag extensions/com.brnbw.tuna.plugins.acme/v0.0.9"

echo "Auto-release planning tests pass."
