#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET="${1:?Usage: upload-extension.sh TARGET}"
API_URL="${STORE_API_URL:-https://tunaformac.com/api/v1/items}"
TOKEN="${RELEASE_UPLOAD_TOKEN:-}"
TOKEN_OP_REF="${RELEASE_UPLOAD_TOKEN_OP:-op://Brainbow/Tuna/RELEASE_UPLOAD_TOKEN}"
CREATE_GIT_TAG="${CREATE_GIT_TAG:-0}"

source "$ROOT/scripts/git-tag-helpers.sh"

if [[ -z "$TOKEN" && -n "$TOKEN_OP_REF" ]]; then
  if command -v op >/dev/null 2>&1; then
    if ! TOKEN="$(op read "$TOKEN_OP_REF" 2>/dev/null)"; then
      echo "Warning: failed to read RELEASE_UPLOAD_TOKEN from 1Password ($TOKEN_OP_REF)." >&2
      TOKEN=""
    fi
  else
    echo "1Password CLI (op) not found; set RELEASE_UPLOAD_TOKEN directly." >&2
  fi
fi

if [[ -z "$TOKEN" ]]; then
  echo "Set RELEASE_UPLOAD_TOKEN, provide RELEASE_UPLOAD_TOKEN_OP, or configure Creds.release_upload_token." >&2
  exit 1
fi

PROJECT_FILE=""
if [[ "$CREATE_GIT_TAG" == "1" ]]; then
  read -r PROJECT _RESOLVED_TARGET < <("$ROOT/scripts/resolve-extension-scheme.sh" "$TARGET")
  PROJECT="${PROJECT#$ROOT/}"
  PROJECT_FILE="$PROJECT/project.pbxproj"
  ensure_paths_committed "$ROOT" "$PROJECT_FILE"
fi

RAW_OUTPUT="$(make ext-package TARGET="$TARGET")"
ITEM_JSON="$(echo "$RAW_OUTPUT" | python3 -c "
import json
import sys

text = sys.stdin.read()
decoder = json.JSONDecoder()
keys = {'id', 'name', 'version', 'compatibility'}
selected = None

for idx, ch in enumerate(text):
    if ch != '{':
        continue
    try:
        obj, _ = decoder.raw_decode(text[idx:])
    except json.JSONDecodeError:
        continue
    if isinstance(obj, dict) and keys.issubset(obj.keys()):
        selected = obj
        break

if selected is None:
    raise SystemExit('Failed to parse package metadata JSON from ext-package output.')

print(json.dumps(selected))
")"

read_field() { echo "$ITEM_JSON" | python3 -c "import json,sys; d=json.load(sys.stdin); print($1)"; }

ID="$(read_field "d['id']")"
NAME="$(read_field "d['name']")"
SUMMARY="$(read_field "d['summary']")"
VERSION="$(read_field "d['version']")"
TYPE="$(read_field "d['type']")"
DEV_NAME="$(read_field "d['developer_name']")"
MIN_TUNA="$(read_field "d['compatibility']['min_tuna']")"
MIN_TUNAKIT="$(read_field "d.get('compatibility', {}).get('min_tunakit', '')")"
MIN_MACOS="$(read_field "d['compatibility']['min_macos']")"
ARCHES=()
while IFS= read -r ARCH; do
  [[ -n "$ARCH" ]] && ARCHES+=("$ARCH")
done < <(echo "$ITEM_JSON" | python3 -c "import json,sys; d=json.load(sys.stdin); [print(a) for a in d.get('compatibility', {}).get('arch', [])]")

SAFE_ID="${ID//\//_}"
PKG="$ROOT/dist/store/${SAFE_ID}-${VERSION}.tunaextension"

if [[ ! -f "$PKG" ]]; then
  echo "Package not found: $PKG" >&2
  exit 1
fi

slugify() {
  printf "%s" "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//'
}

add_media_key() {
  local VALUE="$1"
  [[ -z "$VALUE" ]] && return
  local EXISTING
  for EXISTING in "${MEDIA_KEYS[@]-}"; do
    [[ "$EXISTING" == "$VALUE" ]] && return
  done
  MEDIA_KEYS+=("$VALUE")
}

MEDIA_KEYS=()
for KEY in "$SAFE_ID" "$ID" "${ID##*.}" "$TARGET" "$(slugify "$TARGET")" "$NAME" "$(slugify "$NAME")"; do
  add_media_key "$KEY"
done

if [[ "$TARGET" == Tuna* ]]; then
  TARGET_SUFFIX="${TARGET#Tuna}"
  add_media_key "$TARGET_SUFFIX"
  add_media_key "$(slugify "$TARGET_SUFFIX")"
fi

MEDIA_ROOTS=(
  "$ROOT/dist/store"
  "$ROOT/media"
)

RASTER_MEDIA_EXTS=(png jpg jpeg webp gif)
VECTOR_MEDIA_EXTS=(svg)

content_type_for_path() {
  local FILENAME="${1##*/}"
  local EXT="${FILENAME##*.}"
  EXT="$(printf '%s' "$EXT" | tr '[:upper:]' '[:lower:]')"

  case "$EXT" in
    png) echo "image/png" ;;
    jpg|jpeg) echo "image/jpeg" ;;
    webp) echo "image/webp" ;;
    gif) echo "image/gif" ;;
    svg) echo "image/svg+xml" ;;
    tunaextension) echo "application/octet-stream" ;;
    *) echo "application/octet-stream" ;;
  esac
}

form_file_arg() {
  local FIELD="$1"
  local PATH_VALUE="$2"
  printf '%s=@%s;type=%s' "$FIELD" "$PATH_VALUE" "$(content_type_for_path "$PATH_VALUE")"
}

find_icon_path() {
  local ROOT_DIR KEY EXT CANDIDATE
  for EXT in "${RASTER_MEDIA_EXTS[@]}" "${VECTOR_MEDIA_EXTS[@]}"; do
    for ROOT_DIR in "${MEDIA_ROOTS[@]}"; do
      for KEY in "${MEDIA_KEYS[@]}"; do
        CANDIDATE="$ROOT_DIR/icons/$KEY.$EXT"
        if [[ -f "$CANDIDATE" ]]; then
          echo "$CANDIDATE"
          return 0
        fi
      done
    done
  done

  return 1
}

add_screenshot_path() {
  local PATH_VALUE="$1"
  [[ -z "$PATH_VALUE" ]] && return
  local EXISTING
  for EXISTING in "${SCREENSHOT_PATHS[@]-}"; do
    [[ "$EXISTING" == "$PATH_VALUE" ]] && return
  done
  SCREENSHOT_PATHS+=("$PATH_VALUE")
}

collect_screenshot_paths() {
  local ROOT_DIR KEY EXT DIR CANDIDATE
  SCREENSHOT_PATHS=()

  for EXT in "${RASTER_MEDIA_EXTS[@]}" "${VECTOR_MEDIA_EXTS[@]}"; do
    for ROOT_DIR in "${MEDIA_ROOTS[@]}"; do
      for KEY in "${MEDIA_KEYS[@]}"; do
        DIR="$ROOT_DIR/screenshots/$KEY"
        if [[ -d "$DIR" ]]; then
          for CANDIDATE in "$DIR"/*."$EXT"; do
            [[ -f "$CANDIDATE" ]] || continue
            add_screenshot_path "$CANDIDATE"
          done
        fi

        CANDIDATE="$ROOT_DIR/screenshots/$KEY.$EXT"
        if [[ -f "$CANDIDATE" ]]; then
          add_screenshot_path "$CANDIDATE"
        fi
      done
    done
  done
}

echo "Uploading $PKG → $API_URL/$ID ..."

if [[ ${#ARCHES[@]} -eq 0 ]]; then
  ARCHES=("arm64")
fi

CURL_ARGS=(
  --silent
  --show-error
  -X PUT "$API_URL/$ID"
  -H "Authorization: Bearer $TOKEN"
  -F "store_item[name]=$NAME"
  -F "store_item[summary]=$SUMMARY"
  -F "store_item[item_type]=$TYPE"
  -F "store_item[version]=$VERSION"
  -F "store_item[developer_name]=$DEV_NAME"
  -F "store_item[compatibility_min_tuna]=$MIN_TUNA"
  -F "store_item[compatibility_min_macos]=$MIN_MACOS"
)

if [[ -n "$MIN_TUNAKIT" ]]; then
  CURL_ARGS+=(-F "store_item[compatibility_min_tunakit]=$MIN_TUNAKIT")
fi

for ARCH in "${ARCHES[@]}"; do
  CURL_ARGS+=(-F "store_item[compatibility_arch][]=$ARCH")
done

if ICON_PATH="$(find_icon_path)"; then
  echo "Using icon: $ICON_PATH"
  CURL_ARGS+=(-F "$(form_file_arg "store_item[icon]" "$ICON_PATH")")
fi

collect_screenshot_paths
if [[ ${#SCREENSHOT_PATHS[@]} -gt 0 ]]; then
  echo "Using ${#SCREENSHOT_PATHS[@]} screenshot(s)"
  for SCREENSHOT_PATH in "${SCREENSHOT_PATHS[@]}"; do
    CURL_ARGS+=(-F "$(form_file_arg "store_item[screenshots][]" "$SCREENSHOT_PATH")")
  done
fi

CURL_ARGS+=(-F "$(form_file_arg "store_item[asset]" "$PKG")")

RESPONSE_BODY="$(mktemp)"
trap 'rm -f "$RESPONSE_BODY"' EXIT
print_response_body() {
  if [[ -s "$RESPONSE_BODY" ]]; then
    cat "$RESPONSE_BODY" >&2
  fi
}

if ! HTTP_CODE="$(curl "${CURL_ARGS[@]}" -o "$RESPONSE_BODY" -w "%{http_code}")"; then
  echo "Upload failed before receiving an HTTP response." >&2
  print_response_body
  exit 1
fi

if [[ "$HTTP_CODE" -lt 200 || "$HTTP_CODE" -ge 300 ]]; then
  echo "Upload failed with HTTP $HTTP_CODE." >&2
  print_response_body
  exit 1
fi

if ! python3 -m json.tool < "$RESPONSE_BODY"; then
  cat "$RESPONSE_BODY"
fi

if [[ "$CREATE_GIT_TAG" == "1" ]]; then
  case "$TYPE" in
    extension) TAG="extensions/$ID/v$VERSION" ;;
    theme) TAG="themes/$ID/v$VERSION" ;;
    *)
      echo "Unknown packaged item type for tagging: $TYPE" >&2
      exit 1
      ;;
  esac

  create_annotated_tag "$ROOT" "$TAG" "$NAME $VERSION"
fi

echo "Done: $NAME $VERSION"
