#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/source.lock"

REQUESTED_REF="${1:-latest-tested}"
WORK_ROOT="${WORK_ROOT:-$ROOT/work}"
OPENWRT_TREE="${OPENWRT_TREE:-$WORK_ROOT/openwrt}"
SOURCE_ENV="${SOURCE_ENV:-$ROOT/source.env}"
TAG_ANNOTATION_FILE="${TAG_ANNOTATION_FILE:-$ROOT/upstream-tag-annotation.md}"
REPOSITORY_URL="https://github.com/${OPENWRT_REPOSITORY}.git"

for command_name in git tr; do
  command -v "$command_name" >/dev/null || {
    echo "Missing dependency: $command_name" >&2
    exit 1
  }
done

resolve_remote_ref() {
  local pattern="$1"
  git ls-remote --exit-code --refs "$REPOSITORY_URL" "$pattern" 2>/dev/null || true
}

source_kind=""
source_ref=""
source_tag=""
tag_object_type=""
rm -f "$TAG_ANNOTATION_FILE"

if [[ "$REQUESTED_REF" == "latest-tested" ]]; then
  latest_line="$(
    git ls-remote --sort='-version:refname' --refs --tags \
      "$REPOSITORY_URL" 'refs/tags/tested-*' | head -n 1
  )"

  if [[ -z "$latest_line" ]]; then
    echo "No tested-* tags currently exist in $OPENWRT_REPOSITORY." >&2
    exit 3
  fi

  read -r _remote_object remote_ref <<<"$latest_line"
  source_kind="tag"
  source_tag="${remote_ref#refs/tags/}"
  source_ref="$source_tag"
elif [[ "$REQUESTED_REF" =~ ^[0-9a-fA-F]{40}$ ]]; then
  source_kind="commit"
  source_ref="${REQUESTED_REF,,}"
else
  tag_line="$(resolve_remote_ref "refs/tags/$REQUESTED_REF")"
  branch_line="$(resolve_remote_ref "refs/heads/$REQUESTED_REF")"

  if [[ -n "$tag_line" ]]; then
    source_kind="tag"
    source_tag="$REQUESTED_REF"
    source_ref="$REQUESTED_REF"
  elif [[ -n "$branch_line" ]]; then
    if [[ "$REQUESTED_REF" != "$OPENWRT_BRANCH" ]]; then
      echo "Only the configured Percival branch is allowed: $OPENWRT_BRANCH" >&2
      exit 1
    fi
    source_kind="branch"
    source_ref="$REQUESTED_REF"
  else
    echo "Source reference does not exist in $OPENWRT_REPOSITORY: $REQUESTED_REF" >&2
    exit 1
  fi
fi

rm -rf "$OPENWRT_TREE"
mkdir -p "$OPENWRT_TREE" "$(dirname "$SOURCE_ENV")" \
  "$(dirname "$TAG_ANNOTATION_FILE")"

git -C "$OPENWRT_TREE" init -q
git -C "$OPENWRT_TREE" remote add origin "$REPOSITORY_URL"

case "$source_kind" in
  tag)
    git -C "$OPENWRT_TREE" fetch --depth=1 --no-tags origin \
      "refs/tags/$source_ref:refs/tags/$source_ref"
    tag_object_type="$(
      git -C "$OPENWRT_TREE" cat-file -t "refs/tags/$source_ref"
    )"

    if [[ "$source_tag" == tested-* && "$tag_object_type" != "tag" ]]; then
      echo "Percival tested-* tags must be annotated tags: $source_tag" >&2
      exit 1
    fi

    source_commit="$(
      git -C "$OPENWRT_TREE" rev-list -n 1 "refs/tags/$source_ref"
    )"

    if [[ "$tag_object_type" == "tag" ]]; then
      git -C "$OPENWRT_TREE" for-each-ref \
        --format='%(contents)' "refs/tags/$source_ref" \
        > "$TAG_ANNOTATION_FILE"
      test -s "$TAG_ANNOTATION_FILE"
    fi
    ;;
  branch)
    git -C "$OPENWRT_TREE" fetch --depth=1 --no-tags origin \
      "refs/heads/$source_ref"
    source_commit="$(git -C "$OPENWRT_TREE" rev-parse FETCH_HEAD)"
    ;;
  commit)
    git -C "$OPENWRT_TREE" fetch --depth=1 --no-tags origin "$source_ref"
    source_commit="$(git -C "$OPENWRT_TREE" rev-parse FETCH_HEAD)"
    if [[ "$source_commit" != "$source_ref" ]]; then
      echo "Requested commit $source_ref resolved to $source_commit" >&2
      exit 1
    fi
    ;;
  *)
    echo "Unsupported source kind: $source_kind" >&2
    exit 1
    ;;
esac

git -C "$OPENWRT_TREE" checkout --detach --force "$source_commit"

resolved_commit="$(git -C "$OPENWRT_TREE" rev-parse HEAD)"
if [[ "$resolved_commit" != "$source_commit" ]]; then
  echo "Checkout verification failed: expected $source_commit, got $resolved_commit" >&2
  exit 1
fi

if [[ -n "$(git -C "$OPENWRT_TREE" status --porcelain)" ]]; then
  echo "Fresh Percival checkout is unexpectedly dirty." >&2
  exit 1
fi

source_date="$(git -C "$OPENWRT_TREE" show -s --format=%cI HEAD)"
source_title="$(git -C "$OPENWRT_TREE" show -s --format=%s HEAD | tr '\r\n' ' ')"
source_short="${source_commit:0:12}"
release_tag=""
has_ap_config="false"

if [[ "$source_kind" == "tag" ]]; then
  release_tag="percival-$source_tag"
fi
if [[ -s "$OPENWRT_TREE/configs/ap.config" ]]; then
  has_ap_config="true"
fi

{
  printf 'OPENWRT_REPOSITORY=%q\n' "$OPENWRT_REPOSITORY"
  printf 'OPENWRT_BRANCH=%q\n' "$OPENWRT_BRANCH"
  printf 'SOURCE_KIND=%q\n' "$source_kind"
  printf 'SOURCE_REF=%q\n' "$source_ref"
  printf 'SOURCE_TAG=%q\n' "$source_tag"
  printf 'SOURCE_COMMIT=%q\n' "$source_commit"
  printf 'SOURCE_SHORT=%q\n' "$source_short"
  printf 'SOURCE_DATE=%q\n' "$source_date"
  printf 'SOURCE_TITLE=%q\n' "$source_title"
  printf 'TAG_OBJECT_TYPE=%q\n' "$tag_object_type"
  printf 'TAG_ANNOTATION_FILE=%q\n' "$TAG_ANNOTATION_FILE"
  printf 'HAS_AP_CONFIG=%q\n' "$has_ap_config"
  printf 'RELEASE_TAG=%q\n' "$release_tag"
} > "$SOURCE_ENV"

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  {
    printf 'source_kind=%s\n' "$source_kind"
    printf 'source_ref=%s\n' "$source_ref"
    printf 'source_tag=%s\n' "$source_tag"
    printf 'source_commit=%s\n' "$source_commit"
    printf 'source_short=%s\n' "$source_short"
    printf 'tag_object_type=%s\n' "$tag_object_type"
    printf 'has_ap_config=%s\n' "$has_ap_config"
    printf 'release_tag=%s\n' "$release_tag"
  } >> "$GITHUB_OUTPUT"
fi

printf 'Resolved %s %s to %s (%s)\n' \
  "$source_kind" "$source_ref" "$source_commit" "$source_title"
