#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
FIXTURES="$ROOT/tests/fixtures/local-tunakit"
REWRITER="$ROOT/scripts/rewrite-local-tunakit-references.py"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/tuna-local-rewrite-test.XXXXXX")"
PACKAGE_URL="file:///tmp/Local Packages/TunaKit"
REVISION="0123456789abcdef"

cleanup() {
  /bin/rm -rf "$SANDBOX"
}
trap cleanup EXIT

rewrite_fixture() {
  local project_fixture="$1"
  local resolved_fixture="$2"
  local expected_version="$3"
  local case_dir="$SANDBOX/${resolved_fixture%.resolved}"
  mkdir -p "$case_dir"
  cp "$FIXTURES/$project_fixture" "$case_dir/project.pbxproj"
  cp "$FIXTURES/$resolved_fixture" "$case_dir/Package.resolved"

  "$REWRITER" rewrite \
    --project "$case_dir/project.pbxproj" \
    --resolved "$case_dir/Package.resolved" \
    --package-url "$PACKAGE_URL" \
    --revision "$REVISION"

  [[ "$(rg -o -F "$PACKAGE_URL" "$case_dir/project.pbxproj" | wc -l | tr -d ' ')" == 1 ]]
  jq -e --arg location "$PACKAGE_URL" --arg revision "$REVISION" --arg version "$expected_version" '
    (.pins // .object.pins) as $pins
    | [$pins[] | select((.identity // .package) == (if .identity then "tunakit" else "TunaKit" end))][0]
    | (.location // .repositoryURL) == $location
      and .state.revision == $revision
      and .state.version == $version
  ' "$case_dir/Package.resolved" >/dev/null
}

assert_rewrite_fails_unchanged() {
  local label="$1"
  local expected="$2"
  local case_dir="$SANDBOX/$label"
  mkdir -p "$case_dir"
  cp "$FIXTURES/project-multiline.pbxproj" "$case_dir/project.pbxproj"
  cp "$FIXTURES/package-v3.resolved" "$case_dir/Package.resolved"
  shift 2
  "$@" "$case_dir"
  cp "$case_dir/project.pbxproj" "$case_dir/project.before"
  cp "$case_dir/Package.resolved" "$case_dir/resolved.before"
  if "$REWRITER" rewrite --project "$case_dir/project.pbxproj" \
    --resolved "$case_dir/Package.resolved" --package-url "${FAILING_PACKAGE_URL:-$PACKAGE_URL}" \
    --revision "$REVISION" >"$case_dir/stdout" 2>"$case_dir/stderr"
  then
    echo "Expected $label rewrite to fail." >&2
    exit 1
  fi
  rg -q "$expected" "$case_dir/stderr"
  cmp "$case_dir/project.before" "$case_dir/project.pbxproj"
  cmp "$case_dir/resolved.before" "$case_dir/Package.resolved"
}

no_project_reference() {
  perl -0pi -e 's@https://github.com/tunaformac/TunaKit@https://example.com/Unexpected@' "$1/project.pbxproj"
}

duplicate_project_reference() {
  perl -0pi -e 's@https://example.com/Other@https://github.com/tunaformac/TunaKit@' "$1/project.pbxproj"
}

malformed_project_reference() {
  perl -0pi -e 's@\n\t\t};\n\t};\n}\n$@\n@' "$1/project.pbxproj"
}

commented_project_reference() {
  cat >"$1/project.pbxproj" <<'EOF'
{
	objects = {
		AAAAAAAAAAAAAAAAAAAAAAAA = {
			isa = PBXGroup;
			/* isa = XCRemoteSwiftPackageReference; */
			repositoryURL = "https://github.com/tunaformac/TunaKit";
		};
	};
}
EOF
}

no_resolved_pin() {
  jq '(.pins[] | select(.identity == "tunakit")).identity = "unexpected"' \
    "$1/Package.resolved" >"$1/changed" && mv "$1/changed" "$1/Package.resolved"
}

duplicate_resolved_pin() {
  jq '.pins += [.pins[] | select(.identity == "tunakit")]' \
    "$1/Package.resolved" >"$1/changed" && mv "$1/changed" "$1/Package.resolved"
}

unexpected_resolved_location() {
  jq '(.pins[] | select(.identity == "tunakit")).location = "ssh://git@example.com/TunaKit"' \
    "$1/Package.resolved" >"$1/changed" && mv "$1/changed" "$1/Package.resolved"
}

unexpected_resolved_kind() {
  jq '(.pins[] | select(.identity == "tunakit")).kind = "localSourceControl"' \
    "$1/Package.resolved" >"$1/changed" && mv "$1/changed" "$1/Package.resolved"
}

unexpected_resolved_state() {
  jq '(.pins[] | select(.identity == "tunakit")).state = {revision: "branch-revision", branch: "main"}' \
    "$1/Package.resolved" >"$1/changed" && mv "$1/changed" "$1/Package.resolved"
}

invalid_semantic_version() {
  jq '(.pins[] | select(.identity == "tunakit")).state.version = "main"' \
    "$1/Package.resolved" >"$1/changed" && mv "$1/changed" "$1/Package.resolved"
}

conflicting_resolved_state() {
  jq '(.pins[] | select(.identity == "tunakit")).state.branch = "development"' \
    "$1/Package.resolved" >"$1/changed" && mv "$1/changed" "$1/Package.resolved"
}

unsupported_resolved_format() {
  jq '.version = 4' "$1/Package.resolved" >"$1/changed" && mv "$1/changed" "$1/Package.resolved"
}

unchanged() {
  :
}

malformed_resolved() {
  printf '{not json\n' >"$1/Package.resolved"
}

rewrite_fixture project-multiline.pbxproj package-v1.resolved 1.18.4
rewrite_fixture project-compact.pbxproj package-v2.resolved 1.21.3
rewrite_fixture project-multiline.pbxproj package-v3.resolved 1.22.0

versions="$($REWRITER versions "$FIXTURES/package-v1.resolved" "$FIXTURES/package-v2.resolved" "$FIXTURES/package-v3.resolved")"
[[ "$versions" == $'1.18.4\n1.21.3\n1.22.0' ]]

assert_rewrite_fails_unchanged no-project-reference 'exactly one TunaKit package reference, found 0' no_project_reference
assert_rewrite_fails_unchanged duplicate-project-reference 'exactly one TunaKit package reference, found 2' duplicate_project_reference
assert_rewrite_fails_unchanged malformed-project-reference 'unterminated object' malformed_project_reference
assert_rewrite_fails_unchanged commented-project-reference 'exactly one TunaKit package reference, found 0' commented_project_reference
assert_rewrite_fails_unchanged no-resolved-pin 'exactly one TunaKit resolved pin, found 0' no_resolved_pin
assert_rewrite_fails_unchanged duplicate-resolved-pin 'exactly one TunaKit resolved pin, found 2' duplicate_resolved_pin
assert_rewrite_fails_unchanged unexpected-location 'unexpected location' unexpected_resolved_location
assert_rewrite_fails_unchanged unexpected-kind 'unexpected kind' unexpected_resolved_kind
assert_rewrite_fails_unchanged unexpected-state 'semantic version state' unexpected_resolved_state
assert_rewrite_fails_unchanged invalid-version 'invalid semantic version' invalid_semantic_version
assert_rewrite_fails_unchanged conflicting-state 'both version and branch' conflicting_resolved_state
assert_rewrite_fails_unchanged unsupported-format 'unsupported Package.resolved version 4' unsupported_resolved_format
assert_rewrite_fails_unchanged malformed-resolved 'malformed Package.resolved' malformed_resolved

# A location whose SwiftPM identity differs from the "tunakit" pin makes one resolve fetch the same
# repository under two identities, racing into a single clone directory ("... already exists").
for url in "file:///tmp/local-tunakit-package" "/tmp/TunaKit-local" "file:///tmp/TunaKitX.git"; do
  FAILING_PACKAGE_URL="$url" \
    assert_rewrite_fails_unchanged "identity-$(basename "$url")" 'must end in TunaKit' unchanged
done
for url in "/tmp/TunaKit" "file:///tmp/TunaKit/" "file:///tmp/tunakit.git"; do
  PACKAGE_URL="$url" rewrite_fixture project-multiline.pbxproj package-v3.resolved 1.22.0
done

echo "Local TunaKit rewrite tests passed."
