#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET="${1:-}"
INSTALL_DIR="${2:-}"
CONFIGURATION="${3:-Debug}"
DESTINATION="${4:-generic/platform=macOS}"
DERIVED_DATA="${5:-./build/dd}"

if [[ -z "$TARGET" || -z "$INSTALL_DIR" ]]; then
  echo "Usage: $0 TARGET INSTALL_DIR [CONFIGURATION] [DESTINATION] [DERIVED_DATA]" >&2
  exit 64
fi

SOURCE_PATH="$(
  "$ROOT/scripts/build-extension-product.sh" \
    "$TARGET" \
    "$CONFIGURATION" \
    "$DESTINATION" \
    "$DERIVED_DATA"
)"

FULL_PRODUCT_NAME="$(basename "$SOURCE_PATH")"

# Creating the new-name dir here would strand a legacy PlugIns/PlugInsDev dir
# forever (the app only migrates when the new dir is absent), so move it first.
if [[ ! -e "$INSTALL_DIR" ]]; then
  case "$(basename "$INSTALL_DIR")" in
    Extensions) LEGACY_DIR="$(dirname "$INSTALL_DIR")/PlugIns" ;;
    ExtensionsDev) LEGACY_DIR="$(dirname "$INSTALL_DIR")/PlugInsDev" ;;
    *) LEGACY_DIR="" ;;
  esac
  if [[ -n "$LEGACY_DIR" && -d "$LEGACY_DIR" ]]; then
    mv "$LEGACY_DIR" "$INSTALL_DIR"
  fi
fi
mkdir -p "$INSTALL_DIR"
DEST_PATH="$INSTALL_DIR/$FULL_PRODUCT_NAME"

"$ROOT/scripts/install-dev-bundle.sh" "$SOURCE_PATH" "$DEST_PATH"
