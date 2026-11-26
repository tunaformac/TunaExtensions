#!/usr/bin/env bash
# Usage: needs-newer-macos.sh PROJECT_PBXPROJ
# Prints the project's highest MACOSX_DEPLOYMENT_TARGET and exits 0 when it is newer than the host
# macOS, so its tests can't run here; exits 1 otherwise. TUNA_HOST_MACOS_VERSION overrides the
# host version (sw_vers) for tests.
set -euo pipefail

PROJECT_FILE="${1:-}"
if [[ -z "$PROJECT_FILE" ]]; then
  echo "Usage: $0 PROJECT_PBXPROJ" >&2
  exit 64
fi

HOST="${TUNA_HOST_MACOS_VERSION:-$(sw_vers -productVersion)}"
REQUIRED="$(grep -oE 'MACOSX_DEPLOYMENT_TARGET = "?[0-9.]+' "$PROJECT_FILE" \
  | grep -oE '[0-9.]+$' | sort -t. -k1,1n -k2,2n -k3,3n | tail -n 1)"
[[ -n "$REQUIRED" ]] || exit 1

printf '%s\n' "$REQUIRED"
awk -v required="$REQUIRED" -v host="$HOST" 'BEGIN {
  n = split(required, r, "."); m = split(host, h, ".")
  for (i = 1; i <= (n > m ? n : m); i++) {
    if ((r[i] + 0) > (h[i] + 0)) exit 0
    if ((r[i] + 0) < (h[i] + 0)) exit 1
  }
  exit 1
}'
