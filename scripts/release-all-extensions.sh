#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGETS=("$@")
PREPARED_DIR=""

source "$ROOT/scripts/git-tag-helpers.sh"

if [[ ${#TARGETS[@]} -eq 0 ]]; then
  echo "Usage: $0 TARGET..." >&2
  exit 64
fi

cleanup() {
  if [[ -n "$PREPARED_DIR" && -d "$PREPARED_DIR" ]]; then
    /bin/rm -rf "$PREPARED_DIR"
  fi
}

trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

add_release_input() {
  local candidate="$1"
  local existing

  for existing in "${RELEASE_INPUTS[@]-}"; do
    [[ "$existing" == "$candidate" ]] && return
  done
  RELEASE_INPUTS+=("$candidate")
}

metadata_path_for_target() {
  local target="$1"
  printf '%s/%s.json\n' "$PREPARED_DIR" "${target//[^A-Za-z0-9_.-]/-}"
}

RELEASE_INPUTS=(.gitignore Makefile scripts media)
for TARGET in "${TARGETS[@]}"; do
  read -r PROJECT _ < <("$ROOT/scripts/resolve-extension-scheme.sh" "$TARGET")
  PROJECT="${PROJECT#$ROOT/}"
  add_release_input "$(dirname "$PROJECT")"
done

# Package resolution files can live outside an extension directory (for
# example in a shared workspace), so include every tracked one explicitly.
while IFS= read -r PACKAGE_RESOLVED; do
  [[ -n "$PACKAGE_RESOLVED" ]] && add_release_input "$PACKAGE_RESOLVED"
done < <(git -C "$ROOT" ls-files -- '*Package.resolved')

RELEASE_COMMIT="$(git -C "$ROOT" rev-parse HEAD)"
ensure_paths_committed "$ROOT" "${RELEASE_INPUTS[@]}"

PREPARED_DIR="$(mktemp -d "${TMPDIR:-/tmp}/tuna-release-all.XXXXXX")"
/bin/chmod 700 "$PREPARED_DIR"

for TARGET in "${TARGETS[@]}"; do
  echo "=== Preparing $TARGET ==="
  "$ROOT/scripts/tuna-extension" package --scheme "$TARGET" \
    >"$(metadata_path_for_target "$TARGET")"
done

# Xcode may update Package.resolved while building. Check the complete release
# set only after every package has been built, before any store operation can
# publish an extension.
ensure_paths_committed "$ROOT" "${RELEASE_INPUTS[@]}"
ensure_head_unchanged "$ROOT" "$RELEASE_COMMIT"

for TARGET in "${TARGETS[@]}"; do
  echo "=== Preflighting $TARGET ==="
  TUNA_RELEASE_PACKAGE_METADATA="$(metadata_path_for_target "$TARGET")" \
  TUNA_RELEASE_PREFLIGHT_ONLY=1 \
    "$ROOT/scripts/release-extension.sh" "$TARGET"
done

ensure_paths_committed "$ROOT" "${RELEASE_INPUTS[@]}"
ensure_head_unchanged "$ROOT" "$RELEASE_COMMIT"

for TARGET in "${TARGETS[@]}"; do
  echo "=== Publishing $TARGET ==="
  TUNA_RELEASE_PACKAGE_METADATA="$(metadata_path_for_target "$TARGET")" \
    "$ROOT/scripts/release-extension.sh" "$TARGET"
done
