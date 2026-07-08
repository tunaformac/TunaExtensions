#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET="${1:?Usage: release-extension.sh TARGET}"

CREATE_GIT_TAG=1 "$ROOT/scripts/upload-extension.sh" "$TARGET"
