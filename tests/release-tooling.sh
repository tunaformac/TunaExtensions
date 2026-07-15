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
if [[ "${1:-}" == "-C" ]]; then
  cd "$2"
  shift 2
fi
[[ "${1:-}" == "ext-package" ]]
pwd -P >"$MAKE_CWD_LOG"

if [[ "${FAKE_MAKE_DIRTY:-0}" == "1" ]]; then
  printf 'changed during packaging\n' >>FixtureExtension/Info.plist
fi

mkdir -p dist/store
package_path="dist/store/com.example.fixture-1.0.tunaextension"
mode="${FAKE_ARTIFACT_MODE:-signed}"

case "$mode" in
  signed|mutated)
    cp "$FAKE_SIGNED_PACKAGE" "$package_path"
    if [[ "$mode" == "mutated" ]]; then
      printf 'mutation\n' >>"$package_path"
    fi
    cat "$FAKE_SIGNED_ITEM"
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
response_path=""
asset_path=""
text_form_count=0
: >"$CURL_ARGS_LOG"
: >"$MEDIA_LOG"
printf '%s\n' "$@" >"$CURL_ARGS_LOG"
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o) response_path="$2"; shift 2 ;;
    -w) shift 2 ;;
    --form-string)
      text_form_count=$((text_form_count + 1))
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
      if [[ "$field" == "store_item[asset]" ]]; then
        asset_path="$file_path"
      else
        printf '%s\n' "$file_path" >>"$MEDIA_LOG"
      fi
      shift 2
      ;;
    *) shift ;;
  esac
done
[[ -n "$response_path" ]]
[[ $text_form_count -gt 0 ]] || {
  echo "curl received no --form-string metadata" >&2
  exit 1
}
[[ -n "$asset_path" ]] || {
  echo "curl received no package asset" >&2
  exit 1
}
[[ "$asset_path" != "$EXPECTED_UPLOAD_ROOT"/dist/store/* ]] || {
  echo "curl received the mutable dist/store artifact" >&2
  exit 1
}
[[ "$(/usr/bin/stat -f '%Lp' "$asset_path")" == "400" ]] || {
  echo "upload snapshot is writable" >&2
  exit 1
}
[[ "$(/usr/bin/stat -f '%Lp' "$(dirname "$asset_path")")" == "700" ]] || {
  echo "upload snapshot directory is not private" >&2
  exit 1
}
printf '%s\n' "$asset_path" >"$ASSET_PATH_LOG"
printf '{"ok":true}\n' >"$response_path"
printf 'called\n' >>"$CURL_LOG"
if [[ "${FAKE_CURL_ADVANCE_HEAD:-0}" == "1" ]]; then
  printf 'advanced during curl\n' >"$EXPECTED_UPLOAD_ROOT/head-changed-during-curl.txt"
  git -C "$EXPECTED_UPLOAD_ROOT" add head-changed-during-curl.txt
  git -C "$EXPECTED_UPLOAD_ROOT" commit -qm 'Advance HEAD during fake curl'
fi
printf '200'
SH
chmod +x "$UPLOAD_BIN/xcodebuild" "$UPLOAD_BIN/make" "$UPLOAD_BIN/curl"

git -C "$UPLOAD_ROOT" init -q
git -C "$UPLOAD_ROOT" config user.name 'Tuna Tests'
git -C "$UPLOAD_ROOT" config user.email 'tests@example.com'
git -C "$UPLOAD_ROOT" add .
git -C "$UPLOAD_ROOT" commit -qm 'Create release tooling fixture'

CURL_LOG="$TMP_ROOT/upload/curl.log"
CURL_ARGS_LOG="$TMP_ROOT/upload/curl-args.log"
MEDIA_LOG="$TMP_ROOT/upload/media.log"
ASSET_PATH_LOG="$TMP_ROOT/upload/asset-path.log"
MAKE_CWD_LOG="$TMP_ROOT/upload/make-cwd.log"
curl_count() {
  if [[ -f "$CURL_LOG" ]]; then
    wc -l <"$CURL_LOG" | tr -d ' '
  else
    echo 0
  fi
}

run_upload() {
  (
    cd "${RUN_DIRECTORY:-$UPLOAD_RUN_DIR}"
    env \
      PATH="$UPLOAD_BIN:$PATH" \
      CURL_LOG="$CURL_LOG" \
      CURL_ARGS_LOG="$CURL_ARGS_LOG" \
      MEDIA_LOG="$MEDIA_LOG" \
      ASSET_PATH_LOG="$ASSET_PATH_LOG" \
      MAKE_CWD_LOG="$MAKE_CWD_LOG" \
      EXPECTED_UPLOAD_ROOT="$UPLOAD_ROOT" \
      FAKE_SIGNED_ITEM="$SIGNED_ITEM" \
      FAKE_SIGNED_PACKAGE="$SIGNED_PACKAGE" \
      FAKE_UNSIGNED_ITEM="$UNSIGNED_ITEM" \
      FAKE_UNSIGNED_PACKAGE="$UNSIGNED_PACKAGE" \
      RELEASE_UPLOAD_TOKEN=fake-token \
      STORE_API_URL='https://invalid.example.test/api/v1/items' \
      TMPDIR="$UPLOAD_TMP" \
      FAKE_ARTIFACT_MODE="${FAKE_ARTIFACT_MODE:-signed}" \
      FAKE_MAKE_DIRTY="${FAKE_MAKE_DIRTY:-0}" \
      "$UPLOAD_ROOT/scripts/upload-extension.sh" FixtureExtension
  )
}

run_release() {
  (
    cd "${RUN_DIRECTORY:-$UPLOAD_RUN_DIR}"
    env \
      PATH="$UPLOAD_BIN:$PATH" \
      CURL_LOG="$CURL_LOG" \
      CURL_ARGS_LOG="$CURL_ARGS_LOG" \
      MEDIA_LOG="$MEDIA_LOG" \
      ASSET_PATH_LOG="$ASSET_PATH_LOG" \
      MAKE_CWD_LOG="$MAKE_CWD_LOG" \
      EXPECTED_UPLOAD_ROOT="$UPLOAD_ROOT" \
      FAKE_SIGNED_ITEM="$SIGNED_ITEM" \
      FAKE_SIGNED_PACKAGE="$SIGNED_PACKAGE" \
      FAKE_UNSIGNED_ITEM="$UNSIGNED_ITEM" \
      FAKE_UNSIGNED_PACKAGE="$UNSIGNED_PACKAGE" \
      RELEASE_UPLOAD_TOKEN=fake-token \
      STORE_API_URL='https://invalid.example.test/api/v1/items' \
      TMPDIR="$UPLOAD_TMP" \
      FAKE_ARTIFACT_MODE="${FAKE_ARTIFACT_MODE:-signed}" \
      FAKE_CURL_ADVANCE_HEAD="${FAKE_CURL_ADVANCE_HEAD:-0}" \
      "$UPLOAD_ROOT/scripts/release-extension.sh" FixtureExtension
  )
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

run_upload >"$TMP_ROOT/clean-upload.out"
[[ "$(curl_count)" == "1" ]] || fail "clean upload did not reach fake curl exactly once"
[[ "$(cat "$MAKE_CWD_LOG")" == "$(cd "$UPLOAD_ROOT" && pwd -P)" ]] || \
  fail "upload packaging did not run from the repository root"
snapshot_path="$(cat "$ASSET_PATH_LOG")"
[[ ! -e "$snapshot_path" ]] || fail "private upload snapshot leaked after curl"
[[ ! -d "$(dirname "$snapshot_path")" ]] || fail "private upload snapshot directory leaked"

FAKE_MAKE_DIRTY=1 expect_failure "input changed during packaging" run_upload
[[ "$(curl_count)" == "1" ]] || fail "input changed during packaging reached curl"
git -C "$UPLOAD_ROOT" restore FixtureExtension/Info.plist

printf 'dirty\n' >>"$UPLOAD_ROOT/FixtureExtension/Info.plist"
expect_failure "dirty extension input" run_upload
[[ "$(curl_count)" == "1" ]] || fail "dirty extension input reached curl"
git -C "$UPLOAD_ROOT" restore FixtureExtension/Info.plist

printf 'staged\n' >>"$UPLOAD_ROOT/FixtureExtension/FixtureExtension.swift"
git -C "$UPLOAD_ROOT" add FixtureExtension/FixtureExtension.swift
expect_failure "staged extension input" run_upload
[[ "$(curl_count)" == "1" ]] || fail "staged extension input reached curl"
git -C "$UPLOAD_ROOT" restore --staged FixtureExtension/FixtureExtension.swift
git -C "$UPLOAD_ROOT" restore FixtureExtension/FixtureExtension.swift

printf 'untracked\n' >"$UPLOAD_ROOT/FixtureExtension/Untracked.swift"
expect_failure "untracked extension input" run_upload
[[ "$(curl_count)" == "1" ]] || fail "untracked extension input reached curl"
rm "$UPLOAD_ROOT/FixtureExtension/Untracked.swift"

printf 'dirty\n' >>"$UPLOAD_ROOT/Makefile"
expect_failure "dirty shared input" run_upload
[[ "$(curl_count)" == "1" ]] || fail "dirty shared input reached curl"
git -C "$UPLOAD_ROOT" restore Makefile

printf 'media/\n' >>"$UPLOAD_ROOT/.gitignore"
expect_failure "dirty ignore rules" run_upload
[[ "$(curl_count)" == "1" ]] || fail "dirty ignore rules reached curl"
git -C "$UPLOAD_ROOT" restore .gitignore

printf '#!/usr/bin/env bash\n' >"$UPLOAD_ROOT/scripts/untracked-release-input.sh"
expect_failure "untracked shared script" run_upload
[[ "$(curl_count)" == "1" ]] || fail "untracked shared script reached curl"
rm "$UPLOAD_ROOT/scripts/untracked-release-input.sh"

mkdir -p "$UPLOAD_ROOT/media"
printf 'untracked media\n' >"$UPLOAD_ROOT/media/icon.png"
expect_failure "untracked media input" run_upload
[[ "$(curl_count)" == "1" ]] || fail "untracked media input reached curl"
rm -rf "$UPLOAD_ROOT/media"

TAG='extensions/com.example.fixture/v1.0'
git -C "$UPLOAD_ROOT" tag -a "$TAG" -m 'Fixture Extension 1.0'
printf 'new head\n' >"$UPLOAD_ROOT/history.txt"
git -C "$UPLOAD_ROOT" add history.txt
git -C "$UPLOAD_ROOT" commit -qm 'Advance fixture head'

expect_failure "mismatched existing tag" run_release
grep -q 'not release HEAD' "$TMP_ROOT/failure.err" || fail "mismatched tag error was unclear"
[[ "$(curl_count)" == "1" ]] || fail "mismatched tag reached curl"

git -C "$UPLOAD_ROOT" tag -d "$TAG" >/dev/null
release_commit_before_curl="$(git -C "$UPLOAD_ROOT" rev-parse HEAD)"
FAKE_CURL_ADVANCE_HEAD=1 run_release >"$TMP_ROOT/head-change-release.out"
[[ "$(curl_count)" == "2" ]] || fail "HEAD-change fixture did not reach fake curl exactly once"
grep -q 'Tagged release' "$TMP_ROOT/head-change-release.out" || \
  fail "first release did not recover its tag after HEAD changed during curl"
[[ "$(git -C "$UPLOAD_ROOT" rev-parse "refs/tags/$TAG^{commit}")" == "$release_commit_before_curl" ]] || \
  fail "first release tagged the post-curl HEAD instead of the uploaded commit"
[[ "$(git -C "$UPLOAD_ROOT" rev-parse HEAD)" != "$release_commit_before_curl" ]] || \
  fail "fake curl did not advance HEAD"

git -C "$UPLOAD_ROOT" tag -d "$TAG" >/dev/null
git -C "$UPLOAD_ROOT" tag -a "$TAG" -m 'Fixture Extension 1.0'
tag_ref_before="$(git -C "$UPLOAD_ROOT" rev-parse "refs/tags/$TAG")"
run_release >"$TMP_ROOT/same-head-release.out"
grep -q 'Tag already exists at release commit' "$TMP_ROOT/same-head-release.out" || \
  fail "same-HEAD rerun was not identified"
[[ "$(curl_count)" == "3" ]] || fail "same-HEAD rerun did not reach fake curl exactly once"
[[ "$(git -C "$UPLOAD_ROOT" rev-parse "refs/tags/$TAG")" == "$tag_ref_before" ]] || \
  fail "same-HEAD rerun replaced the existing tag"

mkdir -p "$UPLOAD_ROOT/media/icons"
printf '/media/icons/com.example.fixture.png\n' >>"$UPLOAD_ROOT/.git/info/exclude"
printf 'ignored media\n' >"$UPLOAD_ROOT/media/icons/com.example.fixture.png"
run_upload >"$TMP_ROOT/ignored-media-upload.out"
[[ "$(curl_count)" == "4" ]] || fail "ignored-media upload did not reach fake curl"
[[ ! -s "$MEDIA_LOG" ]] || fail "ignored media was included in curl"
rm "$UPLOAD_ROOT/media/icons/com.example.fixture.png"
: >"$UPLOAD_ROOT/.git/info/exclude"

printf 'tracked media\n' >"$UPLOAD_ROOT/media/icons/com.example.fixture.png"
git -C "$UPLOAD_ROOT" add media/icons/com.example.fixture.png
git -C "$UPLOAD_ROOT" commit -qm 'Add tracked listing media'
run_upload >"$TMP_ROOT/tracked-media-upload.out"
[[ "$(curl_count)" == "5" ]] || fail "tracked-media upload did not reach fake curl"
expected_media_path="$(cd "$UPLOAD_ROOT" && pwd -P)/media/icons/com.example.fixture.png"
logged_media_path="$(cat "$MEDIA_LOG")"
logged_media_path="$(cd "$(dirname "$logged_media_path")" && pwd -P)/$(basename "$logged_media_path")"
[[ "$logged_media_path" == "$expected_media_path" ]] || \
  fail "tracked listing media was not included in curl"

grep -Fq './scripts/tuna-extension upload --scheme "$$SCHEME"' "$ROOT/Makefile" || \
  fail "ext-upload-all bypasses the signing wrapper"
grep -q 'DEFAULT_SIGNING_KEY_OP_REF=' "$ROOT/scripts/tuna-extension" || \
  fail "the extension command has no default signing provider"
if grep -Fq '  "$ROOT/dist/store"' "$ROOT/scripts/upload-extension.sh"; then
  fail "ignored dist/store remains a listing-media source"
fi
grep -q '/bin/rm -P' "$ROOT/scripts/ext-package.sh" || fail "temporary keys are not securely removed"

echo "Release tooling tests pass."
