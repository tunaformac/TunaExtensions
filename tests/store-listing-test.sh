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
    "settings": [{"key": "token", "label": "  Token  ", "kind": "secret", "description": "   ",
                  "catalog_id": null}],
    "connections": []
  },
  "works_with_bundle_ids": ["com.example.app", " com.example.app ", "com.example.other", "  "]
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
assert item["unreleased_release_notes"] == "- Upcoming change.", item["unreleased_release_notes"]
assert set(item["managed_listing_fields"]) == {
    "description", "developer_url", "support_url", "privacy_url", "categories", "tags", "warnings",
    "requires_app", "works_with_bundle_ids",
}, item["managed_listing_fields"]
assert item["requires_app"] is False, item["requires_app"]
assert item["categories"] == ["productivity"], item["categories"]
assert item["warnings"] == ["automation", "network"], item["warnings"]
assert item["support_url"] == "https://example.com/support"
assert item["developer_url"] is None and item["privacy_url"] is None
assert item["works_with_bundle_ids"] == ["com.example.app", "com.example.other"]
catalog = item["contents"]["catalogs"][0]
assert "extra" not in catalog and catalog["name"] == "Examples", catalog
assert item["contents"]["action_catalogs"][0]["actions"][0]["title"] == "Send"
# Text is trimmed and blank text becomes null, as the store normalizes it.
setting = item["contents"]["settings"][0]
assert setting["label"] == "Token" and setting["description"] is None, setting
PY

# A version without its own CHANGELOG section has no notes of its own; the uploader decides
# whether the Unreleased notes apply.
sed -i '' 's/<string>1.2</<string>1.3</' "$BUNDLE/Contents/Info.plist"
package | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["release_notes"] is None and d["unreleased_release_notes"] == "- Upcoming change.", d'
sed -i '' 's/<string>1.3</<string>1.2</' "$BUNDLE/Contents/Info.plist"

# Without STORE.md or CHANGELOG.md the listing copy is simply absent.
"$ROOT/scripts/package-tunaextension.py" --bundle "$BUNDLE" --out "$SANDBOX/dist" --arch arm64 \
  --declaration-json "$SANDBOX/declaration.json" \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["description"] is None and d["release_notes"] is None and d["categories"] == [] and d["managed_listing_fields"] == ["works_with_bundle_ids"] and d["requires_app"] is None, d'

# Unknown warnings, categories, or fields fail packaging.
for bad in 'warnings: [telepathy]' 'categories: [games]' 'colour: blue' 'requires_app: yes'; do
  printf -- '---\n%s\n---\nBody\n' "$bad" >"$SANDBOX/BAD.md"
  if "$ROOT/scripts/package-tunaextension.py" --bundle "$BUNDLE" --out "$SANDBOX/dist" \
    --arch arm64 --declaration-json "$SANDBOX/declaration.json" \
    --store-metadata "$SANDBOX/BAD.md" >/dev/null 2>"$SANDBOX/stderr"; then
    fail "packaging accepted STORE.md with '$bad'"
  fi
  grep -q 'Invalid store metadata' "$SANDBOX/stderr"
done

# requires_app: true marks an extension that does nothing without its app.
printf -- '---\nrequires_app: true\n---\nBody\n' >"$SANDBOX/REQUIRES.md"
"$ROOT/scripts/package-tunaextension.py" --bundle "$BUNDLE" --out "$SANDBOX/dist" --arch arm64 \
  --declaration-json "$SANDBOX/declaration.json" --store-metadata "$SANDBOX/REQUIRES.md" \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["requires_app"] is True, d'

# --- Upload ----------------------------------------------------------------------------------

REPO="$SANDBOX/repo"
mkdir -p "$REPO/scripts" "$REPO/AExtension/A.xcodeproj" "$REPO/bin" "$REPO/dist/store" "$REPO/states"
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

# A fake store that keeps one item and applies each PUT the way the server does: blank text
# becomes null, an empty list value clears the list, and a new version starts a release without
# notes, contents, or works-with apps.
cat >"$REPO/bin/fake_store.py" <<'EOF'
import json
import re

TEXT = {"description", "developer_url", "support_url", "privacy_url", "release_notes",
        "name", "summary", "developer_name"}
LISTS = {"categories", "tags", "warnings", "works_with_bundle_ids"}


def apply_put(item, form, download):
    item = json.loads(json.dumps(item))
    version = dict(form).get("version")
    if version and version != item.get("version"):
        item.update(version=version, release_notes=None, contents=None, works_with_bundle_ids=[])
    lists = {}
    for key, value in form:
        name = key.removesuffix("[]")
        if key == "asset":
            item["download"] = download
        elif name in LISTS:
            lists.setdefault(name, [])
            if value.strip():
                lists[name].append(value.strip())
        elif key in TEXT:
            item[key] = value.strip() or None
        elif key == "requires_app":
            item[key] = value == "true"
        elif key == "contents":
            item[key] = json.loads(value)
    item.update(lists)
    return item


def parse_form(args):
    form = []
    for flag, value in zip(args, args[1:]):
        if flag in {"--form-string", "--form"}:
            match = re.fullmatch(r"store_item\[(\w+)\](\[\])?=(.*)", value, re.S)
            if match:
                form.append((match[1] + (match[2] or ""), match[3]))
    return form
EOF

python3 - "$REPO" "$SANDBOX/item.json" <<'PY'
import hashlib
import json
from pathlib import Path
import sys
import zipfile

root = Path(sys.argv[1])
sys.path.insert(0, str(root / "bin"))
from fake_store import apply_put

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


def write(name, value):
    (root / name).write_text(json.dumps(value))


def state(name, value):
    write(f"states/{name}.json", dict(value, screenshots=[]))


write("download.json", item["download"])
# The candidate as packaged, and two variants: a version whose CHANGELOG has no section of its
# own (only Unreleased notes), and one whose STORE.md lost its description and lists.
write("metadata.json", item)
unreleased = dict(item, release_notes=None)
write("metadata-unreleased.json", unreleased)
write("metadata-cleared.json", dict(item, description=None, categories=[], warnings=[]))
write("metadata-requires-app.json", dict(item, requires_app=True))

# The store before listing copy existed, after a full upload of the candidate, holding an older
# version, and holding this version with notes published before Unreleased moved on.
stale = dict(item, description=None, release_notes=None, support_url=None, categories=[],
             warnings=[], contents=None, works_with_bundle_ids=[])
state("stale", stale)
state("fresh", item)
state("older", dict(item, version="1.1", download=dict(item["download"], checksum_sha256="0" * 64)))
state("published", dict(item, release_notes="- Notes as published."))
state("published-stale", dict(stale, release_notes="- Notes as published."))
PY

# Fake curl: serves the store item (from STORE_STATE until a PUT changes it, or 404 for
# "missing"), the public artifact, and records every PUT's arguments.
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
  exit 0
fi
current="$root/states/${STORE_STATE:-stale}.json"
[[ -e "$root/store.json" ]] && current="$root/store.json"
if [[ "$put" == 1 ]]; then
  printf '%s\n' "${args[@]}" >"$root/put.log"
  python3 - "$root" "$current" "${args[@]}" <<'PY'
import json
import os
import sys

root, current, *args = sys.argv[1:]
sys.path.insert(0, os.path.join(root, "bin"))
from fake_store import apply_put, parse_form

# A first release builds the item from the upload; the stale state holds those same fields.
item = json.load(open(current if os.path.exists(current) else os.path.join(root, "states/stale.json")))
download = json.load(open(os.path.join(root, "download.json")))
item = apply_put(item, parse_form(args), download)
json.dump(item, open(os.path.join(root, "store.json"), "w"))
PY
  current="$root/store.json"
elif [[ ! -e "$current" ]]; then
  printf '{}' >"$output"
  printf '404'
  exit 0
fi
python3 -c 'import json,sys; print(json.dumps({"schema_version": "1", "data": {"item": json.load(open(sys.argv[1]))}}))' \
  "$current" >"$output"
printf '200'
EOF
chmod +x "$REPO/bin/curl"

git -C "$REPO" init -q
git -C "$REPO" config user.name Test
git -C "$REPO" config user.email test@example.com
git -C "$REPO" add .
git -C "$REPO" commit -qm initial

run_upload() {
  rm -f "$REPO/put.log" "$REPO/store.json"
  PATH="$REPO/bin:$PATH" RELEASE_UPLOAD_TOKEN=test-token RELEASE_UPLOAD_TOKEN_OP= \
    STORE_API_URL=https://store.invalid/api/v1/items \
    TUNA_RELEASE_PACKAGE_METADATA="$REPO/${METADATA:-metadata.json}" \
    "$REPO/scripts/upload-extension.sh" AExtension >"$SANDBOX/stdout" 2>"$SANDBOX/stderr"
}

upload() {
  run_upload || { cat "$SANDBOX/stdout" "$SANDBOX/stderr" >&2; fail "upload failed ($*)"; }
}

sent() {
  grep -qxF -- "$1" "$REPO/put.log" || fail "not sent: $1"
}

not_sent() {
  ! grep -qF -- "$1" "$REPO/put.log" || fail "sent unexpectedly: $1"
}

stored() {
  python3 -c "import json,sys; d=json.load(open(sys.argv[1])); assert $1, d" "$REPO/store.json" \
    || fail "store does not hold: $1"
}

assert_listing_sent() {
  grep -q '^store_item\[description\]=Browse \*\*Examples\*\*' "$REPO/put.log" || fail "description not sent"
  grep -q '^store_item\[release_notes\]=- Shipped change.' "$REPO/put.log" || fail "release notes not sent"
  sent 'store_item[support_url]=https://example.com/support'
  sent 'store_item[categories][]=productivity'
  sent 'store_item[warnings][]=network'
  sent 'store_item[works_with_bundle_ids][]=com.example.other'
  grep -q '^store_item\[contents\]={"action_catalogs"' "$REPO/put.log" || fail "contents not sent"
  # STORE.md manages its links, so an unset one is sent empty and clears the store's value.
  sent 'store_item[developer_url]='
  sent 'store_item[tags]='
  sent 'store_item[requires_app]=false'
}

# Same version, same bytes, stale listing: refresh the listing without re-uploading the package.
upload refresh
grep -q 'will be refreshed: description differs' "$SANDBOX/stdout" || fail "refresh not announced"
grep -q 'Verified refreshed store listing' "$SANDBOX/stdout" || fail "refresh not verified"
assert_listing_sent
not_sent 'store_item[asset]'

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

# --- Unreleased notes apply only to a new version ---------------------------------------------

# A published version without its own CHANGELOG section keeps its published notes: they aren't
# drift, and a refresh for other copy leaves them alone.
STORE_STATE=published METADATA=metadata-unreleased.json upload published-current
grep -q 'is current; skipping PUT' "$SANDBOX/stdout" || fail "published notes counted as drift"
STORE_STATE=published-stale METADATA=metadata-unreleased.json upload published-refresh
grep -q 'will be refreshed: description differs' "$SANDBOX/stdout" || fail "refresh not announced"
not_sent 'store_item[release_notes]'
stored 'd["release_notes"] == "- Notes as published."'

# A new version without its own section ships the Unreleased notes, first release or not.
for state in older missing; do
  STORE_STATE=$state METADATA=metadata-unreleased.json upload "unreleased over $state"
  grep -q 'Verified public store release' "$SANDBOX/stdout" || fail "new version not verified"
  sent 'store_item[release_notes]=- Upcoming change.'
  stored 'd["release_notes"] == "- Upcoming change." and d["version"] == "1.2"'
done

# --- Removing copy from STORE.md clears it in the store ---------------------------------------

STORE_STATE=fresh METADATA=metadata-cleared.json upload cleared
grep -q 'will be refreshed: description differs; categories differs; warnings differs' "$SANDBOX/stdout" \
  || fail "removed copy was not noticed"
sent 'store_item[description]='
sent 'store_item[categories]='
sent 'store_item[warnings]='
stored 'd["description"] is None and d["categories"] == [] and d["warnings"] == []'
grep -q 'Verified refreshed store listing' "$SANDBOX/stdout" || fail "cleared listing not verified"

# --- STORE.md's requires_app is sent and checked like the rest of the listing ----------------

STORE_STATE=fresh METADATA=metadata-requires-app.json upload requires-app
grep -q 'will be refreshed: requires_app differs' "$SANDBOX/stdout" || fail "requires_app drift not noticed"
sent 'store_item[requires_app]=true'
stored 'd["requires_app"] is True'
grep -q 'Verified refreshed store listing' "$SANDBOX/stdout" || fail "requires_app not verified"

# --- Preflight checks the release tag the real run will use -----------------------------------

TAG_NAME=extensions/com.example.listing/v1.2
preflight() {
  CREATE_GIT_TAG=1 TUNA_RELEASE_PREFLIGHT_ONLY=1 run_upload
}

# An unchanged release creates its missing tag, or reuses an annotated one wherever it points.
STORE_STATE=fresh preflight || fail "preflight refused an unchanged release without a tag"
git -C "$REPO" tag -a "$TAG_NAME" -m 'Example 1.2'
git -C "$REPO" commit -q --allow-empty -m later
STORE_STATE=fresh preflight || fail "preflight refused an unchanged release's earlier tag"
STORE_STATE=stale preflight || fail "preflight refused a listing refresh's earlier tag"
# A new upload can't reuse a tag at another commit.
if STORE_STATE=older preflight; then
  fail "preflight accepted a new release whose tag points elsewhere"
fi
grep -q 'points to' "$SANDBOX/stderr" || fail "moved tag not reported"
# The real run refuses a lightweight tag, so preflight does too.
git -C "$REPO" tag -d "$TAG_NAME" >/dev/null
git -C "$REPO" tag "$TAG_NAME"
if STORE_STATE=fresh preflight; then
  fail "preflight accepted an unchanged release with a lightweight tag"
fi
grep -q 'must be annotated' "$SANDBOX/stderr" || fail "lightweight tag not reported"

echo "Store listing tests pass."
