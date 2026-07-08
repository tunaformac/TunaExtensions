#!/usr/bin/env bash

ensure_paths_committed() {
  local root="$1"
  shift

  local path
  for path in "$@"; do
    if ! git -C "$root" diff --quiet -- "$path" || ! git -C "$root" diff --cached --quiet -- "$path"; then
      echo "Refusing to create release tag: $path has uncommitted changes. Commit the release version first." >&2
      return 1
    fi
  done
}

create_annotated_tag() {
  local root="$1"
  local tag="$2"
  local message="$3"

  if ! git -C "$root" check-ref-format "refs/tags/$tag" >/dev/null 2>&1; then
    echo "Invalid git tag name: $tag" >&2
    return 1
  fi

  if git -C "$root" rev-parse --verify "refs/tags/$tag" >/dev/null 2>&1; then
    echo "Tag already exists: $tag"
    return 0
  fi

  git -C "$root" tag -a "$tag" -m "$message"
  echo "Tagged release: $tag"
}
