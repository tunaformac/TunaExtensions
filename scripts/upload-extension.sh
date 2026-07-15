#!/usr/bin/env bash
set -euo pipefail
umask 077

unset TOKEN
TOKEN="${RELEASE_UPLOAD_TOKEN:-}"
export -n TOKEN
unset RELEASE_UPLOAD_TOKEN

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET="${1:?Usage: upload-extension.sh TARGET}"
API_URL="${STORE_API_URL:-https://tunaformac.com/api/v1/items}"
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

resolve_upload_token() {
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
    return 1
  fi
}

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
MIN_TUNAKIT="$(read_field "d.get('compatibility', {}).get('min_tunakit') or ''")"
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
PUBLIC_ARTIFACT_PATH="$UPLOAD_SNAPSHOT_DIR/public-artifact.tunaextension"
AUTH_CURL_CONFIG="$UPLOAD_SNAPSHOT_DIR/upload-auth.conf"
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

inspect_store_item() {
  local MODE="$1"
  local CONTEXT="$2"
  local EXPECT_ICON="${3:-0}"
  local EXPECT_SCREENSHOT_COUNT="${4:-0}"

  python3 - \
    "$ITEM_JSON_PATH" \
    "$RESPONSE_BODY" \
    "$MODE" \
    "$CONTEXT" \
    "$EXPECT_ICON" \
    "$EXPECT_SCREENSHOT_COUNT" <<'PY'
import json
import re
import sys

(
    candidate_path,
    response_path,
    mode,
    context,
    expect_icon_value,
    expected_screenshot_count_value,
) = sys.argv[1:]


def fail(message):
    raise SystemExit(f"{context}: {message}")


def load_json(path, label):
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        fail(f"{label} is not valid JSON ({error}).")


def require_string(value, label):
    if not isinstance(value, str) or not value.strip():
        fail(f"{label} must be a non-empty string.")
    return value


def version_parts(value, label):
    value = require_string(value, label)
    if not re.fullmatch(r"[0-9]+(?:\.[0-9]+)*", value):
        fail(f"{label} must contain only dot-separated integers, got {value!r}.")
    parts = tuple(int(part) for part in value.split("."))
    while len(parts) > 1 and parts[-1] == 0:
        parts = parts[:-1]
    return parts


def compare_versions(lhs, rhs):
    left = version_parts(lhs, "candidate version")
    right = version_parts(rhs, "store version")
    width = max(len(left), len(right))
    left += (0,) * (width - len(left))
    right += (0,) * (width - len(right))
    return (left > right) - (left < right)


def controlled_fields(item, label):
    if not isinstance(item, dict):
        fail(f"{label} must be an object.")

    item_id = require_string(item.get("id"), f"{label}.id")
    item_type = require_string(item.get("type"), f"{label}.type")
    name = require_string(item.get("name"), f"{label}.name")
    summary = require_string(item.get("summary"), f"{label}.summary")
    developer = require_string(
        item.get("developer_name"), f"{label}.developer_name"
    )
    version = require_string(item.get("version"), f"{label}.version")
    version_parts(version, f"{label}.version")

    compatibility = item.get("compatibility")
    if not isinstance(compatibility, dict):
        fail(f"{label}.compatibility must be an object.")

    min_tuna = require_string(
        compatibility.get("min_tuna"), f"{label}.compatibility.min_tuna"
    )
    min_macos = require_string(
        compatibility.get("min_macos"), f"{label}.compatibility.min_macos"
    )
    version_parts(min_tuna, f"{label}.compatibility.min_tuna")
    version_parts(min_macos, f"{label}.compatibility.min_macos")
    min_tunakit = compatibility.get("min_tunakit")
    if min_tunakit is not None:
        min_tunakit = require_string(
            min_tunakit, f"{label}.compatibility.min_tunakit"
        )
        version_parts(min_tunakit, f"{label}.compatibility.min_tunakit")

    arches = compatibility.get("arch")
    if not isinstance(arches, list) or not arches:
        fail(f"{label}.compatibility.arch must be a non-empty array.")
    if any(not isinstance(arch, str) or not arch.strip() for arch in arches):
        fail(f"{label}.compatibility.arch must contain non-empty strings.")
    arches = [arch.strip() for arch in arches]
    if len(arches) != len(set(arches)):
        fail(f"{label}.compatibility.arch contains duplicates.")

    download = item.get("download")
    if not isinstance(download, dict):
        fail(f"{label}.download must be an object.")
    size = download.get("size_bytes")
    if isinstance(size, bool) or not isinstance(size, int) or size < 1:
        fail(f"{label}.download.size_bytes must be a positive integer.")
    checksum = require_string(
        download.get("checksum_sha256"), f"{label}.download.checksum_sha256"
    ).lower()
    if not re.fullmatch(r"[0-9a-f]{64}", checksum):
        fail(f"{label}.download.checksum_sha256 must be a SHA-256 digest.")

    return {
        "id": item_id,
        "type": item_type,
        "name": name,
        "summary": summary,
        "developer": developer,
        "version": version,
        "min_tuna": min_tuna,
        "min_tunakit": min_tunakit,
        "min_macos": min_macos,
        "arches": sorted(arches),
        "size": size,
        "checksum": checksum,
    }


def exact_mismatches(candidate, remote):
    labels = {
        "id": "id",
        "type": "type",
        "name": "name",
        "summary": "summary",
        "developer": "developer",
        "version": "version",
        "min_tuna": "min Tuna",
        "min_tunakit": "min TunaKit",
        "min_macos": "min macOS",
        "arches": "architectures",
        "size": "package size",
        "checksum": "package SHA-256",
    }
    return [
        f"{labels[key]} is {remote[key]!r}, expected {candidate[key]!r}"
        for key in labels
        if remote[key] != candidate[key]
    ]


def media_recovery_reasons(item):
    reasons = []
    if expect_icon_value == "1":
        icon_url = item.get("icon_url")
        if not isinstance(icon_url, str) or not icon_url.strip():
            reasons.append("tracked icon is missing")

    if expected_screenshot_count:
        screenshots = item.get("screenshots")
        if not isinstance(screenshots, list):
            reasons.append("tracked screenshots are missing")
        elif len(screenshots) != expected_screenshot_count:
            reasons.append(
                f"store has {len(screenshots)} screenshot(s), "
                f"expected {expected_screenshot_count}"
            )
        elif any(not isinstance(url, str) or not url.strip() for url in screenshots):
            reasons.append("a tracked screenshot URL is missing")
    return reasons


def remote_download_url(item):
    download = item.get("download")
    if not isinstance(download, dict):
        return None
    url = download.get("url")
    if not isinstance(url, str) or not url.strip():
        return None
    return url


candidate_document = load_json(candidate_path, "candidate metadata")
candidate = controlled_fields(candidate_document, "candidate")

response_document = load_json(response_path, "store response")
if not isinstance(response_document, dict) or response_document.get("schema_version") != "1":
    fail("store response must use schema_version 1.")
data = response_document.get("data")
if not isinstance(data, dict) or "item" not in data:
    fail("store response must contain data.item.")
remote = controlled_fields(data["item"], "store item")
remote_document = data["item"]

if expect_icon_value not in {"0", "1"}:
    fail(f"invalid expected-icon flag {expect_icon_value!r}.")
try:
    expected_screenshot_count = int(expected_screenshot_count_value)
except ValueError:
    fail(f"invalid expected screenshot count {expected_screenshot_count_value!r}.")
if expected_screenshot_count < 0:
    fail("expected screenshot count cannot be negative.")

if remote["id"] != candidate["id"]:
    fail(f"store item id is {remote['id']!r}, expected {candidate['id']!r}.")

if mode == "preflight":
    ordering = compare_versions(candidate["version"], remote["version"])
    if ordering < 0:
        fail(
            f"store version {remote['version']} is newer than candidate "
            f"{candidate['version']}; refusing to move the current release backward."
        )
    if ordering > 0:
        print(f"upload\t{remote['version']}")
        raise SystemExit(0)

    mismatches = exact_mismatches(candidate, remote)
    if mismatches:
        fail("equal-version release differs: " + "; ".join(mismatches) + ".")

    recovery_reasons = media_recovery_reasons(remote_document)
    if remote_download_url(remote_document) is None:
        recovery_reasons.append("public artifact URL is missing")
    if recovery_reasons:
        print(f"recover\t{remote['version']}\t" + "; ".join(recovery_reasons))
        raise SystemExit(0)
    print(f"equal\t{remote['version']}")
    raise SystemExit(0)

if mode != "exact":
    fail(f"unknown comparison mode {mode!r}.")

mismatches = exact_mismatches(candidate, remote)
if mismatches:
    fail("release differs: " + "; ".join(mismatches) + ".")

media_mismatches = media_recovery_reasons(remote_document)
if media_mismatches:
    fail("release media differs: " + "; ".join(media_mismatches) + ".")
if remote_download_url(remote_document) is None:
    fail("store item.download.url must be a non-empty string.")
PY
}

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

snapshot_committed_file() {
  local WORKTREE_PATH="$1"
  local RELATIVE_PATH="${WORKTREE_PATH#$ROOT/}"
  local SNAPSHOT_PATH="$UPLOAD_SNAPSHOT_DIR/committed/$RELATIVE_PATH"

  /bin/mkdir -p "$(dirname "$SNAPSHOT_PATH")"
  git -C "$ROOT" show "$RELEASE_COMMIT:$RELATIVE_PATH" >"$SNAPSHOT_PATH"
  /bin/chmod 400 "$SNAPSHOT_PATH"
  printf '%s\n' "$SNAPSHOT_PATH"
}

EXPECT_ICON=0
EXPECT_SCREENSHOT_COUNT=0
ICON_PATH=""
if WORKTREE_ICON_PATH="$(find_icon_path)"; then
  ICON_PATH="$(snapshot_committed_file "$WORKTREE_ICON_PATH")"
  EXPECT_ICON=1
fi

collect_screenshot_paths
WORKTREE_SCREENSHOT_PATHS=()
if [[ ${#SCREENSHOT_PATHS[@]} -gt 0 ]]; then
  WORKTREE_SCREENSHOT_PATHS=("${SCREENSHOT_PATHS[@]}")
fi
SCREENSHOT_PATHS=()
if [[ ${#WORKTREE_SCREENSHOT_PATHS[@]} -gt 0 ]]; then
  for WORKTREE_SCREENSHOT_PATH in "${WORKTREE_SCREENSHOT_PATHS[@]}"; do
    SCREENSHOT_PATHS+=("$(snapshot_committed_file "$WORKTREE_SCREENSHOT_PATH")")
  done
fi
EXPECT_SCREENSHOT_COUNT="${#SCREENSHOT_PATHS[@]}"

if [[ ${#ARCHES[@]} -eq 0 ]]; then
  ARCHES=("arm64")
fi

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

store_download_url() {
  python3 - "$RESPONSE_BODY" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as fh:
    response = json.load(fh)
url = response.get("data", {}).get("item", {}).get("download", {}).get("url")
print(url if isinstance(url, str) else "")
PY
}

verify_public_artifact() {
  local URL="$1"
  local CONTEXT="$2"
  local HTTP_CODE

  case "$URL" in
    http://*|https://*) ;;
    *)
      echo "$CONTEXT has an invalid public artifact URL: $URL" >&2
      return 1
      ;;
  esac

  /bin/rm -f "$PUBLIC_ARTIFACT_PATH"
  if ! HTTP_CODE="$(
    curl \
      --disable \
      --silent \
      --show-error \
      --location \
      --proto '=http,https' \
      --proto-redir '=http,https' \
      "$URL" \
      -o "$PUBLIC_ARTIFACT_PATH" \
      -w "%{http_code}"
  )"; then
    echo "$CONTEXT download failed before receiving an HTTP response." >&2
    return 1
  fi

  if [[ ! "$HTTP_CODE" =~ ^[0-9]{3}$ ]]; then
    echo "$CONTEXT download returned an invalid HTTP status: $HTTP_CODE" >&2
    return 1
  fi
  if [[ ! "$HTTP_CODE" == 2?? ]]; then
    echo "$CONTEXT download failed with HTTP $HTTP_CODE." >&2
    return 1
  fi

  /bin/chmod 400 "$PUBLIC_ARTIFACT_PATH"
  python3 - "$ITEM_JSON_PATH" "$PUBLIC_ARTIFACT_PATH" "$CONTEXT" <<'PY'
import hashlib
import json
import os
import sys

item_path, artifact_path, context = sys.argv[1:]
with open(item_path, encoding="utf-8") as fh:
    expected = json.load(fh)["download"]

actual_size = os.path.getsize(artifact_path)
expected_size = expected["size_bytes"]
if actual_size != expected_size:
    raise SystemExit(
        f"{context} artifact size is {actual_size}, expected {expected_size}."
    )

digest = hashlib.sha256()
with open(artifact_path, "rb") as fh:
    for chunk in iter(lambda: fh.read(1024 * 1024), b""):
        digest.update(chunk)
actual_checksum = digest.hexdigest()
expected_checksum = expected["checksum_sha256"].lower()
if actual_checksum != expected_checksum:
    raise SystemExit(
        f"{context} artifact SHA-256 is {actual_checksum}, expected {expected_checksum}."
    )
PY
}

write_upload_auth_config() {
  local ESCAPED_TOKEN

  resolve_upload_token
  case "$TOKEN" in
    *$'\n'*|*$'\r'*)
      echo "RELEASE_UPLOAD_TOKEN must not contain a newline." >&2
      return 1
      ;;
  esac

  ESCAPED_TOKEN="${TOKEN//\\/\\\\}"
  ESCAPED_TOKEN="${ESCAPED_TOKEN//\"/\\\"}"
  printf 'header = "Authorization: Bearer %s"\n' "$ESCAPED_TOKEN" >"$AUTH_CURL_CONFIG"
  /bin/chmod 400 "$AUTH_CURL_CONFIG"
  TOKEN=""
}

fetch_public_item() {
  local CONTEXT="$1"
  local HTTP_CODE

  : >"$RESPONSE_BODY"
  if ! HTTP_CODE="$(
    curl \
      --disable \
      --silent \
      --show-error \
      "$API_URL/$ID" \
      -o "$RESPONSE_BODY" \
      -w "%{http_code}"
  )"; then
    echo "$CONTEXT failed before receiving an HTTP response." >&2
    print_response_body
    return 1
  fi

  if [[ ! "$HTTP_CODE" =~ ^[0-9]{3}$ ]]; then
    echo "$CONTEXT returned an invalid HTTP status: $HTTP_CODE" >&2
    print_response_body
    return 1
  fi

  printf '%s\n' "$HTTP_CODE"
}

ensure_paths_committed "$ROOT" "${RELEASE_INPUTS[@]}"
ensure_head_unchanged "$ROOT" "$RELEASE_COMMIT"
if [[ -n "$TAG" ]]; then
  ensure_tag_available_at_commit "$ROOT" "$TAG" "$RELEASE_COMMIT"
fi

if ! PREFLIGHT_HTTP_CODE="$(fetch_public_item "Store preflight")"; then
  exit 1
fi

case "$PREFLIGHT_HTTP_CODE" in
  404)
    RELEASE_ACTION="upload"
    echo "Store item $ID is not published; preparing its first release."
    ;;
  2??)
    if ! PREFLIGHT_RESULT="$(
      inspect_store_item \
        preflight \
        "Store preflight" \
        "$EXPECT_ICON" \
        "$EXPECT_SCREENSHOT_COUNT"
    )"; then
      exit 1
    fi
    IFS=$'\t' read -r RELEASE_ACTION STORE_VERSION RECOVERY_REASON <<<"$PREFLIGHT_RESULT"
    case "$RELEASE_ACTION" in
      upload)
        echo "Candidate $VERSION is newer than store version $STORE_VERSION."
        ;;
      recover)
        echo "Store release $ID $VERSION needs recovery: $RECOVERY_REASON."
        ;;
      equal)
        REMOTE_DOWNLOAD_URL="$(store_download_url)"
        if verify_public_artifact "$REMOTE_DOWNLOAD_URL" "Store preflight"; then
          echo "Store already has the exact verified $ID $VERSION release; skipping PUT."
        else
          RELEASE_ACTION="recover"
          echo "Store release $ID $VERSION has missing or mismatched public bytes; preparing recovery."
        fi
        ;;
      *)
        echo "Store preflight returned an unknown action: $RELEASE_ACTION" >&2
        exit 1
        ;;
    esac
    ;;
  *)
    echo "Store preflight failed with HTTP $PREFLIGHT_HTTP_CODE." >&2
    print_response_body
    exit 1
    ;;
esac

if [[ "$RELEASE_ACTION" == "upload" || "$RELEASE_ACTION" == "recover" ]]; then
  write_upload_auth_config

  CURL_ARGS=(
    --disable
    --silent
    --show-error
    -X PUT "$API_URL/$ID"
    --config "$AUTH_CURL_CONFIG"
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

  if [[ -n "$ICON_PATH" ]]; then
    echo "Using icon: $ICON_PATH"
    CURL_ARGS+=(--form "$(form_file_arg "store_item[icon]" "$ICON_PATH")")
  fi

  if [[ ${#SCREENSHOT_PATHS[@]} -gt 0 ]]; then
    echo "Using ${#SCREENSHOT_PATHS[@]} screenshot(s)"
    for SCREENSHOT_PATH in "${SCREENSHOT_PATHS[@]}"; do
      CURL_ARGS+=(--form "$(form_file_arg "store_item[screenshots][]" "$SCREENSHOT_PATH")")
    done
  fi

  CURL_ARGS+=(--form "$(form_file_arg "store_item[asset]" "$UPLOAD_PKG" "$(basename "$PKG")")")

  ensure_paths_committed "$ROOT" "${RELEASE_INPUTS[@]}"
  ensure_head_unchanged "$ROOT" "$RELEASE_COMMIT"
  if [[ -n "$TAG" ]]; then
    ensure_tag_available_at_commit "$ROOT" "$TAG" "$RELEASE_COMMIT"
  fi

  echo "Uploading $PKG → $API_URL/$ID ..."
  : >"$RESPONSE_BODY"
  if ! HTTP_CODE="$(curl "${CURL_ARGS[@]}" -o "$RESPONSE_BODY" -w "%{http_code}")"; then
    echo "Upload failed before receiving an HTTP response." >&2
    print_response_body
    exit 1
  fi

  if [[ ! "$HTTP_CODE" =~ ^[0-9]{3}$ ]]; then
    echo "Upload returned an invalid HTTP status: $HTTP_CODE" >&2
    print_response_body
    exit 1
  fi
  if [[ ! "$HTTP_CODE" == 2?? ]]; then
    echo "Upload failed with HTTP $HTTP_CODE." >&2
    print_response_body
    exit 1
  fi

  inspect_store_item exact "Upload response" "$EXPECT_ICON" "$EXPECT_SCREENSHOT_COUNT"
  python3 -m json.tool <"$RESPONSE_BODY"

  if ! READBACK_HTTP_CODE="$(fetch_public_item "Post-upload readback")"; then
    exit 1
  fi
  if [[ ! "$READBACK_HTTP_CODE" == 2?? ]]; then
    echo "Post-upload readback failed with HTTP $READBACK_HTTP_CODE." >&2
    print_response_body
    exit 1
  fi
  inspect_store_item exact "Post-upload readback" "$EXPECT_ICON" "$EXPECT_SCREENSHOT_COUNT"
  REMOTE_DOWNLOAD_URL="$(store_download_url)"
  if ! verify_public_artifact "$REMOTE_DOWNLOAD_URL" "Post-upload readback"; then
    exit 1
  fi
  echo "Verified public store release: $ID $VERSION"
fi

if [[ -n "$TAG" ]]; then
  create_annotated_tag "$ROOT" "$TAG" "$NAME $VERSION" "$RELEASE_COMMIT"
fi

echo "Done: $NAME $VERSION"
