#!/usr/bin/env bash

ensure_paths_committed() {
  local root="$1"
  shift

  local changes
  if ! changes="$(git -C "$root" status --porcelain=v1 --untracked-files=all -- "$@")"; then
    echo "Failed to inspect release inputs." >&2
    return 1
  fi
  if [[ -n "$changes" ]]; then
    echo "Refusing to upload: release inputs have uncommitted changes:" >&2
    printf '%s\n' "$changes" >&2
    return 1
  fi
}

ensure_head_unchanged() {
  local root="$1"
  local expected_commit="$2"
  local current_commit
  current_commit="$(git -C "$root" rev-parse HEAD)"

  if [[ "$current_commit" != "$expected_commit" ]]; then
    echo "Refusing release: HEAD changed from $expected_commit to $current_commit." >&2
    return 1
  fi

  return 0
}

ensure_tag_available_at_commit() {
  local root="$1"
  local tag="$2"
  local expected_commit="$3"

  if ! git -C "$root" check-ref-format "refs/tags/$tag" >/dev/null 2>&1; then
    echo "Invalid git tag name: $tag" >&2
    return 1
  fi

  if ! git -C "$root" rev-parse --verify "refs/tags/$tag" >/dev/null 2>&1; then
    return 0
  fi

  local tag_commit
  if ! tag_commit="$(git -C "$root" rev-parse "refs/tags/$tag^{commit}" 2>/dev/null)"; then
    echo "Existing tag does not resolve to a commit: $tag" >&2
    return 1
  fi
  if [[ "$tag_commit" != "$expected_commit" ]]; then
    echo "Refusing to upload: existing tag $tag points to $tag_commit, not release HEAD $expected_commit." >&2
    return 1
  fi

  return 0
}

create_annotated_tag() {
  local root="$1"
  local tag="$2"
  local message="$3"
  local commit="$4"

  ensure_tag_available_at_commit "$root" "$tag" "$commit" || return 1

  if git -C "$root" rev-parse --verify "refs/tags/$tag" >/dev/null 2>&1; then
    echo "Tag already exists at release commit: $tag at $commit"
    return 0
  fi

  git -C "$root" tag -a "$tag" "$commit" -m "$message"
  echo "Tagged release: $tag at $commit"
}
