#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
# shellcheck disable=SC1091
source "$PROJECT_ROOT/build.env"

BASE_REPOSITORY="${BASE_REPOSITORY:-perceival/openwrt-flint3}"
BASE_BRANCH="${BASE_BRANCH:-flint3-be9300}"
OVERLAY_REPOSITORY="${OVERLAY_REPOSITORY:-KakatkarAkshay/openwrt}"
OVERLAY_BRANCH="${OVERLAY_BRANCH:-gl-be9300}"
MAX_HISTORY="${MAX_HISTORY:-3}"
MAX_OVERLAY_HISTORY="${MAX_OVERLAY_HISTORY:-1}"
MAX_BUILD_ATTEMPTS="${MAX_BUILD_ATTEMPTS:-8}"
CONTROLLED_SINGLE_BUILD="${CONTROLLED_SINGLE_BUILD:-0}"
CONTROLLED_BASE_COMMIT="${CONTROLLED_BASE_COMMIT:-}"
CONTROLLED_OVERLAY_COMMIT="${CONTROLLED_OVERLAY_COMMIT:-}"
JOBS="${JOBS:-4}"
BACKPORTS_BUMP_COMMIT="${BACKPORTS_BUMP_COMMIT:-509af829c650cb29ebe907e2216b5d648a9b15e6}"

if [[ "$CONTROLLED_SINGLE_BUILD" == 1 ]]; then
  MAX_HISTORY=1
  MAX_OVERLAY_HISTORY=1
  MAX_BUILD_ATTEMPTS=1
  [[ -n "$CONTROLLED_BASE_COMMIT" && -n "$CONTROLLED_OVERLAY_COMMIT" ]] || {
    echo "Controlled build requires exact base and overlay commits." >&2
    exit 1
  }
fi

PINNED_PACKAGES_COMMIT="$PACKAGES_FEED_COMMIT"
PINNED_LUCI_COMMIT="$LUCI_FEED_COMMIT"
PINNED_FOOTSTRAP_COMMIT="$FOOTSTRAP_COMMIT"
PINNED_FOOTSTRAP_VERSION="$FOOTSTRAP_VERSION"
PINNED_OPENWRT_COMMIT="$OPENWRT_COMMIT"

NIGHTLY_ROOT="${NIGHTLY_ROOT:-$PROJECT_ROOT/nightly-work}"
SOURCE_ROOT="$NIGHTLY_ROOT/sources"
PATCH_SOURCE_CACHE="$NIGHTLY_ROOT/patch-sources"
ATTEMPT_ROOT="$NIGHTLY_ROOT/attempts"
CCACHE_ROOT="$NIGHTLY_ROOT/ccache"
RELEASE_DIR="$PROJECT_ROOT/release"
DATE_UTC="$(date -u +%Y%m%d)"
DATE_DISPLAY="$(date -u +%Y-%m-%d)"

rm -rf "$SOURCE_ROOT" "$ATTEMPT_ROOT" "$RELEASE_DIR"
mkdir -p "$SOURCE_ROOT" "$PATCH_SOURCE_CACHE" "$ATTEMPT_ROOT" "$CCACHE_ROOT" "$RELEASE_DIR"

repository_url() {
  local repository="$1"
  case "$repository" in
    http://*|https://*|file://*|/*) printf '%s\n' "$repository" ;;
    *) printf 'https://github.com/%s.git\n' "$repository" ;;
  esac
}

latest_head() {
  local repository="$1" fallback="$2" head url
  url="$(repository_url "$repository")"
  head="$({ git ls-remote "$url" HEAD 2>/dev/null || true; } | awk 'NR == 1 { print $1 }')"
  printf '%s\n' "${head:-$fallback}"
}

clone_history() {
  local repository="$1" branch="$2" destination="$3" url
  url="$(repository_url "$repository")"
  git clone --no-checkout --single-branch --branch "$branch" \
    "$url" "$destination"
  git -C "$destination" rev-parse --verify "origin/$branch^{commit}" >/dev/null
}

ensure_commit() {
  local repository="$1" commit="$2"
  if ! git -C "$repository" cat-file -e "$commit^{commit}" 2>/dev/null; then
    git -C "$repository" fetch --no-tags origin "$commit"
  fi
  git -C "$repository" cat-file -e "$commit^{commit}"
}

release_field() {
  local body="$1" field="$2"
  printf '%s\n' "$body" | sed -n "s/^<!-- ${field}: \(.*\) -->$/\1/p" | head -n1
}

append_commit_changelog() {
  local repository="$1" previous="$2" current="$3" heading="$4"
  printf '### %s\n\n' "$heading"
  if [[ -n "$previous" ]] &&
     git -C "$repository" cat-file -e "$previous^{commit}" 2>/dev/null &&
     git -C "$repository" merge-base --is-ancestor "$previous" "$current"; then
    if [[ "$previous" == "$current" ]]; then
      printf 'No source commits changed.\n\n'
    else
      git -C "$repository" log --no-merges --format='- `%h` %s' "$previous..$current" | head -n 40
      printf '\n'
    fi
  else
    git -C "$repository" log --no-merges --format='- `%h` %s' --max-count=12 "$current"
    printf '\n'
  fi
}

BASE_MIRROR="$SOURCE_ROOT/perceival"
OVERLAY_MIRROR="$SOURCE_ROOT/kakatkar"
clone_history "$BASE_REPOSITORY" "$BASE_BRANCH" "$BASE_MIRROR"
clone_history "$OVERLAY_REPOSITORY" "$OVERLAY_BRANCH" "$OVERLAY_MIRROR"

BASE_HISTORY_FILE="$NIGHTLY_ROOT/base-history.txt"
OVERLAY_HISTORY_FILE="$NIGHTLY_ROOT/overlay-history.txt"
git -C "$BASE_MIRROR" log --first-parent --max-count="$MAX_HISTORY" \
  --format='%ct|%H' "origin/$BASE_BRANCH" > "$BASE_HISTORY_FILE"
LATEST_BASE_COMMIT="$(awk -F'|' 'NR == 1 { print $2 }' "$BASE_HISTORY_FILE")"
if git -C "$BASE_MIRROR" cat-file -e "$PINNED_OPENWRT_COMMIT^{commit}" 2>/dev/null; then
  printf '%s|%s\n' \
    "$(git -C "$BASE_MIRROR" show -s --format=%ct "$PINNED_OPENWRT_COMMIT")" \
    "$PINNED_OPENWRT_COMMIT" >> "$BASE_HISTORY_FILE"
fi
awk -F'|' '!seen[$2]++' "$BASE_HISTORY_FILE" > "$BASE_HISTORY_FILE.tmp"
mv "$BASE_HISTORY_FILE.tmp" "$BASE_HISTORY_FILE"

# The current Kakatkar head is a required coherent series. Do not silently fall
# back to older overlay revisions when the current series fails.
git -C "$OVERLAY_MIRROR" log --first-parent --max-count="$MAX_OVERLAY_HISTORY" \
  --format='%ct|%H' "origin/$OVERLAY_BRANCH" > "$OVERLAY_HISTORY_FILE"
LATEST_OVERLAY_COMMIT="$(awk -F'|' 'NR == 1 { print $2 }' "$OVERLAY_HISTORY_FILE")"

if [[ "$CONTROLLED_SINGLE_BUILD" == 1 ]]; then
  ensure_commit "$BASE_MIRROR" "$CONTROLLED_BASE_COMMIT"
  ensure_commit "$OVERLAY_MIRROR" "$CONTROLLED_OVERLAY_COMMIT"
  printf '%s|%s\n' \
    "$(git -C "$BASE_MIRROR" show -s --format=%ct "$CONTROLLED_BASE_COMMIT")" \
    "$CONTROLLED_BASE_COMMIT" > "$BASE_HISTORY_FILE"
  printf '%s|%s\n' \
    "$(git -C "$OVERLAY_MIRROR" show -s --format=%ct "$CONTROLLED_OVERLAY_COMMIT")" \
    "$CONTROLLED_OVERLAY_COMMIT" > "$OVERLAY_HISTORY_FILE"
  LATEST_BASE_COMMIT="$CONTROLLED_BASE_COMMIT"
  LATEST_OVERLAY_COMMIT="$CONTROLLED_OVERLAY_COMMIT"
fi

[[ -s "$BASE_HISTORY_FILE" && -s "$OVERLAY_HISTORY_FILE" ]] || {
  echo "Could not enumerate Flint 3 source revisions." >&2
  exit 1
}

PAIR_FILE="$NIGHTLY_ROOT/source-pairs.txt"
: > "$PAIR_FILE"
while IFS='|' read -r base_time base_commit; do
  while IFS='|' read -r overlay_time overlay_commit; do
    printf '%s|%s|%s|%s|%s\n' \
      "$((base_time + overlay_time))" "$base_time" "$base_commit" "$overlay_time" "$overlay_commit" >> "$PAIR_FILE"
  done < "$OVERLAY_HISTORY_FILE"
done < "$BASE_HISTORY_FILE"
sort -t'|' -k1,1nr -k2,2nr -k4,4nr -o "$PAIR_FILE" "$PAIR_FILE"

# Always test the newest base first and the pinned base second while keeping the
# same required current Kakatkar series. Controlled mode has exactly one pair.
ORDERED_PAIR_FILE="$NIGHTLY_ROOT/source-pairs-ordered.txt"
{
  awk -F'|' -v b="$LATEST_BASE_COMMIT" -v o="$LATEST_OVERLAY_COMMIT" '$3 == b && $5 == o' "$PAIR_FILE"
  if [[ "$CONTROLLED_SINGLE_BUILD" != 1 ]]; then
    awk -F'|' -v b="$PINNED_OPENWRT_COMMIT" -v o="$LATEST_OVERLAY_COMMIT" '$3 == b && $5 == o' "$PAIR_FILE"
  fi
  cat "$PAIR_FILE"
} | awk -F'|' '!seen[$3 FS $5]++' > "$ORDERED_PAIR_FILE"
PAIR_FILE="$ORDERED_PAIR_FILE"

if [[ "$CONTROLLED_SINGLE_BUILD" == 1 ]]; then
  LATEST_PACKAGES_COMMIT="$PINNED_PACKAGES_COMMIT"
  LATEST_LUCI_COMMIT="$PINNED_LUCI_COMMIT"
  LATEST_FOOTSTRAP_COMMIT="$PINNED_FOOTSTRAP_COMMIT"
  LATEST_FOOTSTRAP_VERSION="$PINNED_FOOTSTRAP_VERSION"
  STRATEGIES=(
    'integrated-required-known-good|0|known-good'
  )
  SOURCE_TIERS=(
    'published-backports|1'
  )
else
  LATEST_PACKAGES_COMMIT="$(latest_head "$PACKAGES_FEED_REPOSITORY" "$PINNED_PACKAGES_COMMIT")"
  LATEST_LUCI_COMMIT="$(latest_head "$LUCI_FEED_REPOSITORY" "$PINNED_LUCI_COMMIT")"
  LATEST_FOOTSTRAP_COMMIT="$(latest_head "$FOOTSTRAP_REPOSITORY" "$PINNED_FOOTSTRAP_COMMIT")"
  LATEST_FOOTSTRAP_VERSION="0.0.0_git${DATE_UTC}_${LATEST_FOOTSTRAP_COMMIT:0:8}"
  STRATEGIES=(
    'integrated-all-latest|1|latest'
    'integrated-required-known-good|0|known-good'
  )
  SOURCE_TIERS=(
    'current|0'
    'published-backports|1'
  )
fi

attempt=0
success=0
successful_base=''
successful_overlay=''
successful_source_tier=''
successful_strategy=''
successful_patch_tier=''
successful_feed_tier=''
successful_packages=''
successful_luci=''
successful_footstrap=''
successful_output=''
successful_patch_manifest=''
successful_overlay_manifest=''
successful_curated_manifest=''
successful_archive_url=''

while IFS='|' read -r _score _base_time base_commit _overlay_time overlay_commit; do
  candidate_id="${base_commit:0:8}-${overlay_commit:0:8}"
  base_candidate="$ATTEMPT_ROOT/base-$candidate_id"
  rm -rf "$base_candidate"
  git clone --local --no-hardlinks "$BASE_MIRROR" "$base_candidate"
  git -C "$base_candidate" checkout --detach "$base_commit"
  git -C "$base_candidate" fetch --no-tags "$OVERLAY_MIRROR" "$overlay_commit"
  git -C "$base_candidate" update-ref refs/nightly/overlay "$overlay_commit"

  for source_tier in "${SOURCE_TIERS[@]}"; do
    IFS='|' read -r source_tier_name revert_backports <<< "$source_tier"
    source_variant="$ATTEMPT_ROOT/source-$candidate_id-$source_tier_name"
    rm -rf "$source_variant"
    git clone --local --no-hardlinks "$base_candidate" "$source_variant"
    git -C "$source_variant" config user.name 'DuskyProjects Builder'
    git -C "$source_variant" config user.email 'actions@users.noreply.github.com'

    if [[ "$revert_backports" == 1 ]]; then
      if ! git -C "$source_variant" merge-base --is-ancestor "$BACKPORTS_BUMP_COMMIT" HEAD; then
        continue
      fi
      if ! git -C "$source_variant" revert --no-edit "$BACKPORTS_BUMP_COMMIT"; then
        git -C "$source_variant" revert --abort >/dev/null 2>&1 || true
        echo "Could not create the published-backports fallback for $candidate_id."
        continue
      fi
    fi

    archive_url="$(bash "$PROJECT_ROOT/scripts/check-mac80211-source.sh" "$source_variant" --print-only)"
    if ! bash "$PROJECT_ROOT/scripts/check-mac80211-source.sh" "$source_variant" >/dev/null; then
      echo "Skipping $candidate_id/$source_tier_name because its mac80211 source archive is unavailable: $archive_url"
      continue
    fi

    for strategy in "${STRATEGIES[@]}"; do
      if (( attempt >= MAX_BUILD_ATTEMPTS )); then
        break 3
      fi
      IFS='|' read -r strategy_name refresh_optional feed_choice <<< "$strategy"

      integrated_source="$ATTEMPT_ROOT/integrated-$candidate_id-$source_tier_name-$strategy_name"
      overlay_manifest="$ATTEMPT_ROOT/overlays-$candidate_id-$source_tier_name-$strategy_name.txt"
      queue_root="$ATTEMPT_ROOT/queue-$candidate_id-$source_tier_name-$strategy_name"
      patch_manifest="$ATTEMPT_ROOT/patches-$candidate_id-$source_tier_name-$strategy_name.txt"
      curated_manifest="$ATTEMPT_ROOT/curated-$candidate_id-$source_tier_name-$strategy_name.txt"
      rm -rf "$integrated_source" "$queue_root"
      git clone --local --no-hardlinks "$source_variant" "$integrated_source"

      if ! bash "$PROJECT_ROOT/scripts/apply-source-overlays.sh" \
        "$integrated_source" "$overlay_commit" "$overlay_manifest"; then
        echo "Required Flint source integration was not usable for $candidate_id/$source_tier_name."
        continue
      fi

      if ! REFRESH_OPTIONAL_PATCHES="$refresh_optional" \
        bash "$PROJECT_ROOT/scripts/refresh-patches.sh" \
          "$integrated_source" "$PATCH_SOURCE_CACHE" "$queue_root" "$patch_manifest"; then
        echo "Required patch intake was not usable for $candidate_id/$source_tier_name/$strategy_name."
        continue
      fi

      if ! bash "$PROJECT_ROOT/scripts/apply-curated-patches.sh" \
        "$integrated_source" "$curated_manifest"; then
        echo "Curated Flint patches were not usable for $candidate_id/$source_tier_name/$strategy_name."
        continue
      fi

      case "$feed_choice" in
        latest)
          packages_commit="$LATEST_PACKAGES_COMMIT"
          luci_commit="$LATEST_LUCI_COMMIT"
          footstrap_commit="$LATEST_FOOTSTRAP_COMMIT"
          footstrap_version="$LATEST_FOOTSTRAP_VERSION"
          ;;
        known-good)
          packages_commit="$PINNED_PACKAGES_COMMIT"
          luci_commit="$PINNED_LUCI_COMMIT"
          footstrap_commit="$PINNED_FOOTSTRAP_COMMIT"
          footstrap_version="$PINNED_FOOTSTRAP_VERSION"
          ;;
        *)
          echo "Unknown feed tier: $feed_choice" >&2
          exit 1
          ;;
      esac

      source_record="$ATTEMPT_ROOT/INTEGRATED-SOURCES-$candidate_id-$source_tier_name-$strategy_name.txt"
      cat > "$source_record" <<SOURCES
Base repository:      $BASE_REPOSITORY
Base branch:          $BASE_BRANCH
Base commit:          $base_commit
Overlay repository:   $OVERLAY_REPOSITORY
Overlay branch:       $OVERLAY_BRANCH
Overlay commit:       $overlay_commit
Integrated commit:    $(git -C "$integrated_source" rev-parse HEAD)
Source tier:          $source_tier_name
Strategy:             $strategy_name
Mac80211 archive:     $archive_url
SOURCES

      attempt=$((attempt + 1))
      attempt_dir="$ATTEMPT_ROOT/build-$attempt-$candidate_id-$source_tier_name-$strategy_name"
      output_dir="$attempt_dir/output"
      log_file="$attempt_dir/build.log"
      mkdir -p "$attempt_dir"

      echo "============================================================"
      echo "Controlled build attempt $attempt of $MAX_BUILD_ATTEMPTS"
      echo "Perceival base:     $base_commit"
      echo "Kakatkar source:    $overlay_commit"
      echo "Source tier:        $source_tier_name"
      echo "Strategy:           $strategy_name"
      echo "Mac80211 archive:   $archive_url"
      echo "============================================================"

      if env \
        OPENWRT_LOCAL_SOURCE="$integrated_source" \
        OPENWRT_REPOSITORY="$BASE_REPOSITORY with required Flint integration from $OVERLAY_REPOSITORY" \
        OPENWRT_BRANCH="$BASE_BRANCH + required $OVERLAY_BRANCH integration" \
        OPENWRT_COMMIT="$(git -C "$integrated_source" rev-parse HEAD)" \
        PACKAGES_FEED_COMMIT="$packages_commit" \
        LUCI_FEED_COMMIT="$luci_commit" \
        FOOTSTRAP_COMMIT="$footstrap_commit" \
        FOOTSTRAP_VERSION="$footstrap_version" \
        FIRMWARE_BUILD_LABEL="controlled-integrated" \
        MERGED_SOURCE_RECORD="$source_record" \
        ATH12K_PATCH_DIR="$queue_root/mac80211-ath12k" \
        WORK_ROOT="$attempt_dir/work" \
        OUTPUT_DIR="$output_dir" \
        DOWNLOAD_CACHE_DIR="${DOWNLOAD_CACHE_DIR:-$NIGHTLY_ROOT/dl}" \
        CCACHE_DIR="$CCACHE_ROOT" \
        JOBS="$JOBS" \
        bash "$PROJECT_ROOT/scripts/build.sh" >"$log_file" 2>&1; then
        success=1
        successful_base="$base_commit"
        successful_overlay="$overlay_commit"
        successful_source_tier="$source_tier_name"
        successful_strategy="$strategy_name"
        successful_patch_tier="$([[ "$refresh_optional" == 1 ]] && printf required-plus-optional || printf required-only)"
        successful_feed_tier="$feed_choice"
        successful_packages="$packages_commit"
        successful_luci="$luci_commit"
        successful_footstrap="$footstrap_commit"
        successful_output="$output_dir"
        successful_patch_manifest="$patch_manifest"
        successful_overlay_manifest="$overlay_manifest"
        successful_curated_manifest="$curated_manifest"
        successful_archive_url="$archive_url"
        tail -n 80 "$log_file"
        break 3
      fi

      if [[ "$CONTROLLED_SINGLE_BUILD" == 1 ]]; then
        echo "Controlled build failed; no second candidate or strategy will be started."
      else
        echo "Candidate did not compile; trying the next controlled strategy."
      fi
      tail -n 120 "$log_file" || true
    done
  done
done < "$PAIR_FILE"

(( success == 1 )) || {
  echo "No required Flint source/feed/patch combination compiled successfully." >&2
  exit 1
}

mapfile -t FACTORY_IMAGES < <(find "$successful_output" -maxdepth 1 -type f -name '*factory.bin' -print)
mapfile -t SYSUPGRADE_IMAGES < <(find "$successful_output" -maxdepth 1 -type f -name '*sysupgrade.bin' -print)
[[ ${#FACTORY_IMAGES[@]} -eq 1 && ${#SYSUPGRADE_IMAGES[@]} -eq 1 ]] || {
  echo "Successful build did not contain exactly two firmware images." >&2
  exit 1
}

FACTORY_RELEASE="$RELEASE_DIR/flint3-full-factory.bin"
SYSUPGRADE_RELEASE="$RELEASE_DIR/flint3-sysupgrade.bin"
cp -v "${FACTORY_IMAGES[0]}" "$FACTORY_RELEASE"
cp -v "${SYSUPGRADE_IMAGES[0]}" "$SYSUPGRADE_RELEASE"
[[ "$(find "$RELEASE_DIR" -maxdepth 1 -type f -name '*.bin' | wc -l)" -eq 2 ]]

previous_body=''
previous_base=''
previous_overlay=''
if command -v gh >/dev/null 2>&1 && [[ -n "${GH_TOKEN:-}" ]]; then
  previous_tag="$(gh release list --limit 100 --json tagName,isPrerelease,publishedAt \
    --jq '[.[] | select(.isPrerelease == true and (.tagName | startswith("nightly-")))] | sort_by(.publishedAt) | last | .tagName // ""' \
    2>/dev/null || true)"
  if [[ -n "$previous_tag" ]]; then
    previous_body="$(gh release view "$previous_tag" --json body --jq .body 2>/dev/null || true)"
    previous_base="$(release_field "$previous_body" base-source)"
    previous_overlay="$(release_field "$previous_body" overlay-source)"
  fi
fi

CHANGELOG_FILE="$PROJECT_ROOT/release-notes.md"
{
  printf '<!-- base-source: %s -->\n' "$successful_base"
  printf '<!-- overlay-source: %s -->\n' "$successful_overlay"
  printf '<!-- source-tier: %s -->\n' "$successful_source_tier"
  printf '<!-- packages-source: %s -->\n' "$successful_packages"
  printf '<!-- luci-source: %s -->\n' "$successful_luci"
  printf '<!-- footstrap-source: %s -->\n\n' "$successful_footstrap"
  printf '# Flint 3 integrated build — %s\n\n' "$DATE_DISPLAY"
  printf 'Required current Kakatkar source and patch series, curated flat DWC3 migration, and the selected Perceival base passed source preflight, privacy checks, package validation, factory-image validation, and compilation.\n\n'
  printf '## Selected inputs\n\n'
  printf -- '- Perceival base: `%s@%s`\n' "$BASE_REPOSITORY" "$successful_base"
  printf -- '- Required Kakatkar source: `%s@%s`\n' "$OVERLAY_REPOSITORY" "$successful_overlay"
  printf -- '- Source tier: `%s`\n' "$successful_source_tier"
  printf -- '- Strategy: `%s`\n' "$successful_strategy"
  printf -- '- Patch tier: `%s`\n' "$successful_patch_tier"
  printf -- '- Package feed: `%s@%s`\n' "$PACKAGES_FEED_REPOSITORY" "$successful_packages"
  printf -- '- LuCI feed: `%s@%s`\n' "$LUCI_FEED_REPOSITORY" "$successful_luci"
  printf -- '- Footstrap: `%s@%s`\n' "$FOOTSTRAP_REPOSITORY" "$successful_footstrap"
  printf -- '- Feed tier: `%s`\n' "$successful_feed_tier"
  printf -- '- mac80211 archive: `%s`\n\n' "$successful_archive_url"

  printf '## Changelog\n\n'
  append_commit_changelog "$BASE_MIRROR" "$previous_base" "$successful_base" "Perceival base changes"
  append_commit_changelog "$OVERLAY_MIRROR" "$previous_overlay" "$successful_overlay" "Required Kakatkar changes"

  printf '### Required Flint source integration\n\n'
  if [[ -s "$successful_overlay_manifest" ]]; then
    grep -E '^(MERGED|ALREADY|KEEP-BASE|MISSING|CONFLICT|SUMMARY)' "$successful_overlay_manifest" |
      sed 's/^/- `/' | sed 's/$/`/'
  else
    printf 'No source-overlay manifest was generated.\n'
  fi
  printf '\n\n'

  printf '### Required and optional patch intake\n\n'
  if [[ -s "$successful_patch_manifest" ]]; then
    grep -E '^(SOURCE|SOURCE-|IMPORTED|REPLACED|ALREADY|EQUIVALENT|CONFLICT|SUMMARY)' "$successful_patch_manifest" |
      sed 's/^/- `/' | sed 's/$/`/'
  else
    printf 'No patch manifest was generated.\n'
  fi
  printf '\n\n'

  printf '### Curated Flint patches\n\n'
  if [[ -s "$successful_curated_manifest" ]]; then
    grep -E '^(SOURCE|KERNEL|SUMMARY)' "$successful_curated_manifest" |
      sed 's/^/- `/' | sed 's/$/`/'
  else
    printf 'No curated-patch manifest was generated.\n'
  fi
  printf '\n\n'

  printf '## Image checksums\n\n```text\n'
  sha256sum "$FACTORY_RELEASE" "$SYSUPGRADE_RELEASE" | sed "s#$PROJECT_ROOT/##"
  printf '```\n\n'
  printf 'Release assets contain only the full factory image and the sysupgrade image.\n'
} > "$CHANGELOG_FILE"

cat > "$PROJECT_ROOT/nightly-release.env" <<ENV
RELEASE_TAG='nightly-$DATE_UTC'
RELEASE_TITLE='Flint 3 Nightly $DATE_DISPLAY'
FACTORY_FILE='$FACTORY_RELEASE'
SYSUPGRADE_FILE='$SYSUPGRADE_RELEASE'
ENV

sha256sum "$FACTORY_RELEASE" "$SYSUPGRADE_RELEASE"
echo "Selected newest successful controlled candidate after $attempt build attempt(s)."
