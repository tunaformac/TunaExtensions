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
local_revision="$(git -C "$LOCAL_PACKAGE" rev-parse HEAD)"
while IFS= read -r -d '' resolved_file; do
  jq --arg revision "$local_revision" \
    '(.pins[] | select(.identity == "tunakit").state.revision) = $revision' \
    "$resolved_file" > "$resolved_file.local"
  mv "$resolved_file.local" "$resolved_file"
done < <(find "$temporary_source" -path '*/xcshareddata/swiftpm/Package.resolved' -print0)
project="$temporary_source/$(basename "$source_project")"

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

package_url="file://$LOCAL_PACKAGE"
export GIT_CONFIG_COUNT=1
export GIT_CONFIG_KEY_0="url.${package_url}.insteadOf"
export GIT_CONFIG_VALUE_0="https://github.com/tunaformac/TunaKit"

xcodebuild -resolvePackageDependencies \
  -project "$project" \
  -scheme "$resolved_target" \
  -clonedSourcePackagesDirPath "$DERIVED_DATA/SourcePackages" \
  -scmProvider system >&2

xcodebuild build \
  -project "$project" \
  -scheme "$resolved_target" \
  -configuration "$CONFIGURATION" \
  -destination "$DESTINATION" \
  -derivedDataPath "$DERIVED_DATA" \
  -clonedSourcePackagesDirPath "$DERIVED_DATA/SourcePackages" \
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
