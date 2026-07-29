#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET="${1:-}"
CONFIGURATION="${2:-Debug}"
DESTINATION="${3:-platform=macOS,arch=$(uname -m)}"
DERIVED_DATA="${4:-$ROOT/build/dd-local}"
LOCAL_PACKAGE="${TUNA_LOCAL_TUNAKIT_PACKAGE:-}"

if [[ -z "$TARGET" || -z "$LOCAL_PACKAGE" ]]; then
  echo "Usage: TUNA_LOCAL_TUNAKIT_PACKAGE=<path> $0 TARGET [CONFIGURATION] [DESTINATION] [DERIVED_DATA]" >&2
  exit 64
fi
if [[ ! -d "$LOCAL_PACKAGE/.git" || ! -d "$LOCAL_PACKAGE/TunaKit.xcframework" ]]; then
  echo "Prepared local TunaKit package not found at $LOCAL_PACKAGE" >&2
  exit 64
fi
mkdir -p "$DERIVED_DATA"
DERIVED_DATA="$(cd "$DERIVED_DATA" && pwd)"

read -r source_project resolved_target < <("$ROOT/scripts/resolve-extension-scheme.sh" "$TARGET")
source_directory="$(dirname "$source_project")"
temporary_directory="$(mktemp -d "${TMPDIR:-/tmp}/tuna-local-extension.XXXXXX")"
cleanup() {
  rm -rf "$temporary_directory"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

temporary_source="$temporary_directory/$(basename "$source_directory")"
ditto "$source_directory" "$temporary_source"
package_url="file://$LOCAL_PACKAGE"
local_revision="$(git -C "$LOCAL_PACKAGE" rev-parse HEAD)"
local_version="$(git -C "$LOCAL_PACKAGE" tag --sort=-v:refname | head -n 1)"
if [[ -z "$local_version" ]]; then
  echo "Prepared local TunaKit package has no version tag." >&2
  exit 1
fi
while IFS= read -r -d '' resolved_file; do
  jq --arg location "$package_url" --arg revision "$local_revision" --arg version "$local_version" \
    '(.pins[] | select(.identity == "tunakit")) |= (.location = $location | .state = {revision: $revision, version: $version})' \
    "$resolved_file" > "$resolved_file.local"
  mv "$resolved_file.local" "$resolved_file"
done < <(find "$temporary_source" -path '*/xcshareddata/swiftpm/Package.resolved' -print0)
project="$temporary_source/$(basename "$source_project")"
TUNA_LOCAL_PACKAGE_URL="$package_url" perl -0pi -e \
  's{repositoryURL = "https://github\.com/tunaformac/TunaKit";}{repositoryURL = "$ENV{TUNA_LOCAL_PACKAGE_URL}";}g' \
  "$project/project.pbxproj"

build_settings=()
if [[ "$CONFIGURATION" == "Debug" ]]; then
  build_settings+=(ONLY_ACTIVE_ARCH=YES)
fi
if [[ -n "${TUNA_DEVELOPMENT_TEAM:-}" ]]; then
  build_settings+=(DEVELOPMENT_TEAM="$TUNA_DEVELOPMENT_TEAM")
fi
if [[ -n "${TUNA_CODE_SIGN_IDENTITY:-}" ]]; then
  build_settings+=(CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$TUNA_CODE_SIGN_IDENTITY")
fi

# A rebuilt local package can reuse the same semantic version at a new revision. SwiftPM rejects
# that intentionally mutable development tag when its workspace still records the old SHA.
rm -rf "$DERIVED_DATA/SourcePackages"

xcodebuild -resolvePackageDependencies \
  -project "$project" \
  -scheme "$resolved_target" \
  -clonedSourcePackagesDirPath "$DERIVED_DATA/SourcePackages" \
  -disablePackageRepositoryCache \
  -scmProvider system >&2

xcodebuild build \
  -project "$project" \
  -scheme "$resolved_target" \
  -configuration "$CONFIGURATION" \
  -destination "$DESTINATION" \
  -derivedDataPath "$DERIVED_DATA" \
  -clonedSourcePackagesDirPath "$DERIVED_DATA/SourcePackages" \
  -disablePackageRepositoryCache \
  -scmProvider system \
  "${build_settings[@]}" >&2

settings_file="$(mktemp)"
trap 'rm -f "$settings_file"; cleanup' EXIT
xcodebuild \
  -project "$project" \
  -scheme "$resolved_target" \
  -configuration "$CONFIGURATION" \
  -destination "$DESTINATION" \
  -derivedDataPath "$DERIVED_DATA" \
  -clonedSourcePackagesDirPath "$DERIVED_DATA/SourcePackages" \
  -disablePackageRepositoryCache \
  -scmProvider system \
  -showBuildSettings > "$settings_file"

target_build_dir="$(rg '^ *TARGET_BUILD_DIR' -m1 "$settings_file" | sed 's/.*= //')"
full_product_name="$(rg '^ *FULL_PRODUCT_NAME' -m1 "$settings_file" | sed 's/.*= //')"
source_path="$target_build_dir/$full_product_name"

if [[ -z "$target_build_dir" || -z "$full_product_name" || ! -e "$source_path" ]]; then
  echo "Failed to resolve local build output for $resolved_target in $source_project" >&2
  exit 1
fi

printf '%s\n' "$source_path"
