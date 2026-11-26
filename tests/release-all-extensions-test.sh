#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/tuna release all test.XXXXXX")"

cleanup() {
  /bin/rm -rf "$SANDBOX"
}

trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

mkdir -p \
  "$SANDBOX/scripts" \
  "$SANDBOX/AExtension/A.xcodeproj" \
  "$SANDBOX/BExtension/B.xcodeproj" \
  "$SANDBOX/ChromiumExtensionSupport" \
  "$SANDBOX/Shared.xcworkspace/xcshareddata/swiftpm"
cp \
  "$ROOT/scripts/release-all-extensions.sh" \
  "$ROOT/scripts/upload-extension.sh" \
  "$ROOT/scripts/extension-shared-package.sh" \
  "$ROOT/scripts/git-tag-helpers.sh" \
  "$SANDBOX/scripts/"
printf '' >"$SANDBOX/.gitignore"
printf '' >"$SANDBOX/Makefile"
cat >"$SANDBOX/AExtension/A.xcodeproj/project.pbxproj" <<'EOF'
{ objects = {
    SHARED = { isa = XCLocalSwiftPackageReference; relativePath = "../ChromiumExtensionSupport"; };
}; }
EOF
printf '{ objects = {}; }\n' >"$SANDBOX/BExtension/B.xcodeproj/project.pbxproj"
printf '// shared package\n' >"$SANDBOX/ChromiumExtensionSupport/Package.swift"
printf 'clean\n' >"$SANDBOX/AExtension/Package.resolved"
printf 'clean\n' >"$SANDBOX/BExtension/Package.resolved"
printf 'clean\n' >"$SANDBOX/Shared.xcworkspace/xcshareddata/swiftpm/Package.resolved"

cat >"$SANDBOX/scripts/resolve-extension-scheme.sh" <<'EOF'
#!/usr/bin/env bash
root="$(cd "$(dirname "$0")/.." && pwd)"
printf '%s/%s/%s.xcodeproj\t%s\n' "$root" "$1" "${1%Extension}" "$1"
EOF

cat >"$SANDBOX/scripts/tuna-extension" <<'EOF'
#!/usr/bin/env bash
root="$(cd "$(dirname "$0")/.." && pwd)"
target="$3"
printf 'package %s\n' "$target" >>"$root/order.log"
if [[ "${MUTATE_PACKAGE_RESOLVED:-0}" == "1" && "$target" == "BExtension" ]]; then
  printf 'dirty\n' >>"$root/Shared.xcworkspace/xcshareddata/swiftpm/Package.resolved"
fi
if [[ "${MUTATE_SHARED_PACKAGE:-0}" == "1" && "$target" == "BExtension" ]]; then
  printf '// changed during packaging\n' >>"$root/ChromiumExtensionSupport/Package.swift"
fi
printf '{"id":"%s","name":"%s","version":"1","compatibility":{}}\n' \
  "$target" "$target"
EOF

cat >"$SANDBOX/scripts/release-extension.sh" <<'EOF'
#!/usr/bin/env bash
root="$(cd "$(dirname "$0")/.." && pwd)"
test -s "$TUNA_RELEASE_PACKAGE_METADATA"
if [[ "${TUNA_RELEASE_PREFLIGHT_ONLY:-0}" == "1" ]]; then
  phase="preflight"
else
  phase="publish"
fi
printf '%s %s\n' "$phase" "$1" >>"$root/order.log"
EOF

chmod +x "$SANDBOX/scripts/"*.sh "$SANDBOX/scripts/tuna-extension"
git -C "$SANDBOX" init -q
git -C "$SANDBOX" config user.name Test
git -C "$SANDBOX" config user.email test@example.com
git -C "$SANDBOX" add .
git -C "$SANDBOX" commit -qm initial

"$SANDBOX/scripts/release-all-extensions.sh" AExtension BExtension >/dev/null
EXPECTED_ORDER="$(cat <<'EOF'
package AExtension
package BExtension
preflight AExtension
preflight BExtension
publish AExtension
publish BExtension
EOF
)"
if [[ "$(cat "$SANDBOX/order.log")" != "$EXPECTED_ORDER" ]]; then
  echo "release-all did not prepare and preflight every extension before publishing." >&2
  exit 1
fi

# A dry run prepares and preflights everything, then publishes nothing.
rm -f "$SANDBOX/order.log"
TUNA_RELEASE_DRY_RUN=1 "$SANDBOX/scripts/release-all-extensions.sh" AExtension BExtension >/dev/null
if [[ "$(cat "$SANDBOX/order.log")" != "$(printf '%s\n' "$EXPECTED_ORDER" | grep -v '^publish')" ]]; then
  echo "release-all published during a dry run." >&2
  exit 1
fi

git -C "$SANDBOX" checkout -q -- .
rm -f "$SANDBOX/order.log"
if MUTATE_PACKAGE_RESOLVED=1 \
  "$SANDBOX/scripts/release-all-extensions.sh" AExtension BExtension \
    >"$SANDBOX/stdout" 2>"$SANDBOX/stderr"
then
  echo "release-all accepted a packaging-time Package.resolved mutation." >&2
  exit 1
fi

EXPECTED_FAILURE_ORDER="$(cat <<'EOF'
package AExtension
package BExtension
EOF
)"
if [[ "$(cat "$SANDBOX/order.log")" != "$EXPECTED_FAILURE_ORDER" ]]; then
  echo "release-all reached store preflight after Package.resolved changed." >&2
  exit 1
fi
if ! grep -q 'Package.resolved' "$SANDBOX/stderr"; then
  echo "release-all did not report the changed Package.resolved." >&2
  exit 1
fi

# Shared sources are checked before packaging and again after all packages are prepared.
git -C "$SANDBOX" checkout -q -- .
rm -f "$SANDBOX/order.log"
if MUTATE_SHARED_PACKAGE=1 \
  "$SANDBOX/scripts/release-all-extensions.sh" AExtension BExtension \
    >"$SANDBOX/stdout" 2>"$SANDBOX/stderr"
then
  echo "release-all accepted a packaging-time shared package mutation." >&2
  exit 1
fi
[[ "$(cat "$SANDBOX/order.log")" == "$EXPECTED_FAILURE_ORDER" ]]
grep -q 'ChromiumExtensionSupport/Package.swift' "$SANDBOX/stderr"

for change in unstaged staged untracked deleted; do
  git -C "$SANDBOX" reset -q HEAD -- ChromiumExtensionSupport
  git -C "$SANDBOX" checkout -q -- ChromiumExtensionSupport
  rm -f "$SANDBOX/ChromiumExtensionSupport/New.swift" "$SANDBOX/order.log"
  case "$change" in
    unstaged|staged) printf '// changed\n' >>"$SANDBOX/ChromiumExtensionSupport/Package.swift" ;;
    untracked) printf '// new\n' >"$SANDBOX/ChromiumExtensionSupport/New.swift" ;;
    deleted) rm "$SANDBOX/ChromiumExtensionSupport/Package.swift" ;;
  esac
  if [[ "$change" == staged ]]; then
    git -C "$SANDBOX" add ChromiumExtensionSupport
  fi
  for script in release-all-extensions.sh upload-extension.sh; do
    if TUNA_RELEASE_PACKAGE_METADATA="$SANDBOX/missing.json" \
      "$SANDBOX/scripts/$script" AExtension >"$SANDBOX/stdout" 2>"$SANDBOX/stderr"
    then
      echo "$script accepted $change shared package changes." >&2
      exit 1
    fi
    grep -q 'release inputs have uncommitted changes' "$SANDBOX/stderr"
    grep -q 'ChromiumExtensionSupport/' "$SANDBOX/stderr"
  done
  [[ ! -e "$SANDBOX/order.log" ]]

  # A project without the reference must not acquire the shared package as an input.
  "$SANDBOX/scripts/release-all-extensions.sh" BExtension >/dev/null
  if TUNA_RELEASE_PACKAGE_METADATA="$SANDBOX/missing.json" \
    "$SANDBOX/scripts/upload-extension.sh" BExtension >"$SANDBOX/stdout" 2>"$SANDBOX/stderr"
  then
    echo "upload accepted missing package metadata." >&2
    exit 1
  fi
  grep -q 'Prepared package metadata not found' "$SANDBOX/stderr"
done
git -C "$SANDBOX" checkout -q -- ChromiumExtensionSupport
rm -f "$SANDBOX/ChromiumExtensionSupport/New.swift"

# Exercise the real upload preflight with a differing public artifact. Its tagged-source
# fallback can accept a rebuild only while the shared package also matches the release tag.
mkdir -p "$SANDBOX/bin" "$SANDBOX/dist/store" "$SANDBOX/UnrelatedExtension"
printf 'unrelated\n' >"$SANDBOX/UnrelatedExtension/untracked.txt"
python3 - "$SANDBOX" <<'PY'
import hashlib
import json
from pathlib import Path
import sys
import zipfile

root = Path(sys.argv[1])
item = {
    "id": "browser", "name": "Browser", "version": "1", "summary": "Browser extension",
    "type": "extension", "developer_name": "Test",
    "compatibility": {"min_tuna": "1", "min_macos": "14", "arch": ["arm64"]},
}
signature = {"signature_base64": "test-signature"}
for filename, contents in (("dist/store/browser-1.tunaextension", "rebuilt"), ("public.zip", "original")):
    path = root / filename
    with zipfile.ZipFile(path, "w") as archive:
        archive.writestr("store-signature.json", json.dumps(signature))
        archive.writestr("payload", contents)
    item["download"] = {
        "size_bytes": path.stat().st_size,
        "checksum_sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
        "signature": signature, "url": "https://store.invalid/public.zip",
    }
    if contents == "rebuilt":
        (root / "metadata.json").write_text(json.dumps(item))
    else:
        (root / "response.json").write_text(json.dumps({"schema_version": "1", "data": {"item": item}}))
PY
cat >"$SANDBOX/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
source="$root/response.json"
output=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    https://store.invalid/public.zip) source="$root/public.zip" ;;
    -o) output="$2"; shift ;;
    -X|--config) echo 'Unexpected store write or authentication' >&2; exit 1 ;;
  esac
  shift
done
cp "$source" "$output"
printf '200'
EOF
chmod +x "$SANDBOX/bin/curl"
git -C "$SANDBOX" tag -a extensions/browser/v1 -m release

upload_preflight() {
  PATH="$SANDBOX/bin:$PATH" CREATE_GIT_TAG=1 TUNA_RELEASE_PREFLIGHT_ONLY=1 \
    TUNA_RELEASE_PACKAGE_METADATA="$SANDBOX/metadata.json" \
    "$SANDBOX/scripts/upload-extension.sh" AExtension >"$SANDBOX/stdout" 2>"$SANDBOX/stderr"
}
upload_preflight
grep -q 'unchanged tagged source' "$SANDBOX/stdout"
grep -q 'is current; skipping PUT' "$SANDBOX/stdout"
# Auto-release only publishes new versions: an equal store release fails closed.
if TUNA_RELEASE_REQUIRE_UPLOAD=1 upload_preflight; then
  echo "upload accepted an equal version when a new one was required." >&2
  exit 1
fi
grep -q 'is not newer than the store' "$SANDBOX/stderr"
# Listing copy is not built into the bundle, so editing it keeps the tagged source unchanged.
printf 'Listing copy.\n' >"$SANDBOX/AExtension/STORE.md"
git -C "$SANDBOX" add AExtension/STORE.md
git -C "$SANDBOX" commit -qm 'Add listing copy'
upload_preflight
grep -q 'unchanged tagged source' "$SANDBOX/stdout"
printf '// committed shared change\n' >>"$SANDBOX/ChromiumExtensionSupport/Package.swift"
git -C "$SANDBOX" add ChromiumExtensionSupport
git -C "$SANDBOX" commit -qm 'Change shared browser support only'
if upload_preflight; then
  echo "upload reused a tag despite changed shared sources." >&2
  exit 1
fi
grep -q 'differs from the candidate; bump its version' "$SANDBOX/stderr"
[[ "$(cat "$SANDBOX/UnrelatedExtension/untracked.txt")" == unrelated ]]

echo "Release-all regression tests pass."
