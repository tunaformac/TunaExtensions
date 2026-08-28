#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TUNA_ROOT="${1:-${TUNA_ROOT:-}}"

if [[ -z "$TUNA_ROOT" ]]; then
  echo "A Tuna checkout is required to build local TunaKit." >&2
  echo "Set TUNA_ROOT to its absolute path." >&2
  exit 64
fi
if [[ ! -d "$TUNA_ROOT" ]]; then
  echo "Tuna checkout not found at $TUNA_ROOT" >&2
  exit 64
fi
TUNA_ROOT="$(cd "$TUNA_ROOT" && pwd -P)"
TUNAKIT_PROJECT="$TUNA_ROOT/app/TunaKit/TunaKit.xcodeproj"
DERIVED_DATA="$ROOT/build/local-tunakit-dd"
PACKAGE_ROOT="$ROOT/build/local-tunakit-package"
ARCH="$(uname -m)"

if [[ ! -d "$TUNAKIT_PROJECT" ]]; then
  echo "Local TunaKit project not found at $TUNAKIT_PROJECT" >&2
  echo "Set TUNA_ROOT to a Tuna checkout." >&2
  exit 64
fi

echo "TunaExtensions root: $ROOT" >&2
echo "Tuna root: $TUNA_ROOT" >&2

package_versions="$(
  find "$ROOT" -path "$ROOT/build" -prune -o \
    -path '*/xcshareddata/swiftpm/Package.resolved' -print0 \
    | xargs -0 jq -r '.pins[] | select(.identity == "tunakit") | .state.version' \
    | sort -u
)"
if [[ -z "$package_versions" ]]; then
  echo "Expected at least one extension to resolve a TunaKit package version." >&2
  exit 1
fi

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
minimum_versions="$({
  printf '%s\n' "$package_versions"
  find "$ROOT" -path "$ROOT/build" -prune -o -name project.pbxproj -print0 \
    | xargs -0 awk '/minimumVersion = [0-9]+\.[0-9]+\.[0-9]+;/ { gsub(";", "", $3); print $3 }'
} | sort -u)"
while IFS= read -r version; do
  [[ -n "$version" ]] && git -C "$PACKAGE_ROOT" tag "$version"
done <<<"$minimum_versions"

printf '%s\n' "$PACKAGE_ROOT"
