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

IFS=$'\t' read -r source_project resolved_target < <("$ROOT/scripts/resolve-extension-scheme.sh" "$TARGET")
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
shared_package="$("$ROOT/scripts/extension-shared-package.sh" "$source_project")"
if [[ -n "$shared_package" ]]; then
  ditto "$ROOT/$shared_package" "$temporary_directory/$shared_package"
fi
package_url="file://$LOCAL_PACKAGE"
local_revision="$(git -C "$LOCAL_PACKAGE" rev-parse HEAD)"
resolved_files=()
while IFS= read -r -d '' resolved_file; do
  resolved_files+=("$resolved_file")
done < <(find "$temporary_source" -path '*/xcshareddata/swiftpm/Package.resolved' -print0)
if [[ ${#resolved_files[@]} -ne 1 ]]; then
  echo "Expected exactly one Package.resolved for $source_project, found ${#resolved_files[@]}." >&2
  exit 1
fi
project="$temporary_source/$(basename "$source_project")"
"$ROOT/scripts/rewrite-local-tunakit-references.py" rewrite \
  --project "$project/project.pbxproj" \
  --resolved "${resolved_files[0]}" \
  --package-url "$package_url" \
  --revision "$local_revision"

# The prepared TunaKit xcframework contains the current host architecture. Keep local builds on
# that same architecture in every configuration, including Release validation.
build_settings=(ONLY_ACTIVE_ARCH=YES)
if [[ -n "${TUNA_DEVELOPMENT_TEAM:-}" ]]; then
  build_settings+=(DEVELOPMENT_TEAM="$TUNA_DEVELOPMENT_TEAM")
fi
if [[ -n "${TUNA_CODE_SIGN_IDENTITY:-}" ]]; then
  build_settings+=(CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$TUNA_CODE_SIGN_IDENTITY")
fi

# A rebuilt local package can reuse the same semantic version at a new revision. SwiftPM rejects
# that intentionally mutable development tag when its workspace still records the old SHA, and its
# per-user trust-on-first-use fingerprints would reject it too, so only warn about those.
rm -rf "$DERIVED_DATA/SourcePackages"
package_settings=(
  -clonedSourcePackagesDirPath "$DERIVED_DATA/SourcePackages"
  -disablePackageRepositoryCache
  -packageFingerprintPolicy warn
  -scmProvider system
)

"$ROOT/scripts/run-xcodebuild" -resolvePackageDependencies \
  -project "$project" \
  -scheme "$resolved_target" \
  "${package_settings[@]}" >&2

"$ROOT/scripts/run-xcodebuild" build \
  -project "$project" \
  -scheme "$resolved_target" \
  -configuration "$CONFIGURATION" \
  -destination "$DESTINATION" \
  -derivedDataPath "$DERIVED_DATA" \
  "${package_settings[@]}" \
  "${build_settings[@]}" >&2

settings_file="$(mktemp)"
trap 'rm -f "$settings_file"; cleanup' EXIT
"$ROOT/scripts/run-xcodebuild" --output "$settings_file" -- \
  -project "$project" \
  -scheme "$resolved_target" \
  -configuration "$CONFIGURATION" \
  -destination "$DESTINATION" \
  -derivedDataPath "$DERIVED_DATA" \
  "${package_settings[@]}" \
  -showBuildSettings

target_build_dir="$(rg '^ *TARGET_BUILD_DIR' -m1 "$settings_file" | sed 's/.*= //')"
full_product_name="$(rg '^ *FULL_PRODUCT_NAME' -m1 "$settings_file" | sed 's/.*= //')"
source_path="$target_build_dir/$full_product_name"

if [[ -z "$target_build_dir" || -z "$full_product_name" || ! -e "$source_path" ]]; then
  echo "Failed to resolve local build output for $resolved_target in $source_project" >&2
  exit 1
fi

printf '%s\n' "$source_path"
