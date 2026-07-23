#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TUNA_ROOT="${1:-${TUNA_ROOT:-$ROOT/../Tuna}}"
TUNAKIT_PROJECT="$TUNA_ROOT/app/TunaKit/TunaKit.xcodeproj"
DERIVED_DATA="$ROOT/build/local-tunakit-dd"
PACKAGE_ROOT="$ROOT/build/local-tunakit-package"
ARCH="$(uname -m)"

if [[ ! -d "$TUNAKIT_PROJECT" ]]; then
  echo "Local TunaKit project not found at $TUNAKIT_PROJECT" >&2
  echo "Set TUNA_ROOT to a Tuna checkout." >&2
  exit 64
fi

package_versions="$(
  find "$ROOT" -path "$ROOT/build" -prune -o \
    -path '*/xcshareddata/swiftpm/Package.resolved' -print0 \
    | xargs -0 jq -r '.pins[] | select(.identity == "tunakit") | .state.version' \
    | sort -u
)"
if [[ -z "$package_versions" || "$package_versions" == *$'\n'* ]]; then
  echo "Expected every extension to resolve one common TunaKit package version." >&2
  exit 1
fi
package_version="$package_versions"

xcodebuild build \
  -project "$TUNAKIT_PROJECT" \
  -scheme TunaKit \
  -configuration Debug \
  -destination "platform=macOS,arch=$ARCH" \
  -derivedDataPath "$DERIVED_DATA" \
  BUILD_LIBRARY_FOR_DISTRIBUTION=YES \
  CODE_SIGNING_ALLOWED=NO \
  ONLY_ACTIVE_ARCH=YES >&2

framework="$DERIVED_DATA/Build/Products/Debug/TunaKit.framework"
if [[ ! -d "$framework" ]]; then
  echo "Local TunaKit build product not found at $framework" >&2
  exit 1
fi

case "$PACKAGE_ROOT" in
  "$ROOT"/build/local-tunakit-package) ;;
  *) echo "Refusing to replace unexpected package path: $PACKAGE_ROOT" >&2; exit 1 ;;
esac
rm -rf "$PACKAGE_ROOT"
mkdir -p "$PACKAGE_ROOT"
cp "$ROOT/scripts/local-tunakit-package/Package.swift" "$PACKAGE_ROOT/Package.swift"
xcodebuild -create-xcframework \
  -framework "$framework" \
  -output "$PACKAGE_ROOT/TunaKit.xcframework" >&2

git -C "$PACKAGE_ROOT" init -q
git -C "$PACKAGE_ROOT" config user.name "Tuna Development"
git -C "$PACKAGE_ROOT" config user.email "development@tuna.local"
git -C "$PACKAGE_ROOT" add Package.swift TunaKit.xcframework
git -C "$PACKAGE_ROOT" commit -qm "Build local TunaKit"
git -C "$PACKAGE_ROOT" tag "$package_version"

printf '%s\n' "$PACKAGE_ROOT"
