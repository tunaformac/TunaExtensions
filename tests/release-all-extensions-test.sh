#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/tuna-release-all-test.XXXXXX")"

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
  "$SANDBOX/Shared.xcworkspace/xcshareddata/swiftpm"
cp \
  "$ROOT/scripts/release-all-extensions.sh" \
  "$ROOT/scripts/git-tag-helpers.sh" \
  "$SANDBOX/scripts/"
printf '' >"$SANDBOX/.gitignore"
printf '' >"$SANDBOX/Makefile"
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

echo "Release-all regression tests pass."
