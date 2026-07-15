#!/usr/bin/env bash
set -euo pipefail

PROJECT_FILE="${1:-}"
SCHEME_FILE="${2:-}"

if [[ -z "$PROJECT_FILE" || -z "$SCHEME_FILE" ]]; then
  echo "Usage: $0 PROJECT_PBXPROJ SHARED_SCHEME" >&2
  exit 64
fi

if [[ ! -f "$PROJECT_FILE" ]]; then
  echo "error: project file not found: $PROJECT_FILE" >&2
  exit 1
fi

if [[ ! -f "$SCHEME_FILE" ]]; then
  echo "error: shared test scheme not found: $SCHEME_FILE" >&2
  exit 1
fi

project_target_ids="$(awk '
    /^[[:space:]]*[[:xdigit:]]{24} \/\* .* \*\/ = \{$/ {
      target_id = $1
      in_object = 1
      native_target = 0
      unit_test_target = 0
    }
    in_object && /isa = PBXNativeTarget;/ {
      native_target = 1
    }
    in_object && /productType = "com.apple.product-type.bundle.unit-test";/ {
      unit_test_target = 1
    }
    in_object && /^[[:space:]]*};$/ {
      if (native_target && unit_test_target) print toupper(target_id)
      in_object = 0
    }
  ' "$PROJECT_FILE" | sort -u)"

if [[ -z "$project_target_ids" ]]; then
  echo "error: no unit-test targets found in $PROJECT_FILE" >&2
  exit 1
fi

xmllint --noout "$SCHEME_FILE"
scheme_attributes="$(xmllint \
  --xpath '/Scheme/TestAction/Testables/TestableReference[not(@skipped = "YES")]/BuildableReference/@BlueprintIdentifier' \
  "$SCHEME_FILE" 2>/dev/null || true)"
scheme_target_ids="$(printf '%s\n' "$scheme_attributes" \
  | grep -Eo '[[:xdigit:]]{24}' \
  | tr '[:lower:]' '[:upper:]' \
  | sort -u || true)"

if [[ "$project_target_ids" != "$scheme_target_ids" ]]; then
  echo "error: shared scheme does not cover every unit-test target: $SCHEME_FILE" >&2
  echo "project unit-test target IDs:" >&2
  while IFS= read -r target_id; do
    printf '  %s\n' "$target_id" >&2
  done <<< "$project_target_ids"
  echo "scheme test target IDs:" >&2
  if [[ -n "$scheme_target_ids" ]]; then
    while IFS= read -r target_id; do
      printf '  %s\n' "$target_id" >&2
    done <<< "$scheme_target_ids"
  else
    echo "  (none)" >&2
  fi
  echo "Add every project unit-test target to the shared scheme's Test action." >&2
  exit 1
fi
