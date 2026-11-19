#!/usr/bin/env bash
# Store listing copy: STORE.md, CHANGELOG.md, and declaration contents flow from packaging into
# the upload, and an equal-version release with stale listing copy gets a package-free refresh.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/tuna store listing test.XXXXXX")"

cleanup() {
  /bin/rm -rf "$SANDBOX"
}

trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

fail() {
  echo "store-listing-test: $*" >&2
  exit 1
}

# --- Packaging -------------------------------------------------------------------------------

BUNDLE="$SANDBOX/bundle/Example.bundle"
mkdir -p "$BUNDLE/Contents"
python3 - "$BUNDLE/Contents/Info.plist" <<'PY'
import plistlib
import sys

with open(sys.argv[1], "wb") as fh:
    plistlib.dump({
        "CFBundleIdentifier": "com.example.listing",
        "CFBundleName": "Example",
        "CFBundleShortVersionString": "1.2",
        "LSMinimumSystemVersion": "15.0",
    }, fh)
PY

cat >"$SANDBOX/declaration.json" <<'EOF'
{
  "identifier": "com.example.listing",
  "name": "Example",
  "author": "Tests",
  "description": "Find examples fast.",
  "type": "extension",
  "catalogs": ["example.items"],
  "action_catalogs": [],
  "compatibility": {"min_tuna": "0.95", "min_tunakit": "1.21.0"},
  "contents": {
    "catalogs": [{"id": "example.items", "name": "Examples", "description": null,
                  "presentation": "source", "contents_catalog_id": null, "extra": "dropped"}],
    "action_catalogs": [{"id": "example.actions", "name": "Example Actions",
                         "actions": [{"id": "send", "title": "Send", "symbol": "paperplane"}]}],
    "settings": [],
    "connections": []
  },
  "works_with_bundle_ids": ["com.example.app", "com.example.app", "com.example.other"]
}
EOF

cat >"$SANDBOX/STORE.md" <<'EOF'
---
categories: [productivity]
warnings: [automation, network]
support_url: https://example.com/support
---
Browse **Examples** and send them anywhere.

It needs Example.app.
EOF

cat >"$SANDBOX/CHANGELOG.md" <<'EOF'
# Example Changelog

## Unreleased

- Upcoming change.

## 1.2

- Shipped change.
- Another one.

## 1.1

- Old change.
EOF

package() {
  "$ROOT/scripts/package-tunaextension.py" \
    --bundle "$BUNDLE" --out "$SANDBOX/dist" --arch arm64 \
    --declaration-json "$SANDBOX/declaration.json" \
    --store-metadata "$SANDBOX/STORE.md" --changelog "$SANDBOX/CHANGELOG.md" "$@"
}

package >"$SANDBOX/item.json"
python3 - "$SANDBOX/item.json" <<'PY'
import json
import sys

item = json.load(open(sys.argv[1]))
assert item["summary"] == "Find examples fast.", item["summary"]
assert item["description"] == "Browse **Examples** and send them anywhere.\n\nIt needs Example.app.", item["description"]
assert item["release_notes"] == "- Shipped change.\n- Another one.", item["release_notes"]
assert item["categories"] == ["productivity"], item["categories"]
assert item["warnings"] == ["automation", "network"], item["warnings"]
assert item["support_url"] == "https://example.com/support"
assert item["developer_url"] is None and item["privacy_url"] is None
assert item["works_with_bundle_ids"] == ["com.example.app", "com.example.other"]
catalog = item["contents"]["catalogs"][0]
assert "extra" not in catalog and catalog["name"] == "Examples", catalog
assert item["contents"]["action_catalogs"][0]["actions"][0]["title"] == "Send"
PY

# A version without its own CHANGELOG section ships the Unreleased notes.
sed -i '' 's/<string>1.2</<string>1.3</' "$BUNDLE/Contents/Info.plist"
package | python3 -c 'import json,sys; n=json.load(sys.stdin)["release_notes"]; assert n == "- Upcoming change.", n'

# Without STORE.md or CHANGELOG.md the listing copy is simply absent.
"$ROOT/scripts/package-tunaextension.py" --bundle "$BUNDLE" --out "$SANDBOX/dist" --arch arm64 \
  --declaration-json "$SANDBOX/declaration.json" \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["description"] is None and d["release_notes"] is None and d["categories"] == [], d'

# Unknown warnings, categories, or fields fail packaging.
for bad in 'warnings: [telepathy]' 'categories: [games]' 'colour: blue'; do
  printf -- '---\n%s\n---\nBody\n' "$bad" >"$SANDBOX/BAD.md"
  if "$ROOT/scripts/package-tunaextension.py" --bundle "$BUNDLE" --out "$SANDBOX/dist" \
    --arch arm64 --declaration-json "$SANDBOX/declaration.json" \
    --store-metadata "$SANDBOX/BAD.md" >/dev/null 2>"$SANDBOX/stderr"; then
    fail "packaging accepted STORE.md with '$bad'"
  fi
  grep -q 'Invalid store metadata' "$SANDBOX/stderr"
done

# --- Upload ----------------------------------------------------------------------------------

REPO="$SANDBOX/repo"
mkdir -p "$REPO/scripts" "$REPO/AExtension/A.xcodeproj" "$REPO/bin" "$REPO/dist/store"
cp \
  "$ROOT/scripts/upload-extension.sh" \
  "$ROOT/scripts/extension-shared-package.sh" \
  "$ROOT/scripts/git-tag-helpers.sh" \
  "$REPO/scripts/"
printf '' >"$REPO/.gitignore"
printf '' >"$REPO/Makefile"
printf '{ objects = {}; }\n' >"$REPO/AExtension/A.xcodeproj/project.pbxproj"
cat >"$REPO/scripts/resolve-extension-scheme.sh" <<'EOF'
#!/usr/bin/env bash
root="$(cd "$(dirname "$0")/.." && pwd)"
printf '%s/%s/%s.xcodeproj\t%s\n' "$root" "$1" "${1%Extension}" "$1"
EOF
chmod +x "$REPO/scripts/"*.sh

# Package bytes, candidate metadata, and the store as it was before listing copy existed.
python3 - "$REPO" "$SANDBOX/item.json" <<'PY'
import hashlib
import json
from pathlib import Path
import sys
import zipfile

root = Path(sys.argv[1])
item = json.load(open(sys.argv[2]))
signature = {"signature_base64": "test-signature"}
package = root / "dist/store/com.example.listing-1.2.tunaextension"
with zipfile.ZipFile(package, "w") as archive:
    archive.writestr("store-signature.json", json.dumps(signature))
    archive.writestr("payload", "bytes")
(root / "public.zip").write_bytes(package.read_bytes())
item["download"] = {
    "size_bytes": package.stat().st_size,
    "checksum_sha256": hashlib.sha256(package.read_bytes()).hexdigest(),
    "signature": signature,
    "url": "https://store.invalid/public.zip",
}
(root / "metadata.json").write_text(json.dumps(item))

stale = dict(item, description=None, release_notes=None, support_url=None, categories=[],
             warnings=[], contents=None, works_with_bundle_ids=[], screenshots=[])
(root / "stale.json").write_text(json.dumps({"schema_version": "1", "data": {"item": stale}}))
fresh = dict(item, screenshots=[])
(root / "fresh.json").write_text(json.dumps({"schema_version": "1", "data": {"item": fresh}}))
PY

# Fake curl: serves the store item (404, stale, or fresh after a PUT), the public artifact, and
# records every PUT's arguments.
cat >"$REPO/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
output=""
put=0
artifact=0
args=("$@")
while [[ $# -gt 0 ]]; do
  case "$1" in
    https://store.invalid/public.zip) artifact=1 ;;
    -o) output="$2"; shift ;;
    -X) put=1 ;;
  esac
  shift
done
if [[ "$artifact" == 1 ]]; then
  cp "$root/public.zip" "$output"
  printf '200'
elif [[ "$put" == 1 ]]; then
  printf '%s\n' "${args[@]}" >"$root/put.log"
  touch "$root/put.done"
  cp "$root/fresh.json" "$output"
  printf '200'
elif [[ -e "$root/put.done" || "${STORE_STATE:-}" == fresh ]]; then
  cp "$root/fresh.json" "$output"
  printf '200'
elif [[ "${STORE_STATE:-}" == missing ]]; then
  printf '{}' >"$output"
  printf '404'
else
  cp "$root/stale.json" "$output"
  printf '200'
fi
EOF
chmod +x "$REPO/bin/curl"

git -C "$REPO" init -q
git -C "$REPO" config user.name Test
git -C "$REPO" config user.email test@example.com
git -C "$REPO" add .
git -C "$REPO" commit -qm initial

upload() {
  rm -f "$REPO/put.log" "$REPO/put.done"
  PATH="$REPO/bin:$PATH" RELEASE_UPLOAD_TOKEN=test-token RELEASE_UPLOAD_TOKEN_OP= \
    STORE_API_URL=https://store.invalid/api/v1/items \
    TUNA_RELEASE_PACKAGE_METADATA="$REPO/metadata.json" \
    "$REPO/scripts/upload-extension.sh" AExtension >"$SANDBOX/stdout" 2>"$SANDBOX/stderr" \
    || { cat "$SANDBOX/stdout" "$SANDBOX/stderr" >&2; fail "upload failed ($*)"; }
}

assert_listing_sent() {
  grep -q '^store_item\[description\]=Browse \*\*Examples\*\*' "$REPO/put.log" || fail "description not sent"
  grep -q '^store_item\[release_notes\]=- Shipped change.' "$REPO/put.log" || fail "release notes not sent"
  grep -qx 'store_item\[support_url\]=https://example.com/support' "$REPO/put.log" || fail "support URL not sent"
  grep -qx 'store_item\[categories\]\[\]=productivity' "$REPO/put.log" || fail "category not sent"
  grep -qx 'store_item\[warnings\]\[\]=network' "$REPO/put.log" || fail "warning not sent"
  grep -qx 'store_item\[works_with_bundle_ids\]\[\]=com.example.other' "$REPO/put.log" || fail "works-with not sent"
  grep -q '^store_item\[contents\]={"action_catalogs"' "$REPO/put.log" || fail "contents not sent"
  ! grep -q 'store_item\[developer_url\]' "$REPO/put.log" || fail "an empty developer URL was sent"
}

# Same version, same bytes, stale listing: refresh the listing without re-uploading the package.
upload refresh
grep -q 'will be refreshed: description differs' "$SANDBOX/stdout" || fail "refresh not announced"
grep -q 'Verified refreshed store listing' "$SANDBOX/stdout" || fail "refresh not verified"
assert_listing_sent
! grep -q 'store_item\[asset\]' "$REPO/put.log" || fail "a listing refresh re-uploaded the package"

# Same version with a current listing: no write at all.
STORE_STATE=fresh upload current
grep -q 'listing for com.example.listing 1.2 is current; skipping PUT' "$SANDBOX/stdout" \
  || fail "current listing was not skipped"
[[ ! -e "$REPO/put.log" ]] || fail "a current listing was written"

# First release: package and listing go up together.
STORE_STATE=missing upload first
grep -q 'Verified public store release' "$SANDBOX/stdout" || fail "first release not verified"
assert_listing_sent
grep -q '^store_item\[asset\]=@' "$REPO/put.log" || fail "first release did not upload the package"

echo "Store listing tests pass."
