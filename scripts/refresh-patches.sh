#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
CANDIDATE_SOURCE="${1:?usage: refresh-patches.sh <candidate-source> <source-cache> <queue-dir> <manifest>}"
SOURCE_CACHE="${2:?usage: refresh-patches.sh <candidate-source> <source-cache> <queue-dir> <manifest>}"
QUEUE_DIR="${3:?usage: refresh-patches.sh <candidate-source> <source-cache> <queue-dir> <manifest>}"
MANIFEST="${4:?usage: refresh-patches.sh <candidate-source> <source-cache> <queue-dir> <manifest>}"
REFRESH_OPTIONAL_PATCHES="${REFRESH_OPTIONAL_PATCHES:-${REFRESH_EXTERNAL_PATCHES:-1}}"
PINNED_REQUIRED_PATCH_SOURCE_ID="${PINNED_REQUIRED_PATCH_SOURCE_ID:-kakatkar}"
PINNED_REQUIRED_PATCH_SOURCE_COMMIT="${PINNED_REQUIRED_PATCH_SOURCE_COMMIT:-$(git -C "$CANDIDATE_SOURCE" config --get nightly.overlayCommit 2>/dev/null || true)}"

[[ -d "$CANDIDATE_SOURCE/.git" ]] || {
  echo "Candidate source is not a Git checkout: $CANDIDATE_SOURCE" >&2
  exit 1
}
[[ -s "$PROJECT_ROOT/patch-sources.conf" ]] || {
  echo "patch-sources.conf is missing or empty." >&2
  exit 1
}

rm -rf "$QUEUE_DIR"
mkdir -p "$QUEUE_DIR" "$SOURCE_CACHE" "$(dirname "$MANIFEST")"
: > "$MANIFEST"

printf 'PATCH INTAKE MANIFEST\n' >> "$MANIFEST"
printf 'candidate-before=%s\n' "$(git -C "$CANDIDATE_SOURCE" rev-parse HEAD)" >> "$MANIFEST"
printf 'optional-refresh=%s\n' "$REFRESH_OPTIONAL_PATCHES" >> "$MANIFEST"
printf 'pinned-required-source=%s@%s\n\n' \
  "$PINNED_REQUIRED_PATCH_SOURCE_ID" "${PINNED_REQUIRED_PATCH_SOURCE_COMMIT:-branch-head}" >> "$MANIFEST"

if compgen -G "$PROJECT_ROOT/patches/mac80211-ath12k/*.patch" >/dev/null; then
  mkdir -p "$QUEUE_DIR/mac80211-ath12k"
  for patch in "$PROJECT_ROOT"/patches/mac80211-ath12k/*.patch; do
    install -m 0644 "$patch" "$QUEUE_DIR/mac80211-ath12k/$(basename "$patch")"
    printf 'LOCAL\t%s\t%s\n' \
      "$(sha256sum "$patch" | awk '{print $1}')" \
      "${patch#$PROJECT_ROOT/}" >> "$MANIFEST"
  done
fi

PATCH_ROOTS=(
  package/kernel/mac80211/patches/ath12k
  target/linux/qualcommbe/patches-6.18
  target/linux/generic/backport-6.18
  target/linux/generic/pending-6.18
  package/network/services/hostapd/patches
)
KEYWORDS='ath12k|ipq5332|qcn9274|gl-be9300|rtl8372|rtl837x|qcom.*ppe|\bppe\b|edma|multi[- ]link|\bmlo\b|remoteproc|\bpas\b|qrtr|dfs|ap_vlan|wds|switchdev|\bfdb\b|\bmdb\b|flow[_ -]?offload|flowtable|netfilter|\bppp\b|pppoe|tunnel|\blwt\b|ip6_tunnel'

repository_url() {
  local repository="$1"
  case "$repository" in
    http://*|https://*|file://*|/*) printf '%s\n' "$repository" ;;
    *) printf 'https://github.com/%s.git\n' "$repository" ;;
  esac
}

clone_sparse_source() {
  local id="$1" repository="$2" branch="$3" destination="$4" revision="$5" url
  url="$(repository_url "$repository")"

  if [[ ! -d "$destination/.git" ]]; then
    rm -rf "$destination"
    mkdir -p "$destination"
    git -C "$destination" init -q
    git -C "$destination" remote add origin "$url"
    git -C "$destination" sparse-checkout init --no-cone
  else
    git -C "$destination" remote set-url origin "$url"
  fi

  git -C "$destination" fetch --depth=1 --filter=blob:none origin "$revision"
  git -C "$destination" checkout --detach --force FETCH_HEAD
  git -C "$destination" sparse-checkout set --no-cone "${PATCH_ROOTS[@]}"
  git -C "$destination" clean -ffd >/dev/null
}

patch_id() {
  git patch-id --stable < "$1" 2>/dev/null | awk 'NR == 1 { print $1 }'
}

declare -A SEEN_PATCH_IDS=()
declare -a IMPORTED_PATHS=()

for root in "${PATCH_ROOTS[@]}"; do
  [[ -d "$CANDIDATE_SOURCE/$root" ]] || continue
  while IFS= read -r existing_patch; do
    existing_pid="$(patch_id "$existing_patch")"
    [[ -n "$existing_pid" ]] && SEEN_PATCH_IDS[$existing_pid]="${existing_patch#$CANDIDATE_SOURCE/}"
  done < <(find "$CANDIDATE_SOURCE/$root" -type f -name '*.patch' -print | sort)
done

conflict=0
imported=0
replaced=0
already=0
ignored=0
required_sources=0

while IFS='|' read -r id repository branch policy; do
  [[ -n "$id" && "$id" != \#* ]] || continue
  policy="${policy:-optional}"
  [[ -n "$repository" && -n "$branch" ]] || {
    echo "Invalid patch source entry for '$id'." >&2
    exit 1
  }
  case "$policy" in
    required)
      required_sources=$((required_sources + 1))
      ;;
    optional)
      if [[ "$REFRESH_OPTIONAL_PATCHES" != 1 ]]; then
        printf 'SOURCE-SKIPPED\t%s\toptional intake disabled\n' "$id" >> "$MANIFEST"
        continue
      fi
      ;;
    *)
      echo "Invalid patch-source policy '$policy' for '$id'." >&2
      exit 1
      ;;
  esac

  revision="$branch"
  if [[ "$id" == "$PINNED_REQUIRED_PATCH_SOURCE_ID" && -n "$PINNED_REQUIRED_PATCH_SOURCE_COMMIT" ]]; then
    revision="$PINNED_REQUIRED_PATCH_SOURCE_COMMIT"
  fi

  destination="$SOURCE_CACHE/$id"
  if ! clone_sparse_source "$id" "$repository" "$branch" "$destination" "$revision"; then
    printf 'SOURCE-UNAVAILABLE\t%s\t%s\t%s\t%s\t%s\n' \
      "$id" "$repository" "$branch" "$policy" "$revision" >> "$MANIFEST"
    if [[ "$policy" == required ]]; then
      echo "Required patch source '$id' could not be fetched at '$revision'." >&2
      exit 1
    fi
    continue
  fi

  source_commit="$(git -C "$destination" rev-parse HEAD)"
  if [[ "$id" == "$PINNED_REQUIRED_PATCH_SOURCE_ID" &&
        -n "$PINNED_REQUIRED_PATCH_SOURCE_COMMIT" &&
        "$source_commit" != "$PINNED_REQUIRED_PATCH_SOURCE_COMMIT" ]]; then
    echo "Required patch source '$id' resolved to $source_commit instead of $PINNED_REQUIRED_PATCH_SOURCE_COMMIT." >&2
    exit 1
  fi

  printf 'SOURCE\t%s\t%s\t%s\t%s\t%s\n' \
    "$id" "$repository" "$branch" "$policy" "$source_commit" >> "$MANIFEST"
  source_candidates=0

  for root in "${PATCH_ROOTS[@]}"; do
    [[ -d "$destination/$root" ]] || continue
    while IFS= read -r patch; do
      relative="${patch#$destination/}"
      selected=0

      if [[ "$policy" == required ]] && {
           [[ "$relative" == package/kernel/mac80211/patches/ath12k/* ]] ||
           [[ "$relative" == target/linux/qualcommbe/patches-6.18/* ]];
         }; then
        selected=1
      elif [[ "$policy" == optional && "$relative" == package/kernel/mac80211/patches/ath12k/* ]]; then
        selected=1
      elif grep -Eiq "$KEYWORDS" "$patch"; then
        selected=1
      fi

      if (( selected == 0 )); then
        ignored=$((ignored + 1))
        continue
      fi
      source_candidates=$((source_candidates + 1))

      pid="$(patch_id "$patch")"
      if [[ -n "$pid" && -n "${SEEN_PATCH_IDS[$pid]:-}" ]]; then
        printf 'ALREADY-ID\t%s\t%s\t%s\t%s\n' \
          "$id" "$pid" "$relative" "${SEEN_PATCH_IDS[$pid]}" >> "$MANIFEST"
        already=$((already + 1))
        continue
      fi

      target="$CANDIDATE_SOURCE/$relative"
      if [[ -e "$target" ]]; then
        if cmp -s "$patch" "$target"; then
          printf 'ALREADY\t%s\t%s\t%s\n' "$id" "${pid:-no-patch-id}" "$relative" >> "$MANIFEST"
          already=$((already + 1))
          continue
        fi

        target_pid="$(patch_id "$target")"
        if [[ -n "$pid" && "$pid" == "$target_pid" ]]; then
          printf 'EQUIVALENT\t%s\t%s\t%s\n' "$id" "$pid" "$relative" >> "$MANIFEST"
          already=$((already + 1))
          continue
        fi

        if [[ "$policy" == required ]]; then
          install -m 0644 "$patch" "$target"
          IMPORTED_PATHS+=("$relative")
          [[ -n "$target_pid" ]] && unset 'SEEN_PATCH_IDS[$target_pid]'
          [[ -n "$pid" ]] && SEEN_PATCH_IDS[$pid]="$relative"
          printf 'REPLACED-REQUIRED\t%s\t%s\t%s\n' "$id" "${pid:-no-patch-id}" "$relative" >> "$MANIFEST"
          replaced=$((replaced + 1))
          continue
        fi

        printf 'CONFLICT-SKIPPED\t%s\t%s\t%s\n' "$id" "${pid:-no-patch-id}" "$relative" >> "$MANIFEST"
        conflict=$((conflict + 1))
        continue
      fi

      mkdir -p "$(dirname "$target")"
      install -m 0644 "$patch" "$target"
      IMPORTED_PATHS+=("$relative")
      [[ -n "$pid" ]] && SEEN_PATCH_IDS[$pid]="$relative"
      printf 'IMPORTED\t%s\t%s\t%s\n' "$id" "${pid:-no-patch-id}" "$relative" >> "$MANIFEST"
      imported=$((imported + 1))
    done < <(find "$destination/$root" -type f -name '*.patch' -print | sort)
  done

  if [[ "$policy" == required && "$source_candidates" -eq 0 ]]; then
    printf 'SOURCE-EMPTY\t%s\n' "$id" >> "$MANIFEST"
    echo "Required patch source '$id' exposed no selected Flint networking patches." >&2
    exit 1
  fi
done < "$PROJECT_ROOT/patch-sources.conf"

if (( required_sources == 0 )); then
  echo "No required patch source is configured." >&2
  exit 1
fi

if (( ${#IMPORTED_PATHS[@]} > 0 )); then
  git -C "$CANDIDATE_SOURCE" add -- "${IMPORTED_PATHS[@]}"
  git -C "$CANDIDATE_SOURCE" config user.name 'DuskyProjects Builder'
  git -C "$CANDIDATE_SOURCE" config user.email 'actions@users.noreply.github.com'
  git -C "$CANDIDATE_SOURCE" commit -m "Integrate required and refreshed patch sources"
fi

printf '\nSUMMARY imported=%d replaced-required=%d already=%d ignored=%d optional-conflicts=%d\n' \
  "$imported" "$replaced" "$already" "$ignored" "$conflict" >> "$MANIFEST"
printf 'candidate-after=%s\n' "$(git -C "$CANDIDATE_SOURCE" rev-parse HEAD)" >> "$MANIFEST"

echo "Patch intake complete: imported=$imported replaced-required=$replaced already=$already optional-conflicts=$conflict"
