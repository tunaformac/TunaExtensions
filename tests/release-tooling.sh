#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/tuna-extensions-tooling-tests.XXXXXX")"

cleanup() {
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

fail() {
  echo "release-tooling test failed: $*" >&2
  exit 1
}

expect_failure() {
  local label="$1"
  shift
  if "$@" >"$TMP_ROOT/failure.out" 2>"$TMP_ROOT/failure.err"; then
    fail "$label unexpectedly succeeded"
  fi
}

assert_no_temp_secrets() {
  local directory="$1"
  if find "$directory" \
    \( -name 'extensions-store-signing-key.*' -o -name 'tuna-extension-declaration.*' \) \
    -print -quit | grep -q .
  then
    fail "temporary declaration or signing key leaked in $directory"
  fi
}

REAL_OPENSSL=""
OPENSSL_CANDIDATES=(
  /opt/homebrew/opt/openssl@3/bin/openssl
  /opt/homebrew/bin/openssl
  /usr/local/opt/openssl@3/bin/openssl
  /usr/local/bin/openssl
)
if path_openssl="$(command -v openssl 2>/dev/null)"; then
  OPENSSL_CANDIDATES+=("$path_openssl")
fi
for candidate in "${OPENSSL_CANDIDATES[@]}"; do
  if [[ -x "$candidate" ]] && "$candidate" version 2>/dev/null | grep -Eq '^OpenSSL 3\.'; then
    REAL_OPENSSL="$candidate"
    break
  fi
done
[[ -n "$REAL_OPENSSL" ]] || fail "OpenSSL 3 is required"

PACKAGE_FIXTURE="$TMP_ROOT/package"
BUNDLE="$PACKAGE_FIXTURE/FixtureExtension.framework"
mkdir -p "$BUNDLE/Versions/A/Resources"
cp /usr/bin/true "$BUNDLE/Versions/A/FixtureExtension"
ln -s A "$BUNDLE/Versions/Current"
ln -s Versions/Current/FixtureExtension "$BUNDLE/FixtureExtension"
ln -s Versions/Current/Resources "$BUNDLE/Resources"

cat >"$BUNDLE/Versions/A/Resources/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>FixtureExtension</string>
  <key>CFBundleIdentifier</key>
  <string>com.example.fixture</string>
  <key>CFBundleName</key>
  <string>FixtureExtension</string>
  <key>CFBundlePackageType</key>
  <string>FMWK</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>15.0</string>
</dict>
</plist>
PLIST

DECLARATION="$PACKAGE_FIXTURE/declaration.json"
cat >"$DECLARATION" <<'JSON'
{
  "name": "Fixture Extension",
  "author": "Tuna Tests",
  "description": "Release tooling fixture.",
  "categories": ["must-not-be-inherited"],
  "compatibility": {
    "min_tuna": "0.78",
    "min_tunakit": "1.11.0"
  }
}
JSON

PACKAGE_OUT="$PACKAGE_FIXTURE/out"
python3 "$ROOT/scripts/package-tunaextension.py" \
  --bundle "$BUNDLE" \
  --out "$PACKAGE_OUT" \
  --declaration-json "$DECLARATION" \
  >"$PACKAGE_FIXTURE/item.json"

python3 - "$PACKAGE_FIXTURE/item.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as fh:
    item = json.load(fh)

assert item["categories"] == [], item["categories"]
assert item["compatibility"]["min_tuna"] == "0.78"
assert item["compatibility"]["min_tunakit"] == "1.11.0"
PY

python3 "$ROOT/scripts/package-tunaextension.py" \
  --bundle "$BUNDLE" \
  --out "$PACKAGE_OUT" \
  --declaration-json "$DECLARATION" \
  --category curated \
  >"$PACKAGE_FIXTURE/item-with-category.json"
python3 - "$PACKAGE_FIXTURE/item-with-category.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as fh:
    item = json.load(fh)

assert item["categories"] == ["curated"], item["categories"]
PY

cat >"$PACKAGE_FIXTURE/missing-min-tuna.json" <<'JSON'
{"name":"Fixture","author":"Tests","compatibility":{"min_tunakit":"1.11.0"}}
JSON
expect_failure "missing min_tuna" \
  python3 "$ROOT/scripts/package-tunaextension.py" \
    --bundle "$BUNDLE" \
    --out "$PACKAGE_OUT" \
    --declaration-json "$PACKAGE_FIXTURE/missing-min-tuna.json"
grep -q 'requires min_tuna' "$TMP_ROOT/failure.err" || fail "missing min_tuna error was unclear"

cat >"$PACKAGE_FIXTURE/missing-min-tunakit.json" <<'JSON'
{"name":"Fixture","author":"Tests","compatibility":{"min_tuna":"0.78"}}
JSON
expect_failure "missing min_tunakit" \
  python3 "$ROOT/scripts/package-tunaextension.py" \
    --bundle "$BUNDLE" \
    --out "$PACKAGE_OUT" \
    --declaration-json "$PACKAGE_FIXTURE/missing-min-tunakit.json"
grep -q 'requires min_tunakit' "$TMP_ROOT/failure.err" || fail "missing min_tunakit error was unclear"

cat >"$PACKAGE_FIXTURE/override-compatibility.json" <<'JSON'
{"name":"Fixture","author":"Tests"}
JSON
python3 "$ROOT/scripts/package-tunaextension.py" \
  --bundle "$BUNDLE" \
  --out "$PACKAGE_OUT" \
  --declaration-json "$PACKAGE_FIXTURE/override-compatibility.json" \
  --min-tuna 0.80 \
  --min-tunakit 1.11.1 \
  >"$PACKAGE_FIXTURE/item-with-overrides.json"
python3 - "$PACKAGE_FIXTURE/item-with-overrides.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as fh:
    compatibility = json.load(fh)["compatibility"]

assert compatibility["min_tuna"] == "0.80", compatibility
assert compatibility["min_tunakit"] == "1.11.1", compatibility
PY

mkdir -p "$PACKAGE_FIXTURE/outside-directory"
ln -s "$PACKAGE_FIXTURE/outside-directory" "$BUNDLE/EscapingDirectory"
expect_failure "escaping directory symlink" \
  python3 "$ROOT/scripts/package-tunaextension.py" \
    --bundle "$BUNDLE" \
    --out "$PACKAGE_OUT" \
    --declaration-json "$DECLARATION"
grep -q 'Symlink escapes bundle' "$TMP_ROOT/failure.err" || \
  fail "escaping directory symlink error was unclear"
rm "$BUNDLE/EscapingDirectory"

mkdir -p "$PACKAGE_FIXTURE/FixtureExtension.framework-evil"
printf 'outside\n' >"$PACKAGE_FIXTURE/FixtureExtension.framework-evil/value"
ln -s ../FixtureExtension.framework-evil/value "$BUNDLE/PrefixCollision"
expect_failure "prefix-collision symlink" \
  python3 "$ROOT/scripts/package-tunaextension.py" \
    --bundle "$BUNDLE" \
    --out "$PACKAGE_OUT" \
    --declaration-json "$DECLARATION"
grep -q 'Symlink escapes bundle' "$TMP_ROOT/failure.err" || \
  fail "prefix-collision symlink error was unclear"
rm "$BUNDLE/PrefixCollision"

# This target is inside the source bundle, but the absolute link would point
# outside the copied bundle in package staging and must therefore be rejected.
ln -s "$BUNDLE/Versions/A/Resources" "$BUNDLE/AbsoluteInBundleDirectory"
expect_failure "absolute in-bundle directory symlink" \
  python3 "$ROOT/scripts/package-tunaextension.py" \
    --bundle "$BUNDLE" \
    --out "$PACKAGE_OUT" \
    --declaration-json "$DECLARATION"
grep -q 'Symlink escapes bundle' "$TMP_ROOT/failure.err" || \
  fail "absolute in-bundle directory symlink error was unclear"
rm "$BUNDLE/AbsoluteInBundleDirectory"

/usr/bin/codesign --force --sign - --timestamp=none "$BUNDLE" >/dev/null
/usr/bin/codesign --verify --strict "$BUNDLE"

SIGNING_FIXTURE="$TMP_ROOT/signing"
SIGNING_ROOT="$SIGNING_FIXTURE/repo"
SIGNING_BIN="$SIGNING_FIXTURE/bin"
SIGNING_TMP="$SIGNING_FIXTURE/tmp"
mkdir -p "$SIGNING_ROOT/scripts" "$SIGNING_BIN" "$SIGNING_TMP"
cp "$ROOT/scripts/ext-package.sh" "$SIGNING_ROOT/scripts/"
cp "$ROOT/scripts/package-tunaextension.py" "$SIGNING_ROOT/scripts/"

cat >"$SIGNING_ROOT/scripts/build-extension-product.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$FAKE_BUNDLE"
SH

cat >"$SIGNING_BIN/tuna" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
cat <<'JSON'
{
  "name": "Fixture Extension",
  "author": "Tuna Tests",
  "description": "Release tooling fixture.",
  "categories": ["must-not-be-inherited"],
  "compatibility": {
    "min_tuna": "0.78",
    "min_tunakit": "1.11.0"
  }
}
JSON
SH

cat >"$SIGNING_BIN/op" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[[ "${FAKE_OP_FAIL:-0}" != "1" ]] || exit 1
[[ "${1:-}" == "read" ]]
cat "$FAKE_SIGNING_KEY"
if [[ -n "${FAKE_OP_READY:-}" ]]; then
  : >"$FAKE_OP_READY"
  while [[ ! -f "$FAKE_OP_RELEASE" ]]; do
    sleep 0.05
  done
fi
SH

cat >"$SIGNING_BIN/openssl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
key_path=""
previous=""
for argument in "$@"; do
  if [[ "$previous" == "-inkey" ]]; then
    key_path="$argument"
    break
  fi
  previous="$argument"
done
if [[ -n "$key_path" ]]; then
  /usr/bin/stat -f '%Lp' "$key_path" >"$SIGNING_MODE_LOG"
fi
exec "$REAL_OPENSSL" "$@"
SH

chmod +x \
  "$SIGNING_ROOT/scripts/build-extension-product.sh" \
  "$SIGNING_BIN/tuna" \
  "$SIGNING_BIN/op" \
  "$SIGNING_BIN/openssl"

FAKE_SIGNING_KEY="$SIGNING_FIXTURE/signing-key.pem"
"$REAL_OPENSSL" genpkey -algorithm ED25519 -out "$FAKE_SIGNING_KEY" 2>/dev/null
SIGNING_MODE_LOG="$SIGNING_FIXTURE/signing-mode"

env \
  PATH="$SIGNING_BIN:$PATH" \
  FAKE_BUNDLE="$BUNDLE" \
  FAKE_SIGNING_KEY="$FAKE_SIGNING_KEY" \
  REAL_OPENSSL="$REAL_OPENSSL" \
  SIGNING_MODE_LOG="$SIGNING_MODE_LOG" \
  OPENSSL="$SIGNING_BIN/openssl" \
  TUNA_BINARY="$SIGNING_BIN/tuna" \
  TMPDIR="$SIGNING_TMP" \
  EXTENSIONS_STORE_SIGNING_PRIVATE_KEY_OP='fake://signing-key' \
  "$SIGNING_ROOT/scripts/ext-package.sh" FixtureExtension generic/platform=macOS "$SIGNING_ROOT/build/dd" \
  >"$SIGNING_FIXTURE/item.json"

[[ "$(cat "$SIGNING_MODE_LOG")" == "600" ]] || fail "temporary signing key was not mode 600"
assert_no_temp_secrets "$SIGNING_TMP"
python3 - "$SIGNING_FIXTURE/item.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as fh:
    item = json.load(fh)

assert item["download"]["signature"]["algorithm"] == "ed25519"
assert item["categories"] == []
PY

expect_failure "failed signing-key provider" env \
  PATH="$SIGNING_BIN:$PATH" \
  FAKE_BUNDLE="$BUNDLE" \
  FAKE_SIGNING_KEY="$FAKE_SIGNING_KEY" \
  FAKE_OP_FAIL=1 \
  TUNA_BINARY="$SIGNING_BIN/tuna" \
  TMPDIR="$SIGNING_TMP" \
  EXTENSIONS_STORE_SIGNING_PRIVATE_KEY_OP='fake://signing-key' \
  "$SIGNING_ROOT/scripts/ext-package.sh" FixtureExtension generic/platform=macOS "$SIGNING_ROOT/build/dd"
assert_no_temp_secrets "$SIGNING_TMP"

signal_ready="$SIGNING_FIXTURE/op-ready"
signal_release="$SIGNING_FIXTURE/op-release"
env \
  PATH="$SIGNING_BIN:$PATH" \
  FAKE_BUNDLE="$BUNDLE" \
  FAKE_SIGNING_KEY="$FAKE_SIGNING_KEY" \
  FAKE_OP_READY="$signal_ready" \
  FAKE_OP_RELEASE="$signal_release" \
  TUNA_BINARY="$SIGNING_BIN/tuna" \
  TMPDIR="$SIGNING_TMP" \
  EXTENSIONS_STORE_SIGNING_PRIVATE_KEY_OP='fake://signing-key' \
  "$SIGNING_ROOT/scripts/ext-package.sh" FixtureExtension generic/platform=macOS "$SIGNING_ROOT/build/dd" \
  >"$SIGNING_FIXTURE/signal.out" 2>"$SIGNING_FIXTURE/signal.err" &
signal_pid=$!
for _attempt in {1..100}; do
  [[ -f "$signal_ready" ]] && break
  sleep 0.05
done
[[ -f "$signal_ready" ]] || fail "slow signing-key provider did not become ready"
find "$SIGNING_TMP" -name 'extensions-store-signing-key.*' -print -quit | grep -q . || \
  fail "slow signing-key provider never created its temp key"
kill -TERM "$signal_pid"
: >"$signal_release"
set +e
wait "$signal_pid"
signal_status=$?
set -e
[[ $signal_status -ne 0 ]] || fail "TERM did not stop packaging"
assert_no_temp_secrets "$SIGNING_TMP"

WRAPPER_ROOT="$TMP_ROOT/wrapper"
mkdir -p "$WRAPPER_ROOT/scripts"
cp "$ROOT/scripts/tuna-extension" "$WRAPPER_ROOT/scripts/"
cat >"$WRAPPER_ROOT/scripts/ext-package.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$EXTENSIONS_STORE_SIGNING_PRIVATE_KEY_OP" >"$WRAPPER_LOG"
SH
chmod +x "$WRAPPER_ROOT/scripts/ext-package.sh"

WRAPPER_LOG="$WRAPPER_ROOT/default-provider"
env WRAPPER_LOG="$WRAPPER_LOG" \
  "$WRAPPER_ROOT/scripts/tuna-extension" package --scheme FixtureExtension
grep -Fxq 'op://Brainbow/Tuna/EXTENSIONS_STORE_SIGNING_PRIVATE_KEY' "$WRAPPER_LOG" || \
  fail "package command did not provide the default signing key provider"

WRAPPER_LOG="$WRAPPER_ROOT/override-provider"
env \
  WRAPPER_LOG="$WRAPPER_LOG" \
  EXTENSIONS_STORE_SIGNING_PRIVATE_KEY_OP='fake://override' \
  "$WRAPPER_ROOT/scripts/tuna-extension" package --scheme FixtureExtension
grep -Fxq 'fake://override' "$WRAPPER_LOG" || fail "package command discarded signing override"

SIGNED_ITEM="$SIGNING_FIXTURE/item.json"
SIGNED_PACKAGE="$SIGNING_ROOT/dist/store/com.example.fixture-1.0.tunaextension"
[[ -f "$SIGNED_PACKAGE" ]] || fail "signed upload fixture was not packaged"

UNSIGNED_FIXTURE="$TMP_ROOT/unsigned-upload-fixture"
mkdir -p "$UNSIGNED_FIXTURE/out"
python3 "$ROOT/scripts/package-tunaextension.py" \
  --bundle "$BUNDLE" \
  --out "$UNSIGNED_FIXTURE/out" \
  --declaration-json "$DECLARATION" \
  >"$UNSIGNED_FIXTURE/item.json"
UNSIGNED_ITEM="$UNSIGNED_FIXTURE/item.json"
UNSIGNED_PACKAGE="$UNSIGNED_FIXTURE/out/com.example.fixture-1.0.tunaextension"

UPLOAD_ROOT="$TMP_ROOT/upload/repo"
UPLOAD_BIN="$TMP_ROOT/upload/bin"
UPLOAD_RUN_DIR="$TMP_ROOT/upload/outside-repo"
UPLOAD_TMP="$TMP_ROOT/upload/tmp"
mkdir -p \
  "$UPLOAD_ROOT/scripts" \
  "$UPLOAD_ROOT/FixtureExtension/FixtureExtension.xcodeproj" \
  "$UPLOAD_BIN" \
  "$UPLOAD_RUN_DIR" \
  "$UPLOAD_TMP"
cp "$ROOT/scripts/upload-extension.sh" "$UPLOAD_ROOT/scripts/"
cp "$ROOT/scripts/release-extension.sh" "$UPLOAD_ROOT/scripts/"
cp "$ROOT/scripts/extension-release-state.py" "$UPLOAD_ROOT/scripts/"
cp "$ROOT/scripts/git-tag-helpers.sh" "$UPLOAD_ROOT/scripts/"
cp "$ROOT/scripts/resolve-extension-scheme.sh" "$UPLOAD_ROOT/scripts/"

cat >"$UPLOAD_ROOT/FixtureExtension/FixtureExtension.xcodeproj/project.pbxproj" <<'EOF'
// fixture project
EOF
cat >"$UPLOAD_ROOT/FixtureExtension/Info.plist" <<'EOF'
fixture info
EOF
cat >"$UPLOAD_ROOT/FixtureExtension/FixtureExtension.swift" <<'EOF'
// fixture source
EOF
cat >"$UPLOAD_ROOT/Makefile" <<'EOF'
# The test places a fake make executable first on PATH.
EOF
cat >"$UPLOAD_ROOT/.gitignore" <<'EOF'
dist/
curl.log
EOF

cat >"$UPLOAD_BIN/xcodebuild" <<'SH'
#!/usr/bin/env bash
cat <<'EOF'
Information about project "FixtureExtension":
    Schemes:
        FixtureExtension

EOF
SH

cat >"$UPLOAD_BIN/make" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[[ -z "${RELEASE_UPLOAD_TOKEN:-}" && -z "${TOKEN:-}" ]] || {
  echo "packaging inherited an upload token" >&2
  exit 1
}
if [[ "${1:-}" == "-C" ]]; then
  cd "$2"
  shift 2
fi
[[ "${1:-}" == "ext-package" ]]
pwd -P >"$MAKE_CWD_LOG"
printf 'called\n' >>"$MAKE_COUNT_LOG"

if [[ "${FAKE_MAKE_DIRTY:-0}" == "1" ]]; then
  printf 'changed during packaging\n' >>FixtureExtension/Info.plist
fi

mkdir -p dist/store
candidate_version="${FAKE_CANDIDATE_VERSION:-1.0}"
package_path="dist/store/com.example.fixture-${candidate_version}.tunaextension"
mode="${FAKE_ARTIFACT_MODE:-signed}"

emit_signed_item() {
  python3 - \
    "$FAKE_SIGNED_ITEM" \
    "$package_path" \
    "$candidate_version" \
    "${FAKE_NULL_TUNAKIT:-0}" \
    "${FAKE_CHANGING_PACKAGE:-0}" <<'PY'
import hashlib
import json
import os
import sys

item_path, package_path, version, null_tunakit, changing_package = sys.argv[1:]
with open(item_path, encoding="utf-8") as fh:
    item = json.load(fh)
item["version"] = version
if null_tunakit == "1":
    item["compatibility"]["min_tunakit"] = None
if changing_package == "1":
    digest = hashlib.sha256()
    with open(package_path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1024 * 1024), b""):
            digest.update(chunk)
    item["download"]["size_bytes"] = os.path.getsize(package_path)
    item["download"]["checksum_sha256"] = digest.hexdigest()
print(json.dumps(item))
PY
}

case "$mode" in
  signed|mutated)
    cp "$FAKE_SIGNED_PACKAGE" "$package_path"
    if [[ "$mode" == "mutated" ]]; then
      printf 'mutation\n' >>"$package_path"
    fi
    if [[ "${FAKE_CHANGING_PACKAGE:-0}" == "1" ]]; then
      printf 'package-run-%s\n' "$(wc -l <"$MAKE_COUNT_LOG" | tr -d ' ')" >>"$package_path"
    fi
    emit_signed_item
    ;;
  unsigned)
    cp "$FAKE_UNSIGNED_PACKAGE" "$package_path"
    cat "$FAKE_UNSIGNED_ITEM"
    ;;
  missing-signature|corrupt|signature-mismatch)
    cp "$FAKE_SIGNED_PACKAGE" "$package_path"
    python3 - "$package_path" "$FAKE_SIGNED_ITEM" "$mode" <<'PY'
import hashlib
import json
import os
import sys
import tempfile
import zipfile

package_path, item_path, mode = sys.argv[1:]

if mode == "corrupt":
    with open(package_path, "wb") as fh:
        fh.write(b"not a zip archive\n")
else:
    descriptor, replacement_path = tempfile.mkstemp(suffix=".tunaextension")
    os.close(descriptor)
    try:
        with zipfile.ZipFile(package_path) as source, zipfile.ZipFile(
            replacement_path, "w"
        ) as destination:
            for info in source.infolist():
                if info.filename == "store-signature.json":
                    if mode == "missing-signature":
                        continue
                    signature = json.loads(source.read(info))
                    signature["key_id"] = "mismatched-key"
                    destination.writestr(info, json.dumps(signature, sort_keys=True))
                else:
                    destination.writestr(info, source.read(info.filename))
        os.replace(replacement_path, package_path)
    finally:
        if os.path.exists(replacement_path):
            os.unlink(replacement_path)

with open(item_path, encoding="utf-8") as fh:
    item = json.load(fh)

digest = hashlib.sha256()
with open(package_path, "rb") as fh:
    for chunk in iter(lambda: fh.read(1024 * 1024), b""):
        digest.update(chunk)
item["download"]["size_bytes"] = os.path.getsize(package_path)
item["download"]["checksum_sha256"] = digest.hexdigest()
print(json.dumps(item))
PY
    ;;
  *)
    echo "Unknown fake artifact mode: $mode" >&2
    exit 1
    ;;
esac
SH

cat >"$UPLOAD_BIN/curl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" == "--disable" ]] || {
  echo "curl did not disable the ambient curlrc as its first argument" >&2
  exit 1
}
[[ -z "${RELEASE_UPLOAD_TOKEN:-}" && -z "${TOKEN:-}" ]] || {
  echo "curl inherited an upload token" >&2
  exit 1
}
method="GET"
response_path=""
request_url=""
config_path=""
follow_redirects=0
authorization_argument=0
text_forms=()
file_fields=()
file_paths=()
args=("$@")
while [[ $# -gt 0 ]]; do
  case "$1" in
    -X|--request) method="$2"; shift 2 ;;
    --disable) shift ;;
    -o|--output) response_path="$2"; shift 2 ;;
    -w|--write-out|--proto|--proto-redir) shift 2 ;;
    -L|--location) follow_redirects=1; shift ;;
    -K|--config) config_path="$2"; shift 2 ;;
    -H|--header)
      [[ "$2" == Authorization:* ]] && authorization_argument=1
      shift 2
      ;;
    --form-string)
      text_forms+=("$2")
      shift 2
      ;;
    --form|-F)
      form_value="$2"
      [[ "$form_value" == *=@* ]] || {
        echo "text metadata used curl file-form semantics: $form_value" >&2
        exit 1
      }
      field="${form_value%%=*}"
      file_value="${form_value#*=@}"
      file_path="${file_value%%;*}"
      [[ -f "$file_path" ]] || {
        echo "curl form file does not exist: $file_path" >&2
        exit 1
      }
      file_fields+=("$field")
      file_paths+=("$file_path")
      shift 2
      ;;
    http://*|https://*) request_url="$1"; shift ;;
    *) shift ;;
  esac
done
[[ -n "$response_path" ]]

API_ITEM_URL='https://invalid.example.test/api/v1/items/com.example.fixture'
ARTIFACT_URL='https://invalid.example.test/download/items/com.example.fixture'
mode="${FAKE_STORE_MODE:-greater}"
state_item="$FAKE_STORE_STATE_DIR/item.json"
state_artifact="$FAKE_STORE_STATE_DIR/artifact.tunaextension"

write_fixture_response() {
  local version="$1"
  local mutation="${2:-none}"
  local include_icon="${3:-0}"
  local included_screenshot_count="${4:-0}"
  local include_download_url="${5:-1}"
  python3 - \
    "$FAKE_SIGNED_ITEM" \
    "$response_path" \
    "$version" \
    "$mutation" \
    "$include_icon" \
    "$included_screenshot_count" \
    "$include_download_url" \
    "${FAKE_NULL_TUNAKIT:-0}" <<'PY'
import copy
import json
import sys

(
    item_path,
    response_path,
    version,
    mutation,
    include_icon,
    included_screenshot_count,
    include_download_url,
    null_tunakit,
) = sys.argv[1:]
with open(item_path, encoding="utf-8") as fh:
    item = copy.deepcopy(json.load(fh))

item["version"] = version
if null_tunakit == "1":
    item["compatibility"]["min_tunakit"] = None
if mutation == "listing":
    item["summary"] = "Unexpected store summary."
elif mutation == "checksum":
    item["download"]["checksum_sha256"] = "0" * 64
elif mutation != "none":
    raise SystemExit(f"unknown fake store mutation: {mutation}")

if include_icon == "1":
    item["icon_url"] = "https://invalid.example.test/icon.png"
if int(included_screenshot_count):
    item["screenshots"] = [
        f"https://invalid.example.test/screenshot-{index}.png"
        for index in range(int(included_screenshot_count))
    ]
item["download"]["url"] = (
    "https://invalid.example.test/download/items/com.example.fixture"
    if include_download_url == "1"
    else None
)

with open(response_path, "w", encoding="utf-8") as fh:
    json.dump({"schema_version": "1", "data": {"item": item}}, fh)
    fh.write("\n")
PY
}

mutate_response() {
  local source_path="$1"
  local mutation="$2"
  python3 - "$source_path" "$response_path" "$mutation" <<'PY'
import json
import sys

source_path, response_path, mutation = sys.argv[1:]
with open(source_path, encoding="utf-8") as fh:
    response = json.load(fh)
item = response["data"]["item"]
if mutation == "checksum":
    item["download"]["checksum_sha256"] = "0" * 64
elif mutation == "screenshots":
    item.pop("screenshots", None)
elif mutation == "icon":
    item["icon_url"] = None
elif mutation == "download-url":
    item["download"]["url"] = None
else:
    raise SystemExit(f"unknown response mutation: {mutation}")
with open(response_path, "w", encoding="utf-8") as fh:
    json.dump(response, fh)
    fh.write("\n")
PY
}

reject_public_auth() {
  [[ "$authorization_argument" == "0" ]] || {
    echo "public request exposed Authorization in argv" >&2
    exit 1
  }
  [[ -z "$config_path" ]] || {
    echo "public request used the private curl config" >&2
    exit 1
  }
}

if [[ "$method" == "GET" && "$request_url" == "$API_ITEM_URL" ]]; then
  reject_public_auth
  printf 'called\n' >>"$GET_LOG"

  if [[ -f "$state_item" ]]; then
    case "$mode" in
      readback-network-error)
        echo 'simulated readback connection failure' >&2
        exit 7
        ;;
      readback-server-error)
        printf '{"schema_version":"1","errors":[{"detail":"unavailable"}]}\n' >"$response_path"
        printf '503'
        exit 0
        ;;
      readback-invalid-json)
        printf 'not json\n' >"$response_path"
        printf '200'
        exit 0
        ;;
      readback-invalid-schema)
        printf '{"schema_version":"2","data":{}}\n' >"$response_path"
        printf '200'
        exit 0
        ;;
      readback-not-found)
        printf '{"schema_version":"1","errors":[{"detail":"not found"}]}\n' >"$response_path"
        printf '404'
        exit 0
        ;;
      wrong-readback) mutate_response "$state_item" checksum ;;
      wrong-media-readback) mutate_response "$state_item" icon ;;
      readback-missing-url) mutate_response "$state_item" download-url ;;
      *) /bin/cp "$state_item" "$response_path" ;;
    esac
    printf '200'
    exit 0
  fi

  case "$mode" in
    absent)
      printf '{"schema_version":"1","errors":[{"detail":"not found"}]}\n' >"$response_path"
      printf '404'
      ;;
    greater|wrong-response|wrong-readback|wrong-media-response|wrong-media-readback|\
      put-network-error|put-server-error|put-invalid-json|put-invalid-schema|\
      readback-network-error|readback-server-error|readback-invalid-json|\
      readback-invalid-schema|readback-not-found|readback-missing-url|\
      post-artifact-missing|post-artifact-bad|post-artifact-network|\
      mutate-media|null-tunakit)
      write_fixture_response 0.9
      printf '200'
      ;;
    greater-minor)
      write_fixture_response 1.9
      printf '200'
      ;;
    lower)
      write_fixture_response 2.0
      printf '200'
      ;;
    equal-exact)
      write_fixture_response "${FAKE_CANDIDATE_VERSION:-1.0}"
      printf '200'
      ;;
    equal-version-alias)
      write_fixture_response 1.0.0
      printf '200'
      ;;
    equal-drift)
      write_fixture_response "${FAKE_CANDIDATE_VERSION:-1.0}" listing
      printf '200'
      ;;
    equal-artifact-missing|equal-artifact-bad)
      write_fixture_response "${FAKE_CANDIDATE_VERSION:-1.0}"
      printf '200'
      ;;
    equal-media-missing)
      write_fixture_response "${FAKE_CANDIDATE_VERSION:-1.0}" none 0 0
      printf '200'
      ;;
    equal-url-missing)
      write_fixture_response "${FAKE_CANDIDATE_VERSION:-1.0}" none 0 0 0
      printf '200'
      ;;
    invalid-json)
      printf 'not json\n' >"$response_path"
      printf '200'
      ;;
    invalid-schema)
      printf '{"schema_version":"2","data":{}}\n' >"$response_path"
      printf '200'
      ;;
    server-error)
      printf '{"schema_version":"1","errors":[{"detail":"unavailable"}]}\n' >"$response_path"
      printf '503'
      ;;
    network-error)
      echo 'simulated connection failure' >&2
      exit 7
      ;;
    *)
      echo "Unknown fake store mode: $mode" >&2
      exit 1
      ;;
  esac
  exit 0
fi

if [[ "$method" == "GET" && "$request_url" == "$ARTIFACT_URL" ]]; then
  reject_public_auth
  [[ "$follow_redirects" == "1" ]] || {
    echo "public artifact request did not follow redirects" >&2
    exit 1
  }
  printf 'called\n' >>"$DOWNLOAD_LOG"

  if [[ -f "$state_artifact" ]]; then
    case "$mode" in
      post-artifact-network)
        echo 'simulated artifact connection failure' >&2
        exit 7
        ;;
      post-artifact-missing)
        printf 'missing\n' >"$response_path"
        printf '404'
        ;;
      post-artifact-bad)
        printf 'wrong public bytes\n' >"$response_path"
        printf '200'
        ;;
      *)
        /bin/cp "$state_artifact" "$response_path"
        printf '200'
        ;;
    esac
    exit 0
  fi

  case "$mode" in
    equal-exact)
      /bin/cp "$FAKE_SIGNED_PACKAGE" "$response_path"
      printf '200'
      ;;
    equal-artifact-missing)
      printf 'missing\n' >"$response_path"
      printf '404'
      ;;
    equal-artifact-bad)
      printf 'wrong public bytes\n' >"$response_path"
      printf '200'
      ;;
    *)
      echo "unexpected preflight artifact request in mode $mode" >&2
      exit 1
      ;;
  esac
  exit 0
fi

[[ "$method" == "PUT" ]] || {
  echo "unexpected fake curl request: $method $request_url" >&2
  exit 1
}
printf 'called\n' >>"$CURL_LOG"
: >"$CURL_ARGS_LOG"
: >"$MEDIA_LOG"
: >"$MEDIA_HASH_LOG"
printf '%s\n' "${args[@]}" >"$CURL_ARGS_LOG"
[[ "$request_url" == "$API_ITEM_URL" ]] || {
  echo "PUT used the wrong API URL: $request_url" >&2
  exit 1
}
[[ "$authorization_argument" == "0" ]] || {
  echo "PUT exposed Authorization in process argv" >&2
  exit 1
}
[[ -n "$config_path" && -f "$config_path" ]] || {
  echo "PUT did not provide a curl auth config" >&2
  exit 1
}
config_mode="$(/usr/bin/stat -f '%Lp' "$config_path")"
[[ "$config_mode" == "400" || "$config_mode" == "600" ]] || {
  echo "curl auth config has unsafe mode $config_mode" >&2
  exit 1
}
grep -Fxq 'header = "Authorization: Bearer fake-token"' "$config_path" || {
  echo "curl auth config did not contain the expected bearer header" >&2
  exit 1
}
if grep -Fq 'fake-token' "$CURL_ARGS_LOG"; then
  echo "bearer token leaked into curl argv" >&2
  exit 1
fi

case "$mode" in
  put-network-error)
    echo 'simulated PUT connection failure' >&2
    exit 7
    ;;
  put-server-error)
    printf '{"schema_version":"1","errors":[{"detail":"unavailable"}]}\n' >"$response_path"
    printf '503'
    exit 0
    ;;
esac

asset_path=""
icon_count=0
screenshot_count=0
for ((index = 0; index < ${#file_fields[@]}; index++)); do
  field="${file_fields[$index]}"
  file_path="${file_paths[$index]}"
  case "$field" in
    'store_item[asset]')
      [[ -z "$asset_path" ]] || {
        echo "curl received multiple package assets" >&2
        exit 1
      }
      asset_path="$file_path"
      ;;
    'store_item[icon]') icon_count=$((icon_count + 1)) ;;
    'store_item[screenshots][]') screenshot_count=$((screenshot_count + 1)) ;;
    *)
      echo "curl received unexpected file field: $field" >&2
      exit 1
      ;;
  esac

  [[ "$file_path" != "$EXPECTED_UPLOAD_ROOT"/* ]] || {
    echo "curl received a mutable worktree path: $file_path" >&2
    exit 1
  }
  [[ "$(/usr/bin/stat -f '%Lp' "$file_path")" == "400" ]] || {
    echo "upload snapshot file is writable: $file_path" >&2
    exit 1
  }
  [[ "$(/usr/bin/stat -f '%Lp' "$(dirname "$file_path")")" == "700" ]] || {
    echo "upload snapshot directory is not private: $file_path" >&2
    exit 1
  }

  if [[ "$field" != 'store_item[asset]' ]]; then
    printf '%s\n' "$file_path" >>"$MEDIA_LOG"
  fi
done

[[ -n "$asset_path" ]] || {
  echo "curl received no package asset" >&2
  exit 1
}
[[ "$icon_count" -le 1 ]] || {
  echo "curl received multiple icons" >&2
  exit 1
}

if [[ "${FAKE_CURL_MUTATE_MEDIA:-0}" == "1" ]]; then
  printf 'mutated during curl\n' >"$FAKE_MUTATE_MEDIA_PATH"
fi

for ((index = 0; index < ${#file_fields[@]}; index++)); do
  field="${file_fields[$index]}"
  file_path="${file_paths[$index]}"
  if [[ "$field" != 'store_item[asset]' ]]; then
    printf '%s\t%s\t%s\n' \
      "$field" \
      "$file_path" \
      "$(git hash-object "$file_path")" >>"$MEDIA_HASH_LOG"
  fi
done

forms_path="$FAKE_STORE_STATE_DIR/forms.txt"
: >"$forms_path"
if [[ ${#text_forms[@]} -gt 0 ]]; then
  printf '%s\n' "${text_forms[@]}" >"$forms_path"
fi
printf '%s\n' "$asset_path" >"$ASSET_PATH_LOG"

python3 - \
  "$FAKE_SIGNED_ITEM" \
  "$forms_path" \
  "$asset_path" \
  "$state_item" \
  "${FAKE_CANDIDATE_VERSION:-1.0}" \
  "${FAKE_NULL_TUNAKIT:-0}" \
  "$icon_count" \
  "$screenshot_count" <<'PY'
import hashlib
import json
import os
import sys

(
    candidate_path,
    forms_path,
    asset_path,
    state_path,
    candidate_version,
    null_tunakit,
    icon_count_value,
    screenshot_count_value,
) = sys.argv[1:]

with open(candidate_path, encoding="utf-8") as fh:
    candidate = json.load(fh)
candidate["version"] = candidate_version
if null_tunakit == "1":
    candidate["compatibility"]["min_tunakit"] = None

forms = {}
with open(forms_path, encoding="utf-8") as fh:
    for line in fh:
        key, value = line.rstrip("\n").split("=", 1)
        forms.setdefault(key, []).append(value)

expected_scalars = {
    "store_item[name]": candidate["name"],
    "store_item[summary]": candidate["summary"],
    "store_item[item_type]": candidate["type"],
    "store_item[version]": candidate["version"],
    "store_item[developer_name]": candidate["developer_name"],
    "store_item[compatibility_min_tuna]": candidate["compatibility"]["min_tuna"],
    "store_item[compatibility_min_macos]": candidate["compatibility"]["min_macos"],
}
min_tunakit = candidate["compatibility"].get("min_tunakit")
if min_tunakit is not None:
    expected_scalars["store_item[compatibility_min_tunakit]"] = min_tunakit

expected_keys = set(expected_scalars) | {"store_item[compatibility_arch][]"}
if set(forms) != expected_keys:
    raise SystemExit(
        f"multipart metadata fields are {sorted(forms)}, expected {sorted(expected_keys)}"
    )
for key, expected in expected_scalars.items():
    if forms[key] != [expected]:
        raise SystemExit(f"multipart {key} is {forms[key]!r}, expected {[expected]!r}")
if sorted(forms["store_item[compatibility_arch][]"]) != sorted(
    candidate["compatibility"]["arch"]
):
    raise SystemExit("multipart architectures do not match candidate metadata")

digest = hashlib.sha256()
with open(asset_path, "rb") as fh:
    for chunk in iter(lambda: fh.read(1024 * 1024), b""):
        digest.update(chunk)

icon_count = int(icon_count_value)
screenshot_count = int(screenshot_count_value)
item = {
    "id": candidate["id"],
    "type": forms["store_item[item_type]"][0],
    "name": forms["store_item[name]"][0],
    "summary": forms["store_item[summary]"][0],
    "developer_name": forms["store_item[developer_name]"][0],
    "icon_url": (
        "https://invalid.example.test/icon.png" if icon_count else None
    ),
    "screenshots": [
        f"https://invalid.example.test/screenshot-{index}.png"
        for index in range(screenshot_count)
    ],
    "version": forms["store_item[version]"][0],
    "compatibility": {
        "min_tuna": forms["store_item[compatibility_min_tuna]"][0],
        "min_tunakit": (
            forms["store_item[compatibility_min_tunakit]"][0]
            if "store_item[compatibility_min_tunakit]" in forms
            else None
        ),
        "min_macos": forms["store_item[compatibility_min_macos]"][0],
        "arch": forms["store_item[compatibility_arch][]"],
    },
    "download": {
        "url": "https://invalid.example.test/download/items/com.example.fixture",
        "size_bytes": os.path.getsize(asset_path),
        "checksum_sha256": digest.hexdigest(),
    },
}
with open(state_path, "w", encoding="utf-8") as fh:
    json.dump({"schema_version": "1", "data": {"item": item}}, fh)
    fh.write("\n")
PY

/bin/cp "$asset_path" "$state_artifact"
if [[ "${FAKE_CURL_ADVANCE_HEAD:-0}" == "1" ]]; then
  printf 'advanced during curl\n' >"$EXPECTED_UPLOAD_ROOT/head-changed-during-curl.txt"
  git -C "$EXPECTED_UPLOAD_ROOT" add head-changed-during-curl.txt
  git -C "$EXPECTED_UPLOAD_ROOT" commit -qm 'Advance HEAD during fake curl'
fi

case "$mode" in
  put-invalid-json) printf 'not json\n' >"$response_path" ;;
  put-invalid-schema) printf '{"schema_version":"2","data":{}}\n' >"$response_path" ;;
  wrong-response) mutate_response "$state_item" checksum ;;
  wrong-media-response) mutate_response "$state_item" screenshots ;;
  *) /bin/cp "$state_item" "$response_path" ;;
esac
printf '200'
SH

cat >"$UPLOAD_BIN/op" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'called\n' >>"$OP_LOG"
if [[ "${FAKE_OP_FAIL:-0}" == "1" ]]; then
  echo "fake op must not be called" >&2
  exit 99
fi
printf 'fake-token\n'
SH
chmod +x "$UPLOAD_BIN/xcodebuild" "$UPLOAD_BIN/make" "$UPLOAD_BIN/curl" "$UPLOAD_BIN/op"

git -C "$UPLOAD_ROOT" init -q
git -C "$UPLOAD_ROOT" config user.name 'Tuna Tests'
git -C "$UPLOAD_ROOT" config user.email 'tests@example.com'
git -C "$UPLOAD_ROOT" add .
git -C "$UPLOAD_ROOT" commit -qm 'Create release tooling fixture'

CURL_LOG="$TMP_ROOT/upload/curl.log"
GET_LOG="$TMP_ROOT/upload/get.log"
DOWNLOAD_LOG="$TMP_ROOT/upload/download.log"
CURL_ARGS_LOG="$TMP_ROOT/upload/curl-args.log"
MEDIA_LOG="$TMP_ROOT/upload/media.log"
MEDIA_HASH_LOG="$TMP_ROOT/upload/media-hash.log"
ASSET_PATH_LOG="$TMP_ROOT/upload/asset-path.log"
MAKE_CWD_LOG="$TMP_ROOT/upload/make-cwd.log"
MAKE_COUNT_LOG="$TMP_ROOT/upload/make-count.log"
OP_LOG="$TMP_ROOT/upload/op.log"
curl_count() {
  if [[ -f "$CURL_LOG" ]]; then
    wc -l <"$CURL_LOG" | tr -d ' '
  else
    echo 0
  fi
}

get_count() {
  if [[ -f "$GET_LOG" ]]; then
    wc -l <"$GET_LOG" | tr -d ' '
  else
    echo 0
  fi
}

download_count() {
  if [[ -f "$DOWNLOAD_LOG" ]]; then
    wc -l <"$DOWNLOAD_LOG" | tr -d ' '
  else
    echo 0
  fi
}

op_count() {
  if [[ -f "$OP_LOG" ]]; then
    wc -l <"$OP_LOG" | tr -d ' '
  else
    echo 0
  fi
}

make_count() {
  if [[ -f "$MAKE_COUNT_LOG" ]]; then
    wc -l <"$MAKE_COUNT_LOG" | tr -d ' '
  else
    echo 0
  fi
}

run_release_tool() {
  local script="$1"
  (
    store_state_owned=0
    release_state_owned=0
    if [[ -n "${FAKE_PERSISTENT_STORE_STATE_DIR:-}" ]]; then
      store_state="$FAKE_PERSISTENT_STORE_STATE_DIR"
      mkdir -p "$store_state"
    else
      store_state="$(mktemp -d "$UPLOAD_TMP/store-state.XXXXXX")"
      store_state_owned=1
    fi
    if [[ -n "${FAKE_PERSISTENT_RELEASE_STATE_DIR:-}" ]]; then
      release_state="$FAKE_PERSISTENT_RELEASE_STATE_DIR"
      mkdir -p "$release_state"
    else
      release_state="$(mktemp -d "$UPLOAD_TMP/release-state.XXXXXX")"
      release_state_owned=1
    fi
    cleanup_fixture_state() {
      [[ "$store_state_owned" == "0" ]] || rm -rf "$store_state"
      [[ "$release_state_owned" == "0" ]] || rm -rf "$release_state"
    }
    trap cleanup_fixture_state EXIT
    cd "${RUN_DIRECTORY:-$UPLOAD_RUN_DIR}"
    env \
      PATH="$UPLOAD_BIN:$PATH" \
      CURL_LOG="$CURL_LOG" \
      GET_LOG="$GET_LOG" \
      DOWNLOAD_LOG="$DOWNLOAD_LOG" \
      CURL_ARGS_LOG="$CURL_ARGS_LOG" \
      MEDIA_LOG="$MEDIA_LOG" \
      MEDIA_HASH_LOG="$MEDIA_HASH_LOG" \
      ASSET_PATH_LOG="$ASSET_PATH_LOG" \
      MAKE_CWD_LOG="$MAKE_CWD_LOG" \
      MAKE_COUNT_LOG="$MAKE_COUNT_LOG" \
      OP_LOG="$OP_LOG" \
      EXPECTED_UPLOAD_ROOT="$UPLOAD_ROOT" \
      FAKE_SIGNED_ITEM="$SIGNED_ITEM" \
      FAKE_SIGNED_PACKAGE="$SIGNED_PACKAGE" \
      FAKE_UNSIGNED_ITEM="$UNSIGNED_ITEM" \
      FAKE_UNSIGNED_PACKAGE="$UNSIGNED_PACKAGE" \
      FAKE_STORE_MODE="${FAKE_STORE_MODE:-greater}" \
      FAKE_STORE_STATE_DIR="$store_state" \
      FAKE_CANDIDATE_VERSION="${FAKE_CANDIDATE_VERSION:-1.0}" \
      FAKE_NULL_TUNAKIT="${FAKE_NULL_TUNAKIT:-0}" \
      FAKE_OP_FAIL="${FAKE_OP_FAIL:-0}" \
      FAKE_CURL_MUTATE_MEDIA="${FAKE_CURL_MUTATE_MEDIA:-0}" \
      FAKE_MUTATE_MEDIA_PATH="${FAKE_MUTATE_MEDIA_PATH:-$UPLOAD_ROOT/media/icons/com.example.fixture.png}" \
      TOKEN='poison-token' \
      RELEASE_UPLOAD_TOKEN="${FAKE_UPLOAD_TOKEN-fake-token}" \
      RELEASE_UPLOAD_TOKEN_OP="${FAKE_TOKEN_OP_REF-fake://release-token}" \
      STORE_API_URL='https://invalid.example.test/api/v1/items' \
      TUNA_EXTENSION_RELEASE_STATE_ROOT="$release_state" \
      TMPDIR="$UPLOAD_TMP" \
      FAKE_ARTIFACT_MODE="${FAKE_ARTIFACT_MODE:-signed}" \
      FAKE_CHANGING_PACKAGE="${FAKE_CHANGING_PACKAGE:-0}" \
      FAKE_MAKE_DIRTY="${FAKE_MAKE_DIRTY:-0}" \
      FAKE_CURL_ADVANCE_HEAD="${FAKE_CURL_ADVANCE_HEAD:-0}" \
      "$UPLOAD_ROOT/scripts/$script" "${FAKE_RELEASE_TARGET:-FixtureExtension}"
  )
}

run_upload() {
  run_release_tool upload-extension.sh
}

run_release() {
  run_release_tool release-extension.sh
}

TAG='extensions/com.example.fixture/v1.0'

delete_fixture_tag() {
  if git -C "$UPLOAD_ROOT" show-ref --verify --quiet "refs/tags/$TAG"; then
    git -C "$UPLOAD_ROOT" tag -d "$TAG" >/dev/null
  fi
}

assert_tag_absent() {
  local label="$1"
  if git -C "$UPLOAD_ROOT" show-ref --verify --quiet "refs/tags/$TAG"; then
    fail "$label created a release tag"
  fi
}

assert_call_delta() {
  local before_put="$1"
  local before_get="$2"
  local expected_put_delta="$3"
  local expected_get_delta="$4"
  local label="$5"
  local expected_put=$((before_put + expected_put_delta))
  local expected_get=$((before_get + expected_get_delta))
  local actual_put
  local actual_get
  actual_put="$(curl_count)"
  actual_get="$(get_count)"
  [[ "$actual_put" == "$expected_put" ]] || \
    fail "$label made $((actual_put - before_put)) PUT request(s), expected $expected_put_delta"
  [[ "$actual_get" == "$expected_get" ]] || \
    fail "$label made $((actual_get - before_get)) GET request(s), expected $expected_get_delta"
}

assert_download_delta() {
  local before_download="$1"
  local expected_delta="$2"
  local label="$3"
  local actual_download
  actual_download="$(download_count)"
  [[ "$actual_download" == "$((before_download + expected_delta))" ]] || \
    fail "$label made $((actual_download - before_download)) artifact download(s), expected $expected_delta"
}

FAKE_ARTIFACT_MODE=unsigned expect_failure "unsigned package" run_upload
grep -q 'unsigned package' "$TMP_ROOT/failure.err" || fail "unsigned package error was unclear"
[[ "$(curl_count)" == "0" ]] || fail "unsigned package reached curl"

FAKE_ARTIFACT_MODE=missing-signature expect_failure "missing embedded signature" run_upload
grep -q 'without exactly one root store-signature.json' "$TMP_ROOT/failure.err" || \
  fail "missing embedded signature error was unclear"
[[ "$(curl_count)" == "0" ]] || fail "missing embedded signature reached curl"

FAKE_ARTIFACT_MODE=corrupt expect_failure "corrupt package" run_upload
grep -q 'not a valid zip archive' "$TMP_ROOT/failure.err" || fail "corrupt package error was unclear"
[[ "$(curl_count)" == "0" ]] || fail "corrupt package reached curl"

FAKE_ARTIFACT_MODE=mutated expect_failure "mutated package" run_upload
grep -Eq 'size is|checksum does not match' "$TMP_ROOT/failure.err" || \
  fail "mutated package error was unclear"
[[ "$(curl_count)" == "0" ]] || fail "mutated package reached curl"

FAKE_ARTIFACT_MODE=signature-mismatch expect_failure "mismatched embedded signature" run_upload
grep -q 'embedded store signature does not match' "$TMP_ROOT/failure.err" || \
  fail "mismatched embedded signature error was unclear"
[[ "$(curl_count)" == "0" ]] || fail "mismatched embedded signature reached curl"
if find "$UPLOAD_TMP" -mindepth 1 -print -quit | grep -q .; then
  fail "failed package validation leaked a private upload snapshot"
fi
[[ "$(get_count)" == "0" ]] || fail "invalid artifacts reached the public store preflight"

before_put="$(curl_count)"
before_get="$(get_count)"
before_download="$(download_count)"
FAKE_STORE_MODE=absent run_upload >"$TMP_ROOT/absent-upload.out"
assert_call_delta "$before_put" "$before_get" 1 2 "first publication"
assert_download_delta "$before_download" 1 "first publication"
grep -q 'not published' "$TMP_ROOT/absent-upload.out" || \
  fail "first publication was not identified"

before_put="$(curl_count)"
before_get="$(get_count)"
before_download="$(download_count)"
FAKE_STORE_MODE=greater run_upload >"$TMP_ROOT/clean-upload.out"
assert_call_delta "$before_put" "$before_get" 1 2 "newer release"
assert_download_delta "$before_download" 1 "newer release"
grep -q 'newer than store version' "$TMP_ROOT/clean-upload.out" || \
  fail "newer release was not identified"
grep -Fxq -- '--config' "$CURL_ARGS_LOG" || fail "PUT did not use a private curl config"
if grep -Eq 'Authorization:|fake-token' "$CURL_ARGS_LOG"; then
  fail "PUT exposed the bearer secret in process arguments"
fi
[[ "$(cat "$MAKE_CWD_LOG")" == "$(cd "$UPLOAD_ROOT" && pwd -P)" ]] || \
  fail "upload packaging did not run from the repository root"
snapshot_path="$(cat "$ASSET_PATH_LOG")"
[[ ! -e "$snapshot_path" ]] || fail "private upload snapshot leaked after curl"
[[ ! -d "$(dirname "$snapshot_path")" ]] || fail "private upload snapshot directory leaked"

delete_fixture_tag
before_put="$(curl_count)"
before_get="$(get_count)"
FAKE_STORE_MODE=lower expect_failure "lower release" run_release
assert_call_delta "$before_put" "$before_get" 0 1 "lower release"
grep -q 'refusing to move the current release backward' "$TMP_ROOT/failure.err" || \
  fail "lower release error was unclear"
assert_tag_absent "lower release"

before_put="$(curl_count)"
before_get="$(get_count)"
before_download="$(download_count)"
before_op="$(op_count)"
FAKE_STORE_MODE=equal-exact \
  FAKE_UPLOAD_TOKEN='' \
  FAKE_OP_FAIL=1 \
  run_release >"$TMP_ROOT/equal-release.out"
assert_call_delta "$before_put" "$before_get" 0 1 "exact equal release"
assert_download_delta "$before_download" 1 "exact equal release"
[[ "$(op_count)" == "$before_op" ]] || fail "exact equal release resolved an upload token"
grep -q 'exact .* release; skipping PUT' "$TMP_ROOT/equal-release.out" || \
  fail "exact equal release did not skip PUT"
git -C "$UPLOAD_ROOT" show-ref --verify --quiet "refs/tags/$TAG" || \
  fail "exact equal release did not recover its tag"
delete_fixture_tag

for recovery_mode in equal-artifact-missing equal-artifact-bad; do
  before_put="$(curl_count)"
  before_get="$(get_count)"
  before_download="$(download_count)"
  FAKE_STORE_MODE="$recovery_mode" run_release >"$TMP_ROOT/$recovery_mode.out"
  assert_call_delta "$before_put" "$before_get" 1 2 "$recovery_mode"
  assert_download_delta "$before_download" 2 "$recovery_mode"
  grep -q 'preparing recovery' "$TMP_ROOT/$recovery_mode.out" || \
    fail "$recovery_mode was not identified as same-version recovery"
  git -C "$UPLOAD_ROOT" show-ref --verify --quiet "refs/tags/$TAG" || \
    fail "$recovery_mode did not tag the verified repaired release"
  delete_fixture_tag
done

before_put="$(curl_count)"
before_get="$(get_count)"
before_download="$(download_count)"
FAKE_STORE_MODE=equal-url-missing run_release >"$TMP_ROOT/equal-url-missing.out"
assert_call_delta "$before_put" "$before_get" 1 2 "missing equal-version artifact URL"
assert_download_delta "$before_download" 1 "missing equal-version artifact URL"
grep -q 'public artifact URL is missing' "$TMP_ROOT/equal-url-missing.out" || \
  fail "missing artifact URL was not identified as same-version recovery"
delete_fixture_tag

before_put="$(curl_count)"
before_get="$(get_count)"
before_download="$(download_count)"
FAKE_STORE_MODE=equal-version-alias expect_failure "raw equal-version alias" run_release
assert_call_delta "$before_put" "$before_get" 0 1 "raw equal-version alias"
assert_download_delta "$before_download" 0 "raw equal-version alias"
grep -q 'equal-version release differs' "$TMP_ROOT/failure.err" || \
  fail "raw equal-version alias error was unclear"
assert_tag_absent "raw equal-version alias"

before_put="$(curl_count)"
before_get="$(get_count)"
before_download="$(download_count)"
FAKE_STORE_MODE=greater-minor \
  FAKE_CANDIDATE_VERSION=1.10 \
  run_upload >"$TMP_ROOT/greater-minor.out"
assert_call_delta "$before_put" "$before_get" 1 2 "numeric 1.10 over 1.9"
assert_download_delta "$before_download" 1 "numeric 1.10 over 1.9"
grep -q 'Candidate 1.10 is newer than store version 1.9' "$TMP_ROOT/greater-minor.out" || \
  fail "numeric 1.10 over 1.9 was not identified"

before_put="$(curl_count)"
before_get="$(get_count)"
before_download="$(download_count)"
FAKE_STORE_MODE=null-tunakit \
  FAKE_NULL_TUNAKIT=1 \
  run_upload >"$TMP_ROOT/null-tunakit.out"
assert_call_delta "$before_put" "$before_get" 1 2 "null TunaKit floor"
assert_download_delta "$before_download" 1 "null TunaKit floor"
if grep -Fq 'store_item[compatibility_min_tunakit]' "$CURL_ARGS_LOG"; then
  fail "null TunaKit floor was sent as multipart metadata"
fi
if grep -Fq 'None' "$CURL_ARGS_LOG"; then
  fail "JSON null TunaKit floor became the literal shell value None"
fi

before_put="$(curl_count)"
before_get="$(get_count)"
FAKE_STORE_MODE=equal-drift expect_failure "equal release drift" run_release
assert_call_delta "$before_put" "$before_get" 0 1 "equal release drift"
grep -q 'equal-version release differs' "$TMP_ROOT/failure.err" || \
  fail "equal release drift error was unclear"
assert_tag_absent "equal release drift"

before_put="$(curl_count)"
before_get="$(get_count)"
FAKE_STORE_MODE=wrong-response expect_failure "wrong upload response" run_release
assert_call_delta "$before_put" "$before_get" 1 1 "wrong upload response"
grep -q 'Upload response: release differs' "$TMP_ROOT/failure.err" || \
  fail "wrong upload response error was unclear"
assert_tag_absent "wrong upload response"

before_put="$(curl_count)"
before_get="$(get_count)"
FAKE_STORE_MODE=wrong-readback expect_failure "wrong public readback" run_release
assert_call_delta "$before_put" "$before_get" 1 2 "wrong public readback"
grep -q 'Post-upload readback: release differs' "$TMP_ROOT/failure.err" || \
  fail "wrong public readback error was unclear"
assert_tag_absent "wrong public readback"

put_failure_modes=(put-network-error put-server-error put-invalid-json put-invalid-schema)
put_failure_patterns=(
  'Upload failed before receiving an HTTP response'
  'Upload failed with HTTP 503'
  'Upload response: store response is not valid JSON'
  'Upload response: store response must use schema_version 1'
)
for ((index = 0; index < ${#put_failure_modes[@]}; index++)); do
  failure_mode="${put_failure_modes[$index]}"
  before_put="$(curl_count)"
  before_get="$(get_count)"
  before_download="$(download_count)"
  FAKE_STORE_MODE="$failure_mode" expect_failure "$failure_mode" run_release
  assert_call_delta "$before_put" "$before_get" 1 1 "$failure_mode"
  assert_download_delta "$before_download" 0 "$failure_mode"
  grep -q "${put_failure_patterns[$index]}" "$TMP_ROOT/failure.err" || \
    fail "$failure_mode error was unclear"
  assert_tag_absent "$failure_mode"
done

readback_failure_modes=(
  readback-network-error
  readback-server-error
  readback-invalid-json
  readback-invalid-schema
  readback-not-found
  readback-missing-url
)
readback_failure_patterns=(
  'Post-upload readback failed before receiving an HTTP response'
  'Post-upload readback failed with HTTP 503'
  'Post-upload readback: store response is not valid JSON'
  'Post-upload readback: store response must use schema_version 1'
  'Post-upload readback failed with HTTP 404'
  'Post-upload readback: store item.download.url must be a non-empty string'
)
for ((index = 0; index < ${#readback_failure_modes[@]}; index++)); do
  failure_mode="${readback_failure_modes[$index]}"
  before_put="$(curl_count)"
  before_get="$(get_count)"
  before_download="$(download_count)"
  FAKE_STORE_MODE="$failure_mode" expect_failure "$failure_mode" run_release
  assert_call_delta "$before_put" "$before_get" 1 2 "$failure_mode"
  assert_download_delta "$before_download" 0 "$failure_mode"
  grep -q "${readback_failure_patterns[$index]}" "$TMP_ROOT/failure.err" || \
    fail "$failure_mode error was unclear"
  assert_tag_absent "$failure_mode"
done

for failure_mode in post-artifact-missing post-artifact-bad post-artifact-network; do
  before_put="$(curl_count)"
  before_get="$(get_count)"
  before_download="$(download_count)"
  FAKE_STORE_MODE="$failure_mode" expect_failure "$failure_mode" run_release
  assert_call_delta "$before_put" "$before_get" 1 2 "$failure_mode"
  assert_download_delta "$before_download" 1 "$failure_mode"
  grep -q 'Post-upload readback' "$TMP_ROOT/failure.err" || \
    fail "$failure_mode error was unclear"
  assert_tag_absent "$failure_mode"
done

LOCKED_RELEASE_STATE="$UPLOAD_TMP/locked-release-state"
locked_state_parent="$LOCKED_RELEASE_STATE/FixtureExtension"
locked_state_path="$locked_state_parent/.$(git -C "$UPLOAD_ROOT" rev-parse HEAD).lock"
mkdir -p "$locked_state_path"
before_put="$(curl_count)"
before_get="$(get_count)"
before_make="$(make_count)"
FAKE_PERSISTENT_RELEASE_STATE_DIR="$LOCKED_RELEASE_STATE" \
  expect_failure "locked release state" run_release
assert_call_delta "$before_put" "$before_get" 0 0 "locked release state"
[[ "$(make_count)" == "$before_make" ]] || fail "locked release state reached packaging"
grep -q 'packaging is already in progress, or a stale lock remains' "$TMP_ROOT/failure.err" || \
  fail "locked release state error was unclear"
/bin/rmdir "$locked_state_path"

RETRY_STORE_STATE="$UPLOAD_TMP/retry-store-state"
RETRY_RELEASE_STATE="$UPLOAD_TMP/retry-release-state"
mkdir -p "$RETRY_STORE_STATE" "$RETRY_RELEASE_STATE"
delete_fixture_tag
before_put="$(curl_count)"
before_get="$(get_count)"
before_download="$(download_count)"
before_make="$(make_count)"
FAKE_STORE_MODE=put-network-error \
  FAKE_CHANGING_PACKAGE=1 \
  FAKE_RELEASE_TARGET=TunaFixture \
  FAKE_PERSISTENT_STORE_STATE_DIR="$RETRY_STORE_STATE" \
  FAKE_PERSISTENT_RELEASE_STATE_DIR="$RETRY_RELEASE_STATE" \
  expect_failure "failed release PUT" run_release
assert_call_delta "$before_put" "$before_get" 1 1 "failed release PUT"
assert_download_delta "$before_download" 0 "failed release PUT"
[[ "$(make_count)" == "$((before_make + 1))" ]] || \
  fail "failed release PUT did not package exactly once"
assert_tag_absent "failed release PUT"

retry_frozen_package="$(find "$RETRY_RELEASE_STATE" -name package.tunaextension -type f -print -quit)"
[[ -n "$retry_frozen_package" ]] || fail "failed release PUT did not preserve frozen state"
retry_frozen_checksum="$(shasum -a 256 "$retry_frozen_package" | awk '{print $1}')"

before_put="$(curl_count)"
before_get="$(get_count)"
before_download="$(download_count)"
before_make="$(make_count)"
FAKE_STORE_MODE=greater \
  FAKE_CHANGING_PACKAGE=1 \
  FAKE_PERSISTENT_STORE_STATE_DIR="$RETRY_STORE_STATE" \
  FAKE_PERSISTENT_RELEASE_STATE_DIR="$RETRY_RELEASE_STATE" \
  run_release >"$TMP_ROOT/failed-put-retry.out"
assert_call_delta "$before_put" "$before_get" 1 2 "failed release PUT retry"
assert_download_delta "$before_download" 1 "failed release PUT retry"
[[ "$(make_count)" == "$before_make" ]] || \
  fail "failed release PUT retry rebuilt its frozen package"
grep -q 'Reusing frozen release candidate' "$TMP_ROOT/failed-put-retry.out" || \
  fail "failed release PUT retry did not report frozen-state reuse"
grep -Fq ';filename=com.example.fixture-1.0.tunaextension;type=application/octet-stream' \
  "$CURL_ARGS_LOG" || fail "failed release PUT retry changed the package filename"
[[ "$retry_frozen_checksum" == "$(shasum -a 256 "$RETRY_STORE_STATE/artifact.tunaextension" | awk '{print $1}')" ]] || \
  fail "failed release PUT retry did not upload its frozen bytes"
git -C "$UPLOAD_ROOT" show-ref --verify --quiet "refs/tags/$TAG" || \
  fail "failed release PUT retry did not tag the verified store bytes"
delete_fixture_tag

SYMLINK_RELEASE_STATE="$UPLOAD_TMP/symlink-release-state"
symlink_state_parent="$SYMLINK_RELEASE_STATE/FixtureExtension"
symlink_state_path="$symlink_state_parent/$(git -C "$UPLOAD_ROOT" rev-parse HEAD)"
mkdir -p "$symlink_state_parent"
/bin/ln -s "$(dirname "$retry_frozen_package")" "$symlink_state_path"
before_put="$(curl_count)"
before_get="$(get_count)"
before_make="$(make_count)"
FAKE_PERSISTENT_RELEASE_STATE_DIR="$SYMLINK_RELEASE_STATE" \
  expect_failure "symlinked release state" run_release
assert_call_delta "$before_put" "$before_get" 0 0 "symlinked release state"
[[ "$(make_count)" == "$before_make" ]] || fail "symlinked release state reached packaging"
grep -q 'state path is not a real directory' "$TMP_ROOT/failure.err" || \
  fail "symlinked release state error was unclear"

UNCERTAIN_STORE_STATE="$UPLOAD_TMP/uncertain-store-state"
UNCERTAIN_RELEASE_STATE="$UPLOAD_TMP/uncertain-release-state"
mkdir -p "$UNCERTAIN_STORE_STATE" "$UNCERTAIN_RELEASE_STATE"
delete_fixture_tag
before_put="$(curl_count)"
before_get="$(get_count)"
before_download="$(download_count)"
before_make="$(make_count)"
FAKE_STORE_MODE=readback-network-error \
  FAKE_CHANGING_PACKAGE=1 \
  FAKE_PERSISTENT_STORE_STATE_DIR="$UNCERTAIN_STORE_STATE" \
  FAKE_PERSISTENT_RELEASE_STATE_DIR="$UNCERTAIN_RELEASE_STATE" \
  expect_failure "uncertain release readback" run_release
assert_call_delta "$before_put" "$before_get" 1 2 "uncertain release readback"
assert_download_delta "$before_download" 0 "uncertain release readback"
[[ "$(make_count)" == "$((before_make + 1))" ]] || \
  fail "uncertain release did not package exactly once"
assert_tag_absent "uncertain release readback"

frozen_package="$(find "$UNCERTAIN_RELEASE_STATE" -name package.tunaextension -type f -print -quit)"
frozen_state="$(find "$UNCERTAIN_RELEASE_STATE" -name state.json -type f -print -quit)"
[[ -n "$frozen_package" && -n "$frozen_state" ]] || \
  fail "uncertain release did not preserve frozen package state"
frozen_checksum="$(shasum -a 256 "$frozen_package" | awk '{print $1}')"
[[ "$frozen_checksum" == "$(shasum -a 256 "$UNCERTAIN_STORE_STATE/artifact.tunaextension" | awk '{print $1}')" ]] || \
  fail "uncertain release state does not match the package accepted by the store"

second_candidate_json="$TMP_ROOT/changed-second-candidate.json"
env \
  PATH="$UPLOAD_BIN:$PATH" \
  MAKE_CWD_LOG="$MAKE_CWD_LOG" \
  MAKE_COUNT_LOG="$MAKE_COUNT_LOG" \
  FAKE_SIGNED_ITEM="$SIGNED_ITEM" \
  FAKE_SIGNED_PACKAGE="$SIGNED_PACKAGE" \
  FAKE_UNSIGNED_ITEM="$UNSIGNED_ITEM" \
  FAKE_UNSIGNED_PACKAGE="$UNSIGNED_PACKAGE" \
  FAKE_CANDIDATE_VERSION=1.0 \
  FAKE_NULL_TUNAKIT=0 \
  FAKE_ARTIFACT_MODE=signed \
  FAKE_CHANGING_PACKAGE=1 \
  TOKEN= \
  RELEASE_UPLOAD_TOKEN= \
  make -C "$UPLOAD_ROOT" ext-package >"$second_candidate_json"
second_candidate_checksum="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["download"]["checksum_sha256"])' "$second_candidate_json")"
[[ "$second_candidate_checksum" != "$frozen_checksum" ]] || \
  fail "changing package fixture did not produce different retry bytes"

before_put="$(curl_count)"
before_get="$(get_count)"
before_download="$(download_count)"
before_make="$(make_count)"
before_op="$(op_count)"
FAKE_STORE_MODE=greater \
  FAKE_CHANGING_PACKAGE=1 \
  FAKE_PERSISTENT_STORE_STATE_DIR="$UNCERTAIN_STORE_STATE" \
  FAKE_PERSISTENT_RELEASE_STATE_DIR="$UNCERTAIN_RELEASE_STATE" \
  FAKE_OP_FAIL=1 \
  run_release >"$TMP_ROOT/uncertain-retry.out"
assert_call_delta "$before_put" "$before_get" 0 1 "uncertain release retry"
assert_download_delta "$before_download" 1 "uncertain release retry"
[[ "$(make_count)" == "$before_make" ]] || \
  fail "uncertain release retry rebuilt its frozen package"
[[ "$(op_count)" == "$before_op" ]] || \
  fail "uncertain release retry resolved upload credentials"
grep -q 'Reusing frozen release candidate' "$TMP_ROOT/uncertain-retry.out" || \
  fail "uncertain release retry did not report frozen-state reuse"
git -C "$UPLOAD_ROOT" show-ref --verify --quiet "refs/tags/$TAG" || \
  fail "uncertain release retry did not converge by tagging the verified store bytes"
delete_fixture_tag

frozen_package_backup="$TMP_ROOT/frozen-package-backup.tunaextension"
/bin/cp "$frozen_package" "$frozen_package_backup"
/bin/chmod 600 "$frozen_package"
printf 'corruption\n' >>"$frozen_package"
before_put="$(curl_count)"
before_get="$(get_count)"
before_make="$(make_count)"
FAKE_STORE_MODE=greater \
  FAKE_PERSISTENT_STORE_STATE_DIR="$UNCERTAIN_STORE_STATE" \
  FAKE_PERSISTENT_RELEASE_STATE_DIR="$UNCERTAIN_RELEASE_STATE" \
  expect_failure "corrupt frozen package" run_release
assert_call_delta "$before_put" "$before_get" 0 0 "corrupt frozen package"
[[ "$(make_count)" == "$before_make" ]] || fail "corrupt frozen package triggered a rebuild"
grep -q 'package size no longer matches state.json' "$TMP_ROOT/failure.err" || \
  fail "corrupt frozen package error was unclear"
/bin/cp "$frozen_package_backup" "$frozen_package"
/bin/chmod 400 "$frozen_package"

/bin/chmod 600 "$frozen_state"
python3 - "$frozen_state" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as fh:
    state = json.load(fh)
state["source_commit"] = "0" * 40
with open(path, "w", encoding="utf-8") as fh:
    json.dump(state, fh, indent=2, sort_keys=True)
    fh.write("\n")
PY
before_put="$(curl_count)"
before_get="$(get_count)"
before_make="$(make_count)"
FAKE_STORE_MODE=greater \
  FAKE_PERSISTENT_STORE_STATE_DIR="$UNCERTAIN_STORE_STATE" \
  FAKE_PERSISTENT_RELEASE_STATE_DIR="$UNCERTAIN_RELEASE_STATE" \
  expect_failure "mismatched frozen release state" run_release
assert_call_delta "$before_put" "$before_get" 0 0 "mismatched frozen release state"
[[ "$(make_count)" == "$before_make" ]] || \
  fail "mismatched release state triggered a rebuild"
grep -q 'Frozen release state is invalid: source_commit' "$TMP_ROOT/failure.err" || \
  fail "mismatched release state error was unclear"

before_put="$(curl_count)"
before_get="$(get_count)"
FAKE_STORE_MODE=invalid-json expect_failure "invalid preflight JSON" run_release
assert_call_delta "$before_put" "$before_get" 0 1 "invalid preflight JSON"
grep -q 'store response is not valid JSON' "$TMP_ROOT/failure.err" || \
  fail "invalid preflight JSON error was unclear"
assert_tag_absent "invalid preflight JSON"

before_put="$(curl_count)"
before_get="$(get_count)"
FAKE_STORE_MODE=invalid-schema expect_failure "invalid preflight schema" run_release
assert_call_delta "$before_put" "$before_get" 0 1 "invalid preflight schema"
grep -q 'must use schema_version 1' "$TMP_ROOT/failure.err" || \
  fail "invalid preflight schema error was unclear"
assert_tag_absent "invalid preflight schema"

before_put="$(curl_count)"
before_get="$(get_count)"
FAKE_STORE_MODE=server-error expect_failure "preflight server error" run_release
assert_call_delta "$before_put" "$before_get" 0 1 "preflight server error"
grep -q 'Store preflight failed with HTTP 503' "$TMP_ROOT/failure.err" || \
  fail "preflight server error was unclear"
assert_tag_absent "preflight server error"

before_put="$(curl_count)"
before_get="$(get_count)"
FAKE_STORE_MODE=network-error expect_failure "preflight network error" run_release
assert_call_delta "$before_put" "$before_get" 0 1 "preflight network error"
grep -q 'failed before receiving an HTTP response' "$TMP_ROOT/failure.err" || \
  fail "preflight network error was unclear"
assert_tag_absent "preflight network error"

put_count_before_input_failures="$(curl_count)"

FAKE_MAKE_DIRTY=1 expect_failure "input changed during packaging" run_upload
[[ "$(curl_count)" == "$put_count_before_input_failures" ]] || \
  fail "input changed during packaging reached PUT"
git -C "$UPLOAD_ROOT" restore FixtureExtension/Info.plist

printf 'dirty\n' >>"$UPLOAD_ROOT/FixtureExtension/Info.plist"
expect_failure "dirty extension input" run_upload
[[ "$(curl_count)" == "$put_count_before_input_failures" ]] || \
  fail "dirty extension input reached PUT"
git -C "$UPLOAD_ROOT" restore FixtureExtension/Info.plist

printf 'staged\n' >>"$UPLOAD_ROOT/FixtureExtension/FixtureExtension.swift"
git -C "$UPLOAD_ROOT" add FixtureExtension/FixtureExtension.swift
expect_failure "staged extension input" run_upload
[[ "$(curl_count)" == "$put_count_before_input_failures" ]] || \
  fail "staged extension input reached PUT"
git -C "$UPLOAD_ROOT" restore --staged FixtureExtension/FixtureExtension.swift
git -C "$UPLOAD_ROOT" restore FixtureExtension/FixtureExtension.swift

printf 'untracked\n' >"$UPLOAD_ROOT/FixtureExtension/Untracked.swift"
expect_failure "untracked extension input" run_upload
[[ "$(curl_count)" == "$put_count_before_input_failures" ]] || \
  fail "untracked extension input reached PUT"
rm "$UPLOAD_ROOT/FixtureExtension/Untracked.swift"

printf 'dirty\n' >>"$UPLOAD_ROOT/Makefile"
expect_failure "dirty shared input" run_upload
[[ "$(curl_count)" == "$put_count_before_input_failures" ]] || \
  fail "dirty shared input reached PUT"
git -C "$UPLOAD_ROOT" restore Makefile

printf 'media/\n' >>"$UPLOAD_ROOT/.gitignore"
expect_failure "dirty ignore rules" run_upload
[[ "$(curl_count)" == "$put_count_before_input_failures" ]] || \
  fail "dirty ignore rules reached PUT"
git -C "$UPLOAD_ROOT" restore .gitignore

printf '#!/usr/bin/env bash\n' >"$UPLOAD_ROOT/scripts/untracked-release-input.sh"
expect_failure "untracked shared script" run_upload
[[ "$(curl_count)" == "$put_count_before_input_failures" ]] || \
  fail "untracked shared script reached PUT"
rm "$UPLOAD_ROOT/scripts/untracked-release-input.sh"

mkdir -p "$UPLOAD_ROOT/media"
printf 'untracked media\n' >"$UPLOAD_ROOT/media/icon.png"
expect_failure "untracked media input" run_upload
[[ "$(curl_count)" == "$put_count_before_input_failures" ]] || \
  fail "untracked media input reached PUT"
rm -rf "$UPLOAD_ROOT/media"

git -C "$UPLOAD_ROOT" tag -a "$TAG" -m 'Fixture Extension 1.0'
printf 'new head\n' >"$UPLOAD_ROOT/history.txt"
git -C "$UPLOAD_ROOT" add history.txt
git -C "$UPLOAD_ROOT" commit -qm 'Advance fixture head'

before_put="$(curl_count)"
before_get="$(get_count)"
expect_failure "mismatched existing tag" run_release
grep -q 'not release HEAD' "$TMP_ROOT/failure.err" || fail "mismatched tag error was unclear"
assert_call_delta "$before_put" "$before_get" 0 0 "mismatched existing tag"

git -C "$UPLOAD_ROOT" tag -d "$TAG" >/dev/null
release_commit_before_curl="$(git -C "$UPLOAD_ROOT" rev-parse HEAD)"
before_put="$(curl_count)"
before_get="$(get_count)"
FAKE_CURL_ADVANCE_HEAD=1 run_release >"$TMP_ROOT/head-change-release.out"
assert_call_delta "$before_put" "$before_get" 1 2 "HEAD-change release"
grep -q 'Tagged release' "$TMP_ROOT/head-change-release.out" || \
  fail "first release did not recover its tag after HEAD changed during curl"
[[ "$(git -C "$UPLOAD_ROOT" rev-parse "refs/tags/$TAG^{commit}")" == "$release_commit_before_curl" ]] || \
  fail "first release tagged the post-curl HEAD instead of the uploaded commit"
[[ "$(git -C "$UPLOAD_ROOT" rev-parse HEAD)" != "$release_commit_before_curl" ]] || \
  fail "fake curl did not advance HEAD"

git -C "$UPLOAD_ROOT" tag -d "$TAG" >/dev/null
git -C "$UPLOAD_ROOT" tag -a "$TAG" -m 'Fixture Extension 1.0'
tag_ref_before="$(git -C "$UPLOAD_ROOT" rev-parse "refs/tags/$TAG")"
before_put="$(curl_count)"
before_get="$(get_count)"
FAKE_STORE_MODE=equal-exact run_release >"$TMP_ROOT/same-head-release.out"
grep -q 'Tag already exists at release commit' "$TMP_ROOT/same-head-release.out" || \
  fail "same-HEAD rerun was not identified"
assert_call_delta "$before_put" "$before_get" 0 1 "same-HEAD rerun"
[[ "$(git -C "$UPLOAD_ROOT" rev-parse "refs/tags/$TAG")" == "$tag_ref_before" ]] || \
  fail "same-HEAD rerun replaced the existing tag"

mkdir -p "$UPLOAD_ROOT/media/icons"
printf '/media/icons/com.example.fixture.png\n' >>"$UPLOAD_ROOT/.git/info/exclude"
printf 'ignored media\n' >"$UPLOAD_ROOT/media/icons/com.example.fixture.png"
before_put="$(curl_count)"
before_get="$(get_count)"
run_upload >"$TMP_ROOT/ignored-media-upload.out"
assert_call_delta "$before_put" "$before_get" 1 2 "ignored-media upload"
[[ ! -s "$MEDIA_LOG" ]] || fail "ignored media was included in curl"
rm "$UPLOAD_ROOT/media/icons/com.example.fixture.png"
: >"$UPLOAD_ROOT/.git/info/exclude"

printf 'tracked media\n' >"$UPLOAD_ROOT/media/icons/com.example.fixture.png"
mkdir -p "$UPLOAD_ROOT/media/screenshots/com.example.fixture"
printf 'tracked screenshot\n' > \
  "$UPLOAD_ROOT/media/screenshots/com.example.fixture/01-overview.png"
git -C "$UPLOAD_ROOT" add \
  media/icons/com.example.fixture.png \
  media/screenshots/com.example.fixture/01-overview.png
git -C "$UPLOAD_ROOT" commit -qm 'Add tracked listing media'
before_put="$(curl_count)"
before_get="$(get_count)"
before_download="$(download_count)"
run_upload >"$TMP_ROOT/tracked-media-upload.out"
assert_call_delta "$before_put" "$before_get" 1 2 "tracked-media upload"
assert_download_delta "$before_download" 1 "tracked-media upload"
found_icon=0
found_screenshot=0
while IFS= read -r logged_media_path; do
  [[ "$logged_media_path" != "$UPLOAD_ROOT"/* ]] || \
    fail "tracked media used a mutable worktree path"
  [[ "$logged_media_path" == */committed/media/icons/com.example.fixture.png ]] && found_icon=1
  [[ "$logged_media_path" == */committed/media/screenshots/com.example.fixture/01-overview.png ]] && \
    found_screenshot=1
done <"$MEDIA_LOG"
[[ "$found_icon" == "1" ]] || fail "tracked listing media was not included in curl"
[[ "$found_screenshot" == "1" ]] || fail "tracked screenshot was not included in curl"
[[ "$(wc -l <"$MEDIA_LOG" | tr -d ' ')" == "2" ]] || \
  fail "tracked-media upload sent an unexpected number of media files"

delete_fixture_tag
before_put="$(curl_count)"
before_get="$(get_count)"
before_download="$(download_count)"
FAKE_STORE_MODE=equal-media-missing run_release >"$TMP_ROOT/equal-media-missing.out"
assert_call_delta "$before_put" "$before_get" 1 2 "missing equal-version media"
assert_download_delta "$before_download" 1 "missing equal-version media"
grep -q 'tracked icon is missing' "$TMP_ROOT/equal-media-missing.out" || \
  fail "missing equal-version media did not select recovery"
git -C "$UPLOAD_ROOT" show-ref --verify --quiet "refs/tags/$TAG" || \
  fail "repaired equal-version media did not tag the verified release"
delete_fixture_tag

expected_icon_blob="$(git -C "$UPLOAD_ROOT" rev-parse HEAD:media/icons/com.example.fixture.png)"
expected_screenshot_blob="$(
  git -C "$UPLOAD_ROOT" rev-parse \
    HEAD:media/screenshots/com.example.fixture/01-overview.png
)"
before_put="$(curl_count)"
before_get="$(get_count)"
before_download="$(download_count)"
FAKE_STORE_MODE=mutate-media \
  FAKE_CURL_MUTATE_MEDIA=1 \
  run_upload >"$TMP_ROOT/mutate-media.out"
assert_call_delta "$before_put" "$before_get" 1 2 "media mutation during curl"
assert_download_delta "$before_download" 1 "media mutation during curl"
grep -Fq "$expected_icon_blob" "$MEDIA_HASH_LOG" || \
  fail "uploaded icon snapshot changed with the worktree during curl"
grep -Fq "$expected_screenshot_blob" "$MEDIA_HASH_LOG" || \
  fail "uploaded screenshot snapshot did not match the release commit"
[[ "$(git -C "$UPLOAD_ROOT" hash-object media/icons/com.example.fixture.png)" != \
  "$expected_icon_blob" ]] || fail "fake curl did not mutate tracked media"
git -C "$UPLOAD_ROOT" restore media/icons/com.example.fixture.png

before_put="$(curl_count)"
before_get="$(get_count)"
FAKE_STORE_MODE=wrong-media-response expect_failure \
  "missing screenshot URLs in upload response" run_release
assert_call_delta "$before_put" "$before_get" 1 1 "missing response screenshot URLs"
grep -q 'Upload response: release media differs: tracked screenshots are missing' \
  "$TMP_ROOT/failure.err" || fail "missing response screenshot URL error was unclear"
assert_tag_absent "missing response screenshot URLs"

before_put="$(curl_count)"
before_get="$(get_count)"
FAKE_STORE_MODE=wrong-media-readback expect_failure \
  "missing icon URL in public readback" run_release
assert_call_delta "$before_put" "$before_get" 1 2 "missing readback icon URL"
grep -q 'Post-upload readback: release media differs: tracked icon is missing' \
  "$TMP_ROOT/failure.err" || fail "missing readback icon URL error was unclear"
assert_tag_absent "missing readback icon URL"

grep -Fq './scripts/tuna-extension upload --scheme "$$SCHEME"' "$ROOT/Makefile" || \
  fail "ext-upload-all bypasses the signing wrapper"
grep -q 'DEFAULT_SIGNING_KEY_OP_REF=' "$ROOT/scripts/tuna-extension" || \
  fail "the extension command has no default signing provider"
[[ -x "$ROOT/scripts/extension-release-state.py" ]] || \
  fail "the frozen release-state helper is not executable"
if grep -Fq '  "$ROOT/dist/store"' "$ROOT/scripts/upload-extension.sh"; then
  fail "ignored dist/store remains a listing-media source"
fi
grep -Fq 'Tuna executable from the exact extracted frozen signed/notarized' "$ROOT/README.md" || \
  fail "release host documentation does not identify the frozen signed/notarized candidate"
if grep -Fq 'exact qualified candidate host' "$ROOT/README.md"; then
  fail "release host documentation still waits for post-extension qualification"
fi
grep -q '/bin/rm -P' "$ROOT/scripts/ext-package.sh" || fail "temporary keys are not securely removed"

echo "Release tooling tests pass."
