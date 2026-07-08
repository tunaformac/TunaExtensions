#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET="${1:?Usage: ext-package.sh TARGET DESTINATION DERIVED_DATA}"
DESTINATION="${2:?Usage: ext-package.sh TARGET DESTINATION DERIVED_DATA}"
DERIVED_DATA="${3:?Usage: ext-package.sh TARGET DESTINATION DERIVED_DATA}"
OUTDIR="$ROOT/dist/store"
DEFAULT_TUNA_BINARY="/Applications/Tuna.app/Contents/MacOS/Tuna"
TEMP_SIGNING_KEY=""
TEMP_DECLARATION_JSON=""
SIGNING_KEY_OP_REF="${EXTENSIONS_STORE_SIGNING_PRIVATE_KEY_OP:-op://Brainbow/Tuna/EXTENSIONS_STORE_SIGNING_PRIVATE_KEY}"

cleanup() {
  if [[ -n "$TEMP_SIGNING_KEY" && -f "$TEMP_SIGNING_KEY" ]]; then
    rm -f "$TEMP_SIGNING_KEY"
  fi
  if [[ -n "$TEMP_DECLARATION_JSON" && -f "$TEMP_DECLARATION_JSON" ]]; then
    rm -f "$TEMP_DECLARATION_JSON"
  fi
}

trap cleanup EXIT

resolve_signing_key() {
  if [[ -n "${SIGNING_KEY:-}" ]]; then
    printf '%s\n' "$SIGNING_KEY"
    return
  fi

  if [[ -z "$SIGNING_KEY_OP_REF" ]]; then
    return
  fi

  if ! command -v op >/dev/null 2>&1; then
    echo "1Password CLI (op) not found; set SIGNING_KEY directly or install op." >&2
    exit 1
  fi

  local pem
  if ! pem="$(op read "$SIGNING_KEY_OP_REF" 2>/dev/null)"; then
    echo "Failed to read extensions store signing key from 1Password ($SIGNING_KEY_OP_REF)." >&2
    exit 1
  fi

  local safe_target="${TARGET//[^A-Za-z0-9_.-]/-}"
  TEMP_SIGNING_KEY="$(mktemp "${TMPDIR:-/tmp}/extensions-store-signing-key.${safe_target}.XXXXXX")"
  chmod 600 "$TEMP_SIGNING_KEY"
  printf '%s\n' "$pem" > "$TEMP_SIGNING_KEY"
  printf '%s\n' "$TEMP_SIGNING_KEY"
}

SRC="$("$ROOT/scripts/build-extension-product.sh" "$TARGET" Release "$DESTINATION" "$DERIVED_DATA")"
mkdir -p "$OUTDIR"

ARGS=()
find_info_plist() {
  local bundle_path="$1"
  if [[ -f "$bundle_path/Contents/Info.plist" ]]; then
    printf '%s\n' "$bundle_path/Contents/Info.plist"
    return
  fi
  if [[ -f "$bundle_path/Info.plist" ]]; then
    printf '%s\n' "$bundle_path/Info.plist"
    return
  fi
  if [[ -f "$bundle_path/Resources/Info.plist" ]]; then
    printf '%s\n' "$bundle_path/Resources/Info.plist"
    return
  fi
  if [[ -f "$bundle_path/Versions/Current/Resources/Info.plist" ]]; then
    printf '%s\n' "$bundle_path/Versions/Current/Resources/Info.plist"
    return
  fi

  find "$bundle_path" -maxdepth 4 -type f -name Info.plist | head -n 1
}

plist_has_key() {
  local plist="$1"
  local key="$2"
  /usr/libexec/PlistBuddy -c "Print :$key" "$plist" >/dev/null 2>&1
}

read_declaration_compatibility_value() {
  local json_path="$1"
  local key="$2"
  python3 - "$json_path" "$key" <<'PY'
import json
import sys

with open(sys.argv[1], encoding='utf-8') as fh:
    declaration = json.load(fh)

compatibility = declaration.get('compatibility') or {}
print(compatibility.get(sys.argv[2]) or '')
PY
}

dump_extension_declaration() {
  local tuna_binary="${TUNA_BINARY:-$DEFAULT_TUNA_BINARY}"
  if [[ ! -x "$tuna_binary" ]]; then
    echo "Tuna binary not found or not executable: $tuna_binary" >&2
    echo "Set TUNA_BINARY to a built Tuna executable or run 'just build'." >&2
    exit 1
  fi

  # Assigned in the caller's shell (not a command substitution) so the EXIT
  # trap can clean it up.
  TEMP_DECLARATION_JSON="$(mktemp "${TMPDIR:-/tmp}/tuna-extension-declaration.XXXXXX.json")"
  "$tuna_binary" --dump-extension-declaration "$SRC" >"$TEMP_DECLARATION_JSON"
}

read_theme_compatibility_value() {
  local plist="$1"
  local key="$2"
  python3 - "$plist" "$key" <<'PY'
import plistlib
import sys

with open(sys.argv[1], 'rb') as fh:
    info = plistlib.load(fh)

manifest = info.get('TKTheme') or {}
compatibility = manifest.get('Compatibility') or {}
print(compatibility.get(sys.argv[2]) or '')
PY
}

INFO_PLIST="$(find_info_plist "$SRC")"
if [[ -z "$INFO_PLIST" ]]; then
  echo "Info.plist not found in bundle: $SRC" >&2
  exit 1
fi

DECLARATION_JSON=""
if plist_has_key "$INFO_PLIST" "TKTheme"; then
  :
else
  dump_extension_declaration
  DECLARATION_JSON="$TEMP_DECLARATION_JSON"
  ARGS+=(--declaration-json "$DECLARATION_JSON")
fi

MIN_TUNA_VALUE="${MIN_TUNA:-}"
if [[ -z "$MIN_TUNA_VALUE" ]]; then
  if [[ -n "$DECLARATION_JSON" ]]; then
    MIN_TUNA_VALUE="$(read_declaration_compatibility_value "$DECLARATION_JSON" min_tuna)"
  else
    MIN_TUNA_VALUE="$(read_theme_compatibility_value "$INFO_PLIST" MinTuna)"
  fi
fi
if [[ -z "$MIN_TUNA_VALUE" ]]; then
  echo "No min Tuna version: declare compatibility.minTuna in the extension or set MIN_TUNA." >&2
  exit 1
fi
if [[ -n "$MIN_TUNA_VALUE" ]]; then
  ARGS+=(--min-tuna "$MIN_TUNA_VALUE")
fi

MIN_TUNAKIT_VALUE="${MIN_TUNAKIT:-}"
if [[ -z "$MIN_TUNAKIT_VALUE" ]]; then
  if [[ -n "$DECLARATION_JSON" ]]; then
    MIN_TUNAKIT_VALUE="$(read_declaration_compatibility_value "$DECLARATION_JSON" min_tunakit)"
  else
    MIN_TUNAKIT_VALUE="$(read_theme_compatibility_value "$INFO_PLIST" MinTunaKit)"
  fi
fi
if [[ -z "$MIN_TUNAKIT_VALUE" ]]; then
  echo "No min TunaKit version: declare compatibility.minTunaKit in the extension or set MIN_TUNAKIT." >&2
  exit 1
fi
if [[ -n "$MIN_TUNAKIT_VALUE" ]]; then
  ARGS+=(--min-tunakit "$MIN_TUNAKIT_VALUE")
fi
if [[ -n "${MIN_MACOS:-}" ]]; then
  ARGS+=(--min-macos "$MIN_MACOS")
fi
if [[ -n "${ARCH:-}" ]]; then
  for arch in $ARCH; do
    ARGS+=(--arch "$arch")
  done
fi

SIGNING_KEY_PATH="$(resolve_signing_key)"
if [[ -n "$SIGNING_KEY_PATH" ]]; then
  ARGS+=(--signing-key "$SIGNING_KEY_PATH")
fi

if [[ -n "${KEY_ID:-}" ]]; then
  ARGS+=(--key-id "$KEY_ID")
fi

"$ROOT/scripts/package-tunaextension.py" --bundle "$SRC" --out "$OUTDIR" "${ARGS[@]}"
