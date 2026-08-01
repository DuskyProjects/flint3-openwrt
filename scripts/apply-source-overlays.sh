#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
CANDIDATE_SOURCE="${1:?usage: apply-source-overlays.sh <candidate-source> <secondary-commit> <manifest>}"
SECONDARY_COMMIT="${2:?usage: apply-source-overlays.sh <candidate-source> <secondary-commit> <manifest>}"
MANIFEST="${3:?usage: apply-source-overlays.sh <candidate-source> <secondary-commit> <manifest>}"

[[ -d "$CANDIDATE_SOURCE/.git" ]] || {
  echo "Candidate source is not a Git checkout: $CANDIDATE_SOURCE" >&2
  exit 1
}
[[ -s "$PROJECT_ROOT/source-overlays.conf" ]] || {
  echo "source-overlays.conf is missing or empty." >&2
  exit 1
}

git -C "$CANDIDATE_SOURCE" cat-file -e "$SECONDARY_COMMIT^{commit}"
# Patch intake reads this value from the same candidate checkout, ensuring that
# source overlays and the required Kakatkar patch tree come from one revision.
git -C "$CANDIDATE_SOURCE" config nightly.overlayCommit "$SECONDARY_COMMIT"

MERGE_BASE="$(git -C "$CANDIDATE_SOURCE" merge-base HEAD "$SECONDARY_COMMIT" || true)"
[[ -n "$MERGE_BASE" ]] || {
  echo "The base and overlay source trees do not have a common ancestor." >&2
  exit 1
}

mkdir -p "$(dirname "$MANIFEST")"
: > "$MANIFEST"
printf 'SOURCE OVERLAY MANIFEST\n' >> "$MANIFEST"
printf 'secondary-commit=%s\n' "$SECONDARY_COMMIT" >> "$MANIFEST"
printf 'merge-base=%s\n\n' "$MERGE_BASE" >> "$MANIFEST"

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

merged=0
replaced=0
already=0
kept_base=0
missing_optional=0
missing_required=0
conflicts=0

while IFS='|' read -r mode path; do
  [[ -n "$mode" && "$mode" != \#* ]] || continue

  required=0
  replace=0
  case "$mode" in
    required)
      required=1
      ;;
    optional)
      ;;
    replace-required)
      required=1
      replace=1
      ;;
    replace-optional)
      replace=1
      ;;
    *)
      echo "Invalid overlay mode '$mode' for $path" >&2
      exit 1
      ;;
  esac

  [[ -n "$path" ]] || {
    echo "Empty overlay path." >&2
    exit 1
  }
  case "$path" in
    /*|*'..'*)
      echo "Unsafe overlay path: $path" >&2
      exit 1
      ;;
  esac

  if ! git -C "$CANDIDATE_SOURCE" cat-file -e "$SECONDARY_COMMIT:$path" 2>/dev/null; then
    if (( required == 1 )); then
      printf 'MISSING-REQUIRED\t%s\n' "$path" >> "$MANIFEST"
      missing_required=$((missing_required + 1))
    else
      printf 'MISSING-OPTIONAL\t%s\n' "$path" >> "$MANIFEST"
      missing_optional=$((missing_optional + 1))
    fi
    continue
  fi

  safe_name="$(printf '%s' "$path" | sha256sum | awk '{print $1}')"
  current_file="$workdir/$safe_name.current"
  ancestor_file="$workdir/$safe_name.ancestor"
  overlay_file="$workdir/$safe_name.overlay"
  merged_file="$workdir/$safe_name.merged"

  if [[ -f "$CANDIDATE_SOURCE/$path" ]]; then
    cp "$CANDIDATE_SOURCE/$path" "$current_file"
  else
    : > "$current_file"
  fi
  if git -C "$CANDIDATE_SOURCE" cat-file -e "$MERGE_BASE:$path" 2>/dev/null; then
    git -C "$CANDIDATE_SOURCE" show "$MERGE_BASE:$path" > "$ancestor_file"
  else
    : > "$ancestor_file"
  fi
  git -C "$CANDIDATE_SOURCE" show "$SECONDARY_COMMIT:$path" > "$overlay_file"

  current_hash="$(sha256sum "$current_file" | awk '{print $1}')"
  ancestor_hash="$(sha256sum "$ancestor_file" | awk '{print $1}')"
  overlay_hash="$(sha256sum "$overlay_file" | awk '{print $1}')"

  if [[ "$current_hash" == "$overlay_hash" ]]; then
    printf 'ALREADY\t%s\t%s\n' "$current_hash" "$path" >> "$MANIFEST"
    already=$((already + 1))
    continue
  fi

  # Some files are maintained as one coherent series by the secondary source.
  # For those explicitly declared replace-* in source-overlays.conf, carry the
  # exact selected revision rather than trying to line-merge two divergent
  # implementations of the same driver.
  if (( replace == 1 )); then
    mkdir -p "$CANDIDATE_SOURCE/$(dirname "$path")"
    cp "$overlay_file" "$CANDIDATE_SOURCE/$path"
    git -C "$CANDIDATE_SOURCE" add -- "$path"
    printf 'REPLACED-%s\t%s\t%s\n' \
      "$([[ $required == 1 ]] && printf REQUIRED || printf OPTIONAL)" \
      "$overlay_hash" "$path" >> "$MANIFEST"
    replaced=$((replaced + 1))
    continue
  fi

  if [[ "$ancestor_hash" == "$overlay_hash" ]]; then
    printf 'KEEP-BASE\t%s\t%s\n' "$current_hash" "$path" >> "$MANIFEST"
    kept_base=$((kept_base + 1))
    continue
  fi

  if [[ "$ancestor_hash" == "$current_hash" ]]; then
    cp "$overlay_file" "$merged_file"
  else
    set +e
    git merge-file -p \
      -L "Perceival:$path" \
      -L "Common ancestor:$path" \
      -L "Kakatkar:$path" \
      "$current_file" "$ancestor_file" "$overlay_file" > "$merged_file"
    merge_status=$?
    set -e

    # git merge-file returns the number of conflicts, capped at 127. Any
    # positive status is therefore a content conflict, not an execution error.
    if (( merge_status > 0 )); then
      printf 'CONFLICT\t%s\tcount=%d\n' "$path" "$merge_status" >> "$MANIFEST"
      conflicts=$((conflicts + 1))
      continue
    fi
  fi

  mkdir -p "$CANDIDATE_SOURCE/$(dirname "$path")"
  cp "$merged_file" "$CANDIDATE_SOURCE/$path"
  git -C "$CANDIDATE_SOURCE" add -- "$path"
  result_hash="$(sha256sum "$merged_file" | awk '{print $1}')"
  printf 'MERGED\t%s\t%s\n' "$result_hash" "$path" >> "$MANIFEST"
  merged=$((merged + 1))
done < "$PROJECT_ROOT/source-overlays.conf"

printf '\nSUMMARY merged=%d replaced=%d already=%d kept-base=%d missing-optional=%d missing-required=%d conflicts=%d\n' \
  "$merged" "$replaced" "$already" "$kept_base" "$missing_optional" "$missing_required" "$conflicts" >> "$MANIFEST"

if (( missing_required > 0 || conflicts > 0 )); then
  echo "Source overlay integration was incomplete: missing-required=$missing_required conflicts=$conflicts" >&2
  exit 1
fi

if ! git -C "$CANDIDATE_SOURCE" diff --cached --quiet; then
  git -C "$CANDIDATE_SOURCE" config user.name 'DuskyProjects Builder'
  git -C "$CANDIDATE_SOURCE" config user.email 'actions@users.noreply.github.com'
  git -C "$CANDIDATE_SOURCE" commit -m "Integrate Flint-specific secondary source changes"
fi

echo "Source overlays integrated: merged=$merged replaced=$replaced already=$already kept-base=$kept_base missing-optional=$missing_optional"
