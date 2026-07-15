#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET="${1:-}"
CONFIGURATION="${2:-}"
DESTINATION="${3:-generic/platform=macOS}"
DERIVED_DATA="${4:-./build/dd}"

if [[ -z "$TARGET" || -z "$CONFIGURATION" ]]; then
  echo "Usage: $0 TARGET CONFIGURATION [DESTINATION] [DERIVED_DATA]" >&2
  exit 64
fi

read -r PROJECT RESOLVED_TARGET < <("$ROOT/scripts/resolve-extension-scheme.sh" "$TARGET")

BUILD_SETTINGS=()
if [[ "$CONFIGURATION" == "Debug" ]]; then
  BUILD_SETTINGS+=(ONLY_ACTIVE_ARCH=YES)
fi
if [[ -n "${TUNA_DEVELOPMENT_TEAM:-}" ]]; then
  BUILD_SETTINGS+=(DEVELOPMENT_TEAM="$TUNA_DEVELOPMENT_TEAM")
fi
if [[ -n "${TUNA_CODE_SIGN_IDENTITY:-}" ]]; then
  BUILD_SETTINGS+=(CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$TUNA_CODE_SIGN_IDENTITY")
fi

run_build() {
  if [[ ${#BUILD_SETTINGS[@]} -gt 0 ]]; then
    xcodebuild build "$@" "${BUILD_SETTINGS[@]}" >&2
  else
    xcodebuild build "$@" >&2
  fi
}

run_build \
  -project "$PROJECT" \
  -scheme "$RESOLVED_TARGET" \
  -configuration "$CONFIGURATION" \
  -destination "$DESTINATION" \
  -derivedDataPath "$DERIVED_DATA"

SETTINGS_FILE="$(mktemp)"
trap 'rm -f "$SETTINGS_FILE"' EXIT

xcodebuild \
  -project "$PROJECT" \
  -scheme "$RESOLVED_TARGET" \
  -configuration "$CONFIGURATION" \
  -destination "$DESTINATION" \
  -derivedDataPath "$DERIVED_DATA" \
  -showBuildSettings > "$SETTINGS_FILE"

TARGET_BUILD_DIR="$(rg "^ *TARGET_BUILD_DIR" -m1 "$SETTINGS_FILE" | sed 's/.*= //')"
FULL_PRODUCT_NAME="$(rg "^ *FULL_PRODUCT_NAME" -m1 "$SETTINGS_FILE" | sed 's/.*= //')"

if [[ -z "$TARGET_BUILD_DIR" || -z "$FULL_PRODUCT_NAME" ]]; then
  echo "Failed to resolve build output for $RESOLVED_TARGET in $PROJECT" >&2
  exit 1
fi

SOURCE_PATH="$TARGET_BUILD_DIR/$FULL_PRODUCT_NAME"
if [[ ! -e "$SOURCE_PATH" ]]; then
  echo "Built product not found at $SOURCE_PATH" >&2
  exit 1
fi

echo "$SOURCE_PATH"
