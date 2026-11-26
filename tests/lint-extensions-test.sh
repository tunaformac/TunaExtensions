#!/usr/bin/env bash
# scripts/lint-extensions: a clean fixture repo passes, each policy violation is reported with its
# rule ID, --changed-since lints only touched extensions and adds the diff-only checks (P12 single
# CHANGELOG section, P14), the allowlist suppresses findings, and warnings never fail the run.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/tuna-lint-extensions-test.XXXXXX")"
REPO="$SANDBOX/repo"
LINT="$ROOT/scripts/lint-extensions"
trap '/bin/rm -rf "$SANDBOX"' EXIT

fail() {
  echo "lint-extensions-test: $*" >&2
  [[ -f "$SANDBOX/out" ]] && cat "$SANDBOX/out" >&2
  exit 1
}

lint() {
  local status=0
  env -u GITHUB_ACTIONS "$LINT" --root "$REPO" --allowlist "$SANDBOX/allowlist" "$@" \
    >"$SANDBOX/out" 2>&1 || status=$?
  return "$status"
}

expect() {
  grep -qF -- "$1" "$SANDBOX/out" || fail "expected output to contain: $1"
}

refute() {
  ! grep -qF -- "$1" "$SANDBOX/out" || fail "expected output not to contain: $1"
}

git_repo() {
  git -C "$REPO" -c user.name=Test -c user.email=test@example.com "$@" >/dev/null
}

png() {
  python3 - "$1" "$2" <<'PY'
import struct, sys, zlib
size = int(sys.argv[2])
ihdr = struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0)
chunk = b"IHDR" + ihdr
with open(sys.argv[1], "wb") as fh:
    fh.write(b"\x89PNG\r\n\x1a\n" + struct.pack(">I", len(ihdr)) + chunk
             + struct.pack(">I", zlib.crc32(chunk)))
PY
}

# extension NAME SLUG BUNDLE_ID [--no-tests] [--unregistered]
extension() {
  local name="$1" slug="$2" bundle_id="$3" tests=1 register=1
  shift 3
  for flag in "$@"; do
    case "$flag" in
      --no-tests) tests=0 ;;
      --unregistered) register=0 ;;
    esac
  done
  local dir="$REPO/$name" project="$REPO/$name/$name.xcodeproj"
  mkdir -p "$project/xcshareddata/xcschemes"
  {
    echo '// !$*UTF8*$!'
    echo '{'
    echo '		A00000000000000000000001 /* '"$name"' */ = {'
    echo '			isa = PBXNativeTarget;'
    echo '			productType = "com.apple.product-type.framework";'
    echo '		};'
    if ((tests)); then
      echo '		A00000000000000000000002 /* '"$name"'Tests */ = {'
      echo '			isa = PBXNativeTarget;'
      echo '			productType = "com.apple.product-type.bundle.unit-test";'
      echo '		};'
    fi
    echo '				MACOSX_DEPLOYMENT_TARGET = 15.0;'
    echo "				PRODUCT_BUNDLE_IDENTIFIER = $bundle_id;"
    echo "				PRODUCT_BUNDLE_IDENTIFIER = com.brnbw.${name}Tests;"
    echo '}'
  } >"$project/project.pbxproj"
  local testable=""
  ((tests)) && testable='<TestableReference skipped="NO"><BuildableReference BlueprintIdentifier="A00000000000000000000002"/></TestableReference>'
  printf '<?xml version="1.0"?>\n<Scheme><TestAction><Testables>%s</Testables></TestAction></Scheme>\n' \
    "$testable" >"$project/xcshareddata/xcschemes/$name.xcscheme"
  python3 - "$dir/Info.plist" "$slug" <<'PY'
import plistlib, sys
with open(sys.argv[1], "wb") as fh:
    plistlib.dump({"CFBundleIdentifier": "$(PRODUCT_BUNDLE_IDENTIFIER)", "CFBundleName": sys.argv[2],
                   "CFBundleShortVersionString": "0.1",
                   "LSMinimumSystemVersion": "$(MACOSX_DEPLOYMENT_TARGET)"}, fh)
PY
  png "$dir/icon.png" 1024
  printf '# Changelog\n\n## 0.1\n\n- First release.\n' >"$dir/CHANGELOG.md"
  printf -- '---\nsupport_url: https://github.com/tunaformac/TunaExtensions/tree/main/%s\n---\nHello.\n' \
    "$name" >"$dir/STORE.md"
  cat >"$dir/$name.swift" <<'EOF'
import TunaKit
let endpoint = URL(string: "https://api.example.com")!
let callback = "http://127.0.0.1:8080/callback"
// Not code: http://example.com
EOF
  if ((register)); then
    perl -pi -e "s/^(EXTENSION_SCHEMES :=.*)\$/\$1 $name/" "$REPO/Makefile"
    printf '| %s | Does things |\n' "$name" >>"$REPO/README.md"
    printf '<FileRef location = "group:%s/%s.xcodeproj"></FileRef>\n' "$name" "$name" \
      >>"$REPO/TunaExtensions.xcworkspace/contents.xcworkspacedata"
  fi
}

# --- A clean repo passes -------------------------------------------------------------------------

mkdir -p "$REPO/TunaExtensions.xcworkspace" "$REPO/scripts" "$REPO/media/screenshots/good"
printf 'EXTENSION_SCHEMES :=\n\nbuild:\n\t@true\n' >"$REPO/Makefile"
printf '# Extensions\n\n| Extension | What it does |\n| --- | --- |\n' >"$REPO/README.md"
: >"$REPO/TunaExtensions.xcworkspace/contents.xcworkspacedata"
printf 'echo upload\n' >"$REPO/scripts/upload.sh"
: >"$SANDBOX/allowlist"
extension GoodExtension Good com.brnbw.tuna.plugins.good
png "$REPO/media/screenshots/good/1-main.png" 64
git -C "$REPO" init -q -b main
git_repo add -A
git_repo commit -qm base

lint || fail "a clean repo must pass"
expect "lint-extensions: all 1 extensions: 0 error(s), 0 warning(s)"

# --- Every violation is reported with its rule ID ------------------------------------------------

extension BadExtension Bad de.example.bad --no-tests --unregistered
B="$REPO/BadExtension"
printf 'MIT\n' >"$B/LICENSE"
printf 'Nothing.\n' >"$B/PRIVACY.md"
png "$B/icon.png" 512
python3 - "$B/Info.plist" <<'PY'
import plistlib, sys
with open(sys.argv[1], "rb") as fh:
    data = plistlib.load(fh)
data["LSMinimumSystemVersion"] = "15.0"
data["CFBundleShortVersionString"] = "0.3"
with open(sys.argv[1], "wb") as fh:
    plistlib.dump(data, fh)
PY
printf '# Changelog\n\n## 0.2\n\n- More.\n\n## 0.1\n\n- First.\n' >"$B/CHANGELOG.md"
cat >"$B/STORE.md" <<'EOF'
---
support_url: https://github.com/someone/bad
privacy_url: https://tunaformac.com/privacy
---
See https://github.com/someone/bad for more.
EOF
printf '# Bad\n\n![shot](https://raw.githubusercontent.com/someone/bad/main/shot.png)\n' >"$B/README.md"
cat >"$B/BadNetwork.swift" <<'EOF'
import Foundation
let insecure = URL(string: "http://api.example.com/v1")!
let loopbackHost = "127.0.0.1"
func dynamic(host: String) -> URL? { URL(string: "http://\(host)/path") }
let loopback = URL(string: "http://\(loopbackHost):9/callback")!
func send(_ request: inout URLRequest) async throws {
  request.setValue("Bearer token", forHTTPHeaderField: "Authorization")
  _ = try await URLSession.shared.data(for: request)
}
EOF
cat >"$B/BadStorage.swift" <<'EOF'
import TunaKit
let cache = RuntimeEnvironment.appSupportDirectory().appending(path: "Tuna/ExtensionData/Bad")
func confirm() { _ = NSAlert().runModal() }
let enrichment = AppActionEnrichment(preferredActions: ["copy"])
EOF
cat >"$B/BadExtension.swift" <<'EOF'
let declaration = [
  CatalogDeclaration(
    id: "bad.commands", type: BadCommandsCatalog.self, name: "Bad",
    initialGlobalScope: .all),
  CatalogDeclaration(
    id: "bad.items", type: BadItemsCatalog.self, name: "Bad Items",
    initialGlobalScope: .all),
]
final class BadCommandsCatalog: Catalog {
  func scan() { objects = [CommandItem(title: "Run")] }
}
final class BadItemsCatalog: Catalog {
  func scan() { objects = [TextItem(title: "Read")] }
}
EOF
cat >"$B/BadExtensionTests.swift" <<'EOF'
let defaults = UserDefaults(suiteName: "BadTests-\(UUID())")!
let fine = URL(string: "http://example.com/tests-may-use-anything")!
EOF
mkdir -p "$REPO/media/screenshots/bad/0.2" "$REPO/media/screenshots/not-an-extension"
png "$REPO/media/screenshots/bad/0.2/1-nested.png" 64
png "$REPO/media/screenshots/not-an-extension/1.png" 64
png "$REPO/media/screenshots/bad/2-main-dark.png" 64
png "$REPO/media/screenshots/bad/2-main-light.png" 64
mkdir -p "$REPO/media/screenshots/de.example.bad"  # the uploader finds it; the slug is "bad"
png "$REPO/media/screenshots/de.example.bad/1.png" 64
mkdir -p "$REPO/media/screenshots/tuna-bad"  # Bad's, by slug, but the uploader never finds it
png "$REPO/media/screenshots/tuna-bad/1.png" 64

lint && fail "violations must fail the run"
for finding in \
  "BadExtension: P1: the bundle ID is \`com.brnbw.tuna.plugins.<name>\` (is \`de.example.bad\`)" \
  "BadExtension: P1: the extension is registered in \`TunaExtensions.xcworkspace\` (no \`BadExtension/BadExtension.xcodeproj\` entry) [P1-workspace]" \
  "BadExtension: P1: the extension is registered in \`EXTENSION_SCHEMES\` in the \`Makefile\` (\`BadExtension\` is missing) [P1-makefile]" \
  "BadExtension: P1: the extension is registered in the README's extension table (no \`| BadExtension |\` row) [P1-readme]" \
  "BadExtension/LICENSE: P2: the repository LICENSE covers every extension" \
  "BadExtension/PRIVACY.md: P2: no per-extension \`PRIVACY.md\`" \
  "BadExtension/BadExtension.swift:2: P3: catalogs whose items do something when run declare \`initialGlobalScope: .none\`" \
  "BadExtension/BadStorage.swift:2: P5: regenerable caches go in TunaKit's" \
  "BadExtension/BadExtensionTests.swift:1: P5: tests don't write to the real user defaults" \
  "error: BadExtension/BadNetwork.swift:2: P6: HTTPS only, except literal loopback addresses and \`localhost\` (\`http://api.example.com\`)" \
  "warning: BadExtension/BadNetwork.swift:4: P6: HTTPS only" \
  "P6: credentials go only to the configured origin: refuse cross-origin and HTTPS-to-HTTP redirects" \
  "BadExtension/BadStorage.swift:3: P7: long work returns a background task" \
  "BadExtension/BadStorage.swift:4: P8: Enter on an app item opens the app" \
  "BadExtension: P11: every extension has an XCTest target in its scheme (none found)" \
  "BadExtension/icon.png: P12: \`icon.png\` is 1024×1024 (is 512×512)" \
  "BadExtension/Info.plist: P12: the minimum macOS comes from the deployment target" \
  "BadExtension/CHANGELOG.md: P12: CHANGELOG.md has no \`## 0.3\`" \
  "BadExtension/STORE.md:2: P12: \`STORE.md\` links point at the tunaformac repository or tunaformac.com, not a personal repository (\`support_url\`" \
  "BadExtension/STORE.md:5: P12: \`STORE.md\` links point at the tunaformac repository or tunaformac.com (body links to https://github.com/someone/bad)" \
  "BadExtension/README.md:3: P12: README media point at the tunaformac repository" \
  "media/screenshots/bad/0.2: P12: screenshots sit flat in media/screenshots/bad/ (the uploader ignores subfolders" \
  "media/screenshots/bad: P12: media/screenshots/bad/ has light and dark versions of 1 shot(s)" \
  "media/screenshots/de.example.bad: P12: store media sits at media/screenshots/de.example.bad; use the extension's slug: media/screenshots/bad/ [P12-media-slug]" \
  "media/screenshots/not-an-extension: P12: media/screenshots/not-an-extension belongs to no extension" \
  "media/screenshots/tuna-bad: P12: media/screenshots/tuna-bad is named so the uploader never finds it; store media uses the extension's slug: media/screenshots/bad/ [P12-screenshots-orphan]" \
  ; do
  expect "$finding"
done
refute "STORE.md:3"  # privacy_url on tunaformac.com is fine
refute "BadExtension.swift:5: P3"  # a read-only catalog may use .all
refute "BadNetwork.swift:5"  # interpolated constant that is loopback
refute "BadExtensionTests.swift:2"
refute "GoodExtension"
refute "P12-changelog-single"  # diff-only
refute "P14"

# --- --extension lints one folder ----------------------------------------------------------------

lint --extension GoodExtension || fail "--extension GoodExtension must pass"
expect "GoodExtension: 0 error(s), 0 warning(s)"
lint --extension Nope && fail "an unknown folder must fail"
expect "unknown extension folder"

# --- --changed-since: touched extensions only, plus P12 single section and P14 ------------------

printf 'echo de.example.bad\n' >>"$REPO/scripts/upload.sh"
# Bad's own registration lines are expected at admission, not P14.
perl -pi -e 's/^(EXTENSION_SCHEMES :=.*)$/$1 BadExtension/' "$REPO/Makefile"
printf '| BadExtension | Does bad things |\n' >>"$REPO/README.md"
printf '<FileRef location = "group:BadExtension/BadExtension.xcodeproj"></FileRef>\n' \
  >>"$REPO/TunaExtensions.xcworkspace/contents.xcworkspacedata"
png "$REPO/media/screenshots/good/2-other.png" 64  # another extension's media is P14
printf 'notes\n' >"$REPO/NOTES.md"
git_repo add -A
git_repo commit -qm "Add Bad"
printf 'more notes\n' >>"$REPO/NOTES.md"  # uncommitted work counts too

lint --changed-since main~1 --summary "$SANDBOX/summary.md" && fail "changed-since must fail"
expect "lint-extensions: changes since main~1: BadExtension:"
expect "BadExtension/CHANGELOG.md: P12: a new extension debuts with a single CHANGELOG.md section for the version it ships (found 0.2, 0.1)"
expect "warning: scripts/upload.sh: P14: scripts/upload.sh is outside the extension's folder"
expect "warning: scripts/upload.sh: P14: scripts/upload.sh adds lines naming de.example.bad"
expect "warning: NOTES.md: P14:"
expect "warning: media/screenshots/good/2-other.png: P14:"
expect "media/screenshots/not-an-extension: P12:"
for path in README.md Makefile TunaExtensions.xcworkspace media/screenshots/bad media/screenshots/de.example.bad \
  media/screenshots/tuna-bad/1.png \
  media/screenshots/not-an-extension/1.png; do
  refute "$path: P14"
  refute "$path/contents.xcworkspacedata: P14"
done
refute "[P1-makefile]"  # registered now
refute "[P1-readme]"
refute "[P1-workspace]"
refute "GoodExtension"
grep -qF '## Extension lint' "$SANDBOX/summary.md" || fail "summary heading missing"
grep -qF '**P14**' "$SANDBOX/summary.md" || fail "summary lacks warnings"

# An update: a second CHANGELOG section is fine, registration edits are P14, and a media-only
# change belongs to the media's extension.
git_repo checkout -q -- NOTES.md
printf '\n## 0.2\n\n- Next.\n' >>"$REPO/GoodExtension/CHANGELOG.md"
perl -pi -e 's/^\| GoodExtension \| Does things \|$/| GoodExtension | Does good things |/' "$REPO/README.md"
git_repo commit -qam "Update Good"
lint --changed-since HEAD~1 || fail "an update's warnings must not fail the run"
expect "changes since HEAD~1: GoodExtension: 0 error(s)"
expect "warning: README.md: P14:"
refute "P12-changelog-single"

png "$REPO/media/screenshots/good/3-more.png" 64
git_repo add -A
git_repo commit -qm "More Good screenshots"
lint --changed-since HEAD~1 || fail "a media-only update must pass"
expect "changes since HEAD~1: GoodExtension: 0 error(s), 0 warning(s)"

# A test target missing from the shared scheme fails through scripts/verify-test-scheme.sh.
SCHEME="$REPO/GoodExtension/GoodExtension.xcodeproj/xcshareddata/xcschemes/GoodExtension.xcscheme"
cp "$SCHEME" "$SANDBOX/scheme"
printf '<?xml version="1.0"?>\n<Scheme><TestAction><Testables/></TestAction></Scheme>\n' >"$SCHEME"
lint --extension GoodExtension && fail "a test target outside the scheme must fail"
expect "GoodExtension: P11: every extension has an XCTest target in its scheme (GoodExtensionTests; shared scheme does not cover every unit-test target: GoodExtension/GoodExtension.xcodeproj/xcshareddata/xcschemes/GoodExtension.xcscheme)"
cp "$SANDBOX/scheme" "$SCHEME"

# --- Allowlist: suppresses findings, warns about unused entries, warnings never fail ------------

/bin/rm -rf "$B" "$REPO/media/screenshots/bad" "$REPO/media/screenshots/de.example.bad" \
  "$REPO/media/screenshots/tuna-bad" \
  "$REPO/media/screenshots/not-an-extension"
perl -pi -e 's/ BadExtension//' "$REPO/Makefile"
png "$REPO/GoodExtension/icon.png" 512
printf 'let x = AppActionEnrichment(preferredActions: [])\n' >"$REPO/GoodExtension/Extra.swift"
cat >"$SANDBOX/allowlist" <<'EOF'
# comment
GoodExtension P12-icon Published at 512x512.
GoodExtension P2-license Stale entry.
EOF
lint || fail "allowlisted errors and warnings must not fail the run"
refute "P12-icon]"
expect "warning: GoodExtension/Extra.swift:1: P8:"
expect "P2: allowlist entry matches nothing; remove it [P2-license]"

printf 'GoodExtension P12-icon\n' >"$SANDBOX/allowlist"
lint && fail "an entry without a reason must be rejected"
expect "expected \`<Folder> <check-id> <reason>\`"

# --- The real repo is clean ----------------------------------------------------------------------

env -u GITHUB_ACTIONS "$LINT" >"$SANDBOX/out" 2>&1 || fail "the repo itself must lint without errors"

echo "lint-extensions test passed."
