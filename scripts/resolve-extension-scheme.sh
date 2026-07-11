#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET="${1:-}"
if [[ -z "$TARGET" ]]; then
  echo "Usage: $0 TARGET" >&2
  exit 64
fi

list_schemes() {
  local project="$1"
  xcodebuild -list -project "$project" 2>/dev/null \
    | awk '/Schemes:/ {flag=1; next} flag && NF {print $1} flag && !NF {exit}'
}

declare -a candidates=()
add_candidate() {
  local candidate="$1"
  [[ -n "$candidate" ]] || return

  local existing
  for existing in "${candidates[@]-}"; do
    [[ "$existing" == "$candidate" ]] && return
  done

  candidates+=("$candidate")
}

add_candidate "$TARGET"
if [[ "$TARGET" == *Extension ]]; then
  add_candidate "Tuna${TARGET%Extension}"
elif [[ "$TARGET" == Tuna* ]]; then
  bare="${TARGET#Tuna}"
  add_candidate "$bare"
  add_candidate "${bare}Extension"
  add_candidate "${bare}Theme"
  if [[ "$bare" == *Actions ]]; then
    add_candidate "${bare%Actions}Extension"
  fi
else
  add_candidate "Tuna$TARGET"
fi

declare -a projects=()
while IFS= read -r project; do
  projects+=("$project")
done < <(find "$ROOT" -mindepth 1 -maxdepth 2 -name '*.xcodeproj' -print | sort)

for project in "${projects[@]}"; do
  schemes="$(list_schemes "$project" || true)"
  [[ -z "$schemes" ]] && continue

  for candidate in "${candidates[@]}"; do
    if echo "$schemes" | rg -Fxq "$candidate"; then
      printf '%s\t%s\n' "$project" "$candidate"
      exit 0
    fi
  done
done

echo "Unknown scheme: $TARGET" >&2
echo "Known schemes by project:" >&2
for project in "${projects[@]}"; do
  schemes="$(list_schemes "$project" || true)"
  [[ -z "$schemes" ]] && continue
  echo "  $project" >&2
  while IFS= read -r scheme; do
    [[ -n "$scheme" ]] && echo "    $scheme" >&2
  done <<< "$schemes"
done
exit 1
