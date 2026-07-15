#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET="${1:?Usage: upload-extension.sh TARGET}"
API_URL="${STORE_API_URL:-https://tunaformac.com/api/v1/items}"
TOKEN="${RELEASE_UPLOAD_TOKEN:-}"
TOKEN_OP_REF="${RELEASE_UPLOAD_TOKEN_OP:-op://Brainbow/Tuna/RELEASE_UPLOAD_TOKEN}"
CREATE_GIT_TAG="${CREATE_GIT_TAG:-0}"
RESPONSE_BODY=""
UPLOAD_SNAPSHOT_DIR=""

source "$ROOT/scripts/git-tag-helpers.sh"

cleanup() {
  if [[ -n "$RESPONSE_BODY" && -f "$RESPONSE_BODY" ]]; then
    /bin/rm -f "$RESPONSE_BODY"
  fi
  if [[ -n "$UPLOAD_SNAPSHOT_DIR" && -d "$UPLOAD_SNAPSHOT_DIR" ]]; then
    /bin/rm -rf "$UPLOAD_SNAPSHOT_DIR"
  fi
}

trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

RELEASE_COMMIT="$(git -C "$ROOT" rev-parse HEAD)"
read -r PROJECT _RESOLVED_TARGET < <("$ROOT/scripts/resolve-extension-scheme.sh" "$TARGET")
PROJECT="${PROJECT#$ROOT/}"
EXTENSION_DIR="$(dirname "$PROJECT")"
RELEASE_INPUTS=("$EXTENSION_DIR" .gitignore Makefile scripts media)
ensure_paths_committed "$ROOT" "${RELEASE_INPUTS[@]}"
ensure_head_unchanged "$ROOT" "$RELEASE_COMMIT"

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
  echo "Set RELEASE_UPLOAD_TOKEN or provide RELEASE_UPLOAD_TOKEN_OP." >&2
  exit 1
fi

RAW_OUTPUT="$(make -C "$ROOT" ext-package TARGET="$TARGET")"
ensure_paths_committed "$ROOT" "${RELEASE_INPUTS[@]}"
ensure_head_unchanged "$ROOT" "$RELEASE_COMMIT"
ITEM_JSON="$(printf '%s\n' "$RAW_OUTPUT" | python3 -c "
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

read_field() { printf '%s\n' "$ITEM_JSON" | python3 -c "import json,sys; d=json.load(sys.stdin); print($1)"; }

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

UPLOAD_SNAPSHOT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/tuna-extension-upload.XXXXXX")"
/bin/chmod 700 "$UPLOAD_SNAPSHOT_DIR"
UPLOAD_PKG="$UPLOAD_SNAPSHOT_DIR/$(basename "$PKG")"
ITEM_JSON_PATH="$UPLOAD_SNAPSHOT_DIR/item.json"
/bin/cp "$PKG" "$UPLOAD_PKG"
printf '%s\n' "$ITEM_JSON" >"$ITEM_JSON_PATH"
/bin/chmod 400 "$UPLOAD_PKG" "$ITEM_JSON_PATH"

python3 - "$UPLOAD_PKG" "$ITEM_JSON_PATH" <<'PY'
import hashlib
import json
import os
import re
import sys
import zipfile

package_path, item_path = sys.argv[1:]
with open(item_path, encoding="utf-8") as fh:
    item = json.load(fh)

download = item.get("download")
if not isinstance(download, dict):
    raise SystemExit("Refusing to upload package without download metadata.")

signature = download.get("signature")
if not isinstance(signature, dict) or not str(signature.get("signature_base64", "")).strip():
    raise SystemExit("Refusing to upload an unsigned package.")

expected_size = download.get("size_bytes")
if isinstance(expected_size, bool) or not isinstance(expected_size, int) or expected_size < 1:
    raise SystemExit("Refusing to upload package with an invalid declared size.")

expected_checksum = str(download.get("checksum_sha256", "")).strip().lower()
if not re.fullmatch(r"[0-9a-f]{64}", expected_checksum):
    raise SystemExit("Refusing to upload package with an invalid declared checksum.")

actual_size = os.path.getsize(package_path)
if actual_size != expected_size:
    raise SystemExit(
        f"Refusing to upload package: size is {actual_size}, expected {expected_size}."
    )

digest = hashlib.sha256()
with open(package_path, "rb") as fh:
    for chunk in iter(lambda: fh.read(1024 * 1024), b""):
        digest.update(chunk)
actual_checksum = digest.hexdigest()
if actual_checksum != expected_checksum:
    raise SystemExit(
        "Refusing to upload package: checksum does not match packaging metadata."
    )

try:
    with zipfile.ZipFile(package_path) as archive:
        signature_entries = [
            name for name in archive.namelist()
            if name in {"store-signature.json", "./store-signature.json"}
        ]
        if len(signature_entries) != 1:
            raise SystemExit(
                "Refusing to upload package without exactly one root store-signature.json."
            )
        embedded_signature = json.loads(archive.read(signature_entries[0]))
except zipfile.BadZipFile as error:
    raise SystemExit("Refusing to upload package: artifact is not a valid zip archive.") from error
except (UnicodeDecodeError, json.JSONDecodeError) as error:
    raise SystemExit("Refusing to upload package: store-signature.json is invalid.") from error

if embedded_signature != signature:
    raise SystemExit(
        "Refusing to upload package: embedded store signature does not match packaging metadata."
    )
PY

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
  local FILENAME="${3:-}"
  local VALUE="$FIELD=@$PATH_VALUE"
  if [[ -n "$FILENAME" ]]; then
    VALUE+=";filename=$FILENAME"
  fi
  printf '%s;type=%s' "$VALUE" "$(content_type_for_path "$PATH_VALUE")"
}

is_tracked_file() {
  local PATH_VALUE="$1"
  local RELATIVE_PATH="${PATH_VALUE#$ROOT/}"
  [[ -f "$PATH_VALUE" && ! -L "$PATH_VALUE" ]] || return 1
  git -C "$ROOT" ls-files --error-unmatch -- "$RELATIVE_PATH" >/dev/null 2>&1
}

find_icon_path() {
  local ROOT_DIR KEY EXT CANDIDATE
  for EXT in "${RASTER_MEDIA_EXTS[@]}" "${VECTOR_MEDIA_EXTS[@]}"; do
    for ROOT_DIR in "${MEDIA_ROOTS[@]}"; do
      for KEY in "${MEDIA_KEYS[@]}"; do
        CANDIDATE="$ROOT_DIR/icons/$KEY.$EXT"
        if [[ -f "$CANDIDATE" ]] && is_tracked_file "$CANDIDATE"; then
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
            [[ -f "$CANDIDATE" ]] && is_tracked_file "$CANDIDATE" || continue
            add_screenshot_path "$CANDIDATE"
          done
        fi

        CANDIDATE="$ROOT_DIR/screenshots/$KEY.$EXT"
        if [[ -f "$CANDIDATE" ]] && is_tracked_file "$CANDIDATE"; then
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
  --form-string "store_item[name]=$NAME"
  --form-string "store_item[summary]=$SUMMARY"
  --form-string "store_item[item_type]=$TYPE"
  --form-string "store_item[version]=$VERSION"
  --form-string "store_item[developer_name]=$DEV_NAME"
  --form-string "store_item[compatibility_min_tuna]=$MIN_TUNA"
  --form-string "store_item[compatibility_min_macos]=$MIN_MACOS"
)

if [[ -n "$MIN_TUNAKIT" ]]; then
  CURL_ARGS+=(--form-string "store_item[compatibility_min_tunakit]=$MIN_TUNAKIT")
fi

for ARCH in "${ARCHES[@]}"; do
  CURL_ARGS+=(--form-string "store_item[compatibility_arch][]=$ARCH")
done

if ICON_PATH="$(find_icon_path)"; then
  echo "Using icon: $ICON_PATH"
  CURL_ARGS+=(--form "$(form_file_arg "store_item[icon]" "$ICON_PATH")")
fi

collect_screenshot_paths
if [[ ${#SCREENSHOT_PATHS[@]} -gt 0 ]]; then
  echo "Using ${#SCREENSHOT_PATHS[@]} screenshot(s)"
  for SCREENSHOT_PATH in "${SCREENSHOT_PATHS[@]}"; do
    CURL_ARGS+=(--form "$(form_file_arg "store_item[screenshots][]" "$SCREENSHOT_PATH")")
  done
fi

CURL_ARGS+=(--form "$(form_file_arg "store_item[asset]" "$UPLOAD_PKG" "$(basename "$PKG")")")

TAG=""
if [[ "$CREATE_GIT_TAG" == "1" ]]; then
  case "$TYPE" in
    extension) TAG="extensions/$ID/v$VERSION" ;;
    theme) TAG="themes/$ID/v$VERSION" ;;
    *)
      echo "Unknown packaged item type for tagging: $TYPE" >&2
      exit 1
      ;;
  esac
fi

RESPONSE_BODY="$(mktemp "${TMPDIR:-/tmp}/tuna-extension-upload-response.XXXXXX")"
print_response_body() {
  if [[ -s "$RESPONSE_BODY" ]]; then
    cat "$RESPONSE_BODY" >&2
  fi
}

ensure_paths_committed "$ROOT" "${RELEASE_INPUTS[@]}"
ensure_head_unchanged "$ROOT" "$RELEASE_COMMIT"
if [[ -n "$TAG" ]]; then
  ensure_tag_available_at_commit "$ROOT" "$TAG" "$RELEASE_COMMIT"
fi

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

if [[ -n "$TAG" ]]; then
  create_annotated_tag "$ROOT" "$TAG" "$NAME $VERSION" "$RELEASE_COMMIT"
fi

echo "Done: $NAME $VERSION"
