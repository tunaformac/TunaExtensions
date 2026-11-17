#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/tuna local tooling test.XXXXXX")"
SANDBOX="$(cd "$SANDBOX" && pwd -P)"

cleanup() {
  /bin/rm -rf "$SANDBOX"
}

trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

fail() {
  echo "$*" >&2
  exit 1
}

assert_resolves_to() {
  local requested="$1"
  local expected="$2"
  local resolved
  resolved="$("$SANDBOX/resolver/scripts/resolve-extension-scheme.sh" "$requested")"
  [[ "${resolved##*$'\t'}" == "$expected" ]] ||
    fail "Expected $requested to resolve to $expected, got: $resolved"
}

# Exercise normalization against controlled scheme names. Exact schemes stay first-class, short
# extension names gain the conventional suffix, and GitHub retains its historical scheme mapping.
mkdir -p \
  "$SANDBOX/resolver/scripts" \
  "$SANDBOX/resolver/bin" \
  "$SANDBOX/resolver/GitHubExtension/GitHubExtension.xcodeproj" \
  "$SANDBOX/resolver/MyMindExtension/MyMindExtension.xcodeproj"
cp \
  "$ROOT/scripts/resolve-extension-scheme.sh" \
  "$ROOT/scripts/run-xcodebuild" \
  "$SANDBOX/resolver/scripts/"
printf '' >"$SANDBOX/resolver/GitHubExtension/GitHubExtension.xcodeproj/project.pbxproj"
printf '' >"$SANDBOX/resolver/MyMindExtension/MyMindExtension.xcodeproj/project.pbxproj"
cat >"$SANDBOX/resolver/bin/xcodebuild" <<'EOF'
#!/usr/bin/env bash
project=""
while [[ $# -gt 0 ]]; do
  if [[ "$1" == "-project" ]]; then project="$2"; break; fi
  shift
done
case "$project" in
  *GitHubExtension.xcodeproj) scheme=TunaGitHub ;;
  *MyMindExtension.xcodeproj) scheme=MyMindExtension ;;
  *) exit 1 ;;
esac
printf 'Schemes:\n    %s\n\n' "$scheme"
EOF
chmod +x "$SANDBOX/resolver/bin/xcodebuild" "$SANDBOX/resolver/scripts/"*

PATH="$SANDBOX/resolver/bin:$PATH"
export PATH
assert_resolves_to MyMind MyMindExtension
assert_resolves_to MyMindExtension MyMindExtension
assert_resolves_to GitHub TunaGitHub
assert_resolves_to GitHubExtension TunaGitHub
assert_resolves_to TunaGitHub TunaGitHub

# The subset coordinator must resolve every target before doing expensive preparation, prepare
# exactly once, and pass canonical schemes plus the requested configuration to each install.
mkdir -p "$SANDBOX/coordinator/scripts"
cp "$ROOT/scripts/install-local-extensions.sh" "$SANDBOX/coordinator/scripts/"
cat >"$SANDBOX/coordinator/scripts/resolve-extension-scheme.sh" <<'EOF'
#!/usr/bin/env bash
root="$(cd "$(dirname "$0")/.." && pwd)"
printf 'resolve %s\n' "$1" >>"$root/order.log"
case "$1" in
  MyMind) printf '%s/project with space/MyMind.xcodeproj\tMyMindExtension\n' "$root" ;;
  GitHub) printf '%s/project with space/GitHub.xcodeproj\tTunaGitHub\n' "$root" ;;
  *) exit 1 ;;
esac
EOF
cat >"$SANDBOX/coordinator/scripts/prepare-local-tunakit-package.sh" <<'EOF'
#!/usr/bin/env bash
root="$(cd "$(dirname "$0")/.." && pwd)"
printf 'prepare %s\n' "$1" >>"$root/order.log"
mkdir -p "$root/package"
printf '%s\n' "$root/package"
EOF
cat >"$SANDBOX/coordinator/scripts/install-local-extension-product.sh" <<'EOF'
#!/usr/bin/env bash
root="$(cd "$(dirname "$0")/.." && pwd)"
printf 'install %s %s %s %s %s\n' "$1" "$2" "$3" "$4" "$TUNA_LOCAL_TUNAKIT_PACKAGE" >>"$root/order.log"
EOF
chmod +x "$SANDBOX/coordinator/scripts/"*.sh

"$SANDBOX/coordinator/scripts/install-local-extensions.sh" \
  /tuna /install /derived Release MyMind GitHub
expected_order="$(cat <<EOF
resolve MyMind
resolve GitHub
prepare /tuna
install MyMindExtension /install /derived Release $SANDBOX/coordinator/package
install TunaGitHub /install /derived Release $SANDBOX/coordinator/package
EOF
)"
[[ "$(cat "$SANDBOX/coordinator/order.log")" == "$expected_order" ]] ||
  fail "Local subset preparation/install order was incorrect."

: >"$SANDBOX/coordinator/order.log"
if "$SANDBOX/coordinator/scripts/install-local-extensions.sh" \
  /tuna /install /derived Debug MyMind Unknown >/dev/null 2>&1
then
  fail "Local subset accepted an unknown target."
fi
[[ "$(cat "$SANDBOX/coordinator/order.log")" == $'resolve MyMind\nresolve Unknown' ]] ||
  fail "Local subset prepared TunaKit before validating every selected target."

# Package discovery is limited to top-level extension projects. A malformed lockfile in a nested
# worktree must not affect the checkout being prepared.
mkdir -p \
  "$SANDBOX/discovery/scripts/local-tunakit-package" \
  "$SANDBOX/discovery/bin" \
  "$SANDBOX/discovery/SourceExtension/Source.xcodeproj/project.xcworkspace/xcshareddata/swiftpm" \
  "$SANDBOX/discovery/.wt/worktrees/other/Bad.xcodeproj/project.xcworkspace/xcshareddata/swiftpm" \
  "$SANDBOX/discovery/tuna/app/TunaKit/TunaKit.xcodeproj"
cp \
  "$ROOT/scripts/prepare-local-tunakit-package.sh" \
  "$ROOT/scripts/rewrite-local-tunakit-references.py" \
  "$ROOT/scripts/run-xcodebuild" \
  "$SANDBOX/discovery/scripts/"
cp "$ROOT/scripts/local-tunakit-package/Package.swift" \
  "$SANDBOX/discovery/scripts/local-tunakit-package/Package.swift"
cp "$ROOT/tests/fixtures/local-tunakit/project-multiline.pbxproj" \
  "$SANDBOX/discovery/SourceExtension/Source.xcodeproj/project.pbxproj"
cp "$ROOT/tests/fixtures/local-tunakit/package-v3.resolved" \
  "$SANDBOX/discovery/SourceExtension/Source.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
printf '{not json\n' \
  >"$SANDBOX/discovery/.wt/worktrees/other/Bad.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
cat >"$SANDBOX/discovery/bin/xcodebuild" <<'EOF'
#!/usr/bin/env bash
derived_data=""
output=""
previous=""
for argument in "$@"; do
  case "$previous" in
    -derivedDataPath) derived_data="$argument" ;;
    -output) output="$argument" ;;
  esac
  previous="$argument"
done
if [[ "$1" == "build" ]]; then
  mkdir -p "$derived_data/Build/Products/Debug/TunaKit.framework"
elif [[ "$1" == "-create-xcframework" ]]; then
  mkdir -p "$output"
fi
EOF
cat >"$SANDBOX/discovery/bin/xcsift" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
EOF
chmod +x "$SANDBOX/discovery/scripts/"* "$SANDBOX/discovery/bin/"*
PATH="$SANDBOX/discovery/bin:$PATH" \
TUNA_XCODEBUILD_LOG_DIR="$SANDBOX/discovery/logs" \
  "$SANDBOX/discovery/scripts/prepare-local-tunakit-package.sh" \
    "$SANDBOX/discovery/tuna" >/dev/null
[[ -d "$SANDBOX/discovery/build/local-tunakit/TunaKit/TunaKit.xcframework" ]] ||
  fail "Local TunaKit preparation did not produce a package."

# A local Release build must explicitly remain on the active architecture because its generated
# TunaKit xcframework has only that architecture.
mkdir -p \
  "$SANDBOX/build/scripts" \
  "$SANDBOX/build/bin" \
  "$SANDBOX/build/SourceExtension/Source.xcodeproj" \
  "$SANDBOX/build/SourceExtension/Source.xcodeproj/project.xcworkspace/xcshareddata/swiftpm" \
  "$SANDBOX/build/ChromiumExtensionSupport/Sources" \
  "$SANDBOX/build/local-package/TunaKit/TunaKit.xcframework"
cp \
  "$ROOT/scripts/build-extension-product.sh" \
  "$ROOT/scripts/build-local-extension-product.sh" \
  "$ROOT/scripts/extension-shared-package.sh" \
  "$ROOT/scripts/rewrite-local-tunakit-references.py" \
  "$ROOT/scripts/run-xcodebuild" \
  "$SANDBOX/build/scripts/"
cat >"$SANDBOX/build/scripts/resolve-extension-scheme.sh" <<EOF
#!/usr/bin/env bash
printf '%s\t%s\n' '$SANDBOX/build/SourceExtension/Source.xcodeproj' SourceExtension
EOF
cp "$ROOT/tests/fixtures/local-tunakit/project-multiline.pbxproj" \
  "$SANDBOX/build/SourceExtension/Source.xcodeproj/project.pbxproj"
cp "$ROOT/tests/fixtures/local-tunakit/package-v3.resolved" \
  "$SANDBOX/build/SourceExtension/Source.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
printf '// shared package\n' >"$SANDBOX/build/ChromiumExtensionSupport/Package.swift"
printf '// shared source\n' >"$SANDBOX/build/ChromiumExtensionSupport/Sources/Browser.swift"
python3 - "$SANDBOX/build/SourceExtension/Source.xcodeproj/project.pbxproj" <<'PY'
from pathlib import Path
import sys

project = Path(sys.argv[1])
project.write_text(project.read_text().replace("objects = {", '''objects = {
    /* isa = XCLocalSwiftPackageReference; relativePath = ../ChromiumExtensionSupport; */
    FILE = { isa = PBXFileReference; relativePath = "../ChromiumExtensionSupport"; };
    LOCAL = { isa = XCLocalSwiftPackageReference; relativePath = ../Other; };
'''))
PY
cat >"$SANDBOX/build/bin/xcodebuild" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$XCODEBUILD_LOG"
configuration=Debug
derived_data=""
project=""
show_settings=false
previous=""
for argument in "$@"; do
  case "$previous" in
    -project) project="$argument" ;;
    -configuration) configuration="$argument" ;;
    -derivedDataPath) derived_data="$argument" ;;
  esac
  [[ "$argument" == "-showBuildSettings" ]] && show_settings=true
  previous="$argument"
done
if [[ -n "${EXPECT_SHARED_PACKAGE:-}" ]]; then
  shared_package="$(dirname "$(dirname "$project")")/ChromiumExtensionSupport"
  if [[ "$EXPECT_SHARED_PACKAGE" == "1" ]]; then
    [[ "$shared_package" != "$SHARED_PACKAGE_SOURCE" ]]
    cmp "$SHARED_PACKAGE_SOURCE/Package.swift" "$shared_package/Package.swift"
    cmp "$SHARED_PACKAGE_SOURCE/Sources/Browser.swift" "$shared_package/Sources/Browser.swift"
  else
    [[ ! -e "$shared_package" ]]
  fi
  printf '%s\n' "$project" >"$LOCAL_PROJECT_PATH_FILE"
fi
if [[ "$1" == "build" ]]; then
  mkdir -p "$derived_data/Build/Products/$configuration/Fake.appex"
fi
if [[ "$show_settings" == true ]]; then
  printf '    TARGET_BUILD_DIR = %s/Build/Products/%s\n' "$derived_data" "$configuration"
  printf '    FULL_PRODUCT_NAME = Fake.appex\n'
fi
exit 0
EOF
cat >"$SANDBOX/build/bin/xcsift" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
EOF
chmod +x "$SANDBOX/build/scripts/"* "$SANDBOX/build/bin/"*
git -C "$SANDBOX/build/local-package/TunaKit" init -q
git -C "$SANDBOX/build/local-package/TunaKit" config user.name Test
git -C "$SANDBOX/build/local-package/TunaKit" config user.email test@example.com
printf '// package\n' >"$SANDBOX/build/local-package/TunaKit/Package.swift"
git -C "$SANDBOX/build/local-package/TunaKit" add .
git -C "$SANDBOX/build/local-package/TunaKit" commit -qm initial
git -C "$SANDBOX/build/local-package/TunaKit" tag 1.22.0

PATH="$SANDBOX/build/bin:$PATH" \
XCODEBUILD_LOG="$SANDBOX/build/xcodebuild.log" \
EXPECT_SHARED_PACKAGE=0 \
LOCAL_PROJECT_PATH_FILE="$SANDBOX/build/local-project-path" \
TUNA_LOCAL_TUNAKIT_PACKAGE="$SANDBOX/build/local-package/TunaKit" \
  "$SANDBOX/build/scripts/build-local-extension-product.sh" \
    Source Release "platform=macOS,arch=$(uname -m)" "$SANDBOX/build/derived" >/dev/null
rg -q '^build .* -configuration Release .* ONLY_ACTIVE_ARCH=YES$' "$SANDBOX/build/xcodebuild.log" ||
  fail "Local Release build did not set ONLY_ACTIVE_ARCH=YES."
# Every rebuild of the local package re-tags the same versions at new revisions, so SwiftPM's
# per-user fingerprints must not block resolution or building.
for invocation in '^-resolvePackageDependencies ' '^build ' ' -showBuildSettings$'; do
  rg -- "$invocation" "$SANDBOX/build/xcodebuild.log" | rg -q -- '-packageFingerprintPolicy warn' ||
    fail "Local xcodebuild matching '$invocation' did not relax package fingerprint checking."
done

# Both quoted and unquoted project-local package paths must survive the isolated build.
for package_path in '../ChromiumExtensionSupport' '"../ChromiumExtensionSupport"'; do
  python3 - "$SANDBOX/build/SourceExtension/Source.xcodeproj/project.pbxproj" "$package_path" <<'PY'
from pathlib import Path
import re
import sys

project = Path(sys.argv[1])
project.write_text(re.sub(
    r'(LOCAL = \{ isa = XCLocalSwiftPackageReference; relativePath = )[^;]+',
    lambda match: match[1] + sys.argv[2],
    project.read_text(),
))
PY
  cp "$SANDBOX/build/SourceExtension/Source.xcodeproj/project.pbxproj" "$SANDBOX/build/original.pbxproj"
  PATH="$SANDBOX/build/bin:$PATH" \
  XCODEBUILD_LOG="$SANDBOX/build/xcodebuild.log" \
  EXPECT_SHARED_PACKAGE=1 \
  SHARED_PACKAGE_SOURCE="$SANDBOX/build/ChromiumExtensionSupport" \
  LOCAL_PROJECT_PATH_FILE="$SANDBOX/build/local-project-path" \
  TUNA_LOCAL_TUNAKIT_PACKAGE="$SANDBOX/build/local-package/TunaKit" \
    /bin/bash "$SANDBOX/build/scripts/build-local-extension-product.sh" \
      Source Release "platform=macOS,arch=$(uname -m)" "$SANDBOX/build/derived" >/dev/null
  cmp "$SANDBOX/build/original.pbxproj" "$SANDBOX/build/SourceExtension/Source.xcodeproj/project.pbxproj" ||
    fail "Local build modified the source project."
  temporary_project="$(cat "$SANDBOX/build/local-project-path")"
  [[ ! -e "$(dirname "$(dirname "$temporary_project")")" ]] ||
    fail "Local build did not clean up its temporary root."
done

# Exercise the normal Release path under macOS's Bash 3.2 with no optional signing settings. This
# also verifies tab-delimited resolver output when the project path contains spaces.
PATH="$SANDBOX/build/bin:$PATH" \
XCODEBUILD_LOG="$SANDBOX/build/xcodebuild.log" \
  /bin/bash "$SANDBOX/build/scripts/build-extension-product.sh" \
    Source Release "generic/platform=macOS" "$SANDBOX/build/release-derived" >/dev/null
rg -Fq "build -project $SANDBOX/build/SourceExtension/Source.xcodeproj -scheme SourceExtension -configuration Release" \
  "$SANDBOX/build/xcodebuild.log" ||
  fail "Normal Release build did not preserve the resolver's project path."

# Extensions pin different TunaKit versions, so each scheme defaults to its own derived data;
# TUNA_EXTENSION_DERIVED_DATA moves the parent folder.
cp "$ROOT/scripts/tuna-extension" "$SANDBOX/build/scripts/"
PATH="$SANDBOX/build/bin:$PATH" \
XCODEBUILD_LOG="$SANDBOX/build/xcodebuild.log" \
  "$SANDBOX/build/scripts/tuna-extension" build --scheme Source --release >/dev/null
rg -Fq -- "-derivedDataPath $SANDBOX/build/build/dd/SourceExtension" "$SANDBOX/build/xcodebuild.log" ||
  fail "Default build did not use a per-scheme derived data folder."
PATH="$SANDBOX/build/bin:$PATH" \
XCODEBUILD_LOG="$SANDBOX/build/xcodebuild.log" \
TUNA_EXTENSION_DERIVED_DATA="$SANDBOX/build/custom-dd" \
  "$SANDBOX/build/scripts/tuna-extension" build --scheme Source --release >/dev/null
rg -Fq -- "-derivedDataPath $SANDBOX/build/custom-dd/SourceExtension" "$SANDBOX/build/xcodebuild.log" ||
  fail "TUNA_EXTENSION_DERIVED_DATA did not move the per-scheme derived data folder."

echo "Local extension tooling tests pass."
