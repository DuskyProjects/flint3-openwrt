#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
# shellcheck disable=SC1091
source "$PROJECT_ROOT/build.env"

BASE_REPOSITORY="${BASE_REPOSITORY:-perceival/openwrt-flint3}"
BASE_BRANCH="${BASE_BRANCH:-flint3-be9300}"
OVERLAY_REPOSITORY="${OVERLAY_REPOSITORY:-KakatkarAkshay/openwrt}"
OVERLAY_BRANCH="${OVERLAY_BRANCH:-gl-be9300}"
NIGHTLY_ROOT="${NIGHTLY_ROOT:-$PROJECT_ROOT/nightly-work}"
RELEASE_DIR="$PROJECT_ROOT/release"
DATE_UTC="$(date -u +%Y%m%d)"
DATE_DISPLAY="$(date -u +%Y-%m-%d)"

mkdir -p "$NIGHTLY_ROOT/dl" "$NIGHTLY_ROOT/ccache" "$NIGHTLY_ROOT/patch-sources"

repository_url() {
  local repository="$1"
  case "$repository" in
    http://*|https://*|file://*|/*) printf '%s\n' "$repository" ;;
    *) printf 'https://github.com/%s.git\n' "$repository" ;;
  esac
}

remote_branch_head() {
  local repository="$1" branch="$2" fallback="$3" value url
  url="$(repository_url "$repository")"
  value="$({ git ls-remote "$url" "refs/heads/$branch" 2>/dev/null || true; } | awk 'NR == 1 { print $1 }')"
  printf '%s\n' "${value:-$fallback}"
}

remote_default_head() {
  local repository="$1" fallback="$2" value url
  url="$(repository_url "$repository")"
  value="$({ git ls-remote "$url" HEAD 2>/dev/null || true; } | awk 'NR == 1 { print $1 }')"
  printf '%s\n' "${value:-$fallback}"
}

release_field() {
  local body="$1" field="$2"
  printf '%s\n' "$body" | sed -n "s/^<!-- ${field}: \(.*\) -->$/\1/p" | head -n1
}

write_release_env() {
  cat > "$PROJECT_ROOT/nightly-release.env" <<ENV
RELEASE_TAG='nightly-$DATE_UTC'
RELEASE_TITLE='Flint 3 Nightly $DATE_DISPLAY'
FACTORY_FILE='$RELEASE_DIR/flint3-full-factory.bin'
SYSUPGRADE_FILE='$RELEASE_DIR/flint3-sysupgrade.bin'
ENV
}

download_release_assets() {
  local tag="$1"
  rm -rf "$RELEASE_DIR"
  mkdir -p "$RELEASE_DIR"
  gh release download "$tag" --pattern 'flint3-full-factory.bin' --dir "$RELEASE_DIR" >/dev/null
  gh release download "$tag" --pattern 'flint3-sysupgrade.bin' --dir "$RELEASE_DIR" >/dev/null
  [[ "$(find "$RELEASE_DIR" -maxdepth 1 -type f -name '*.bin' | wc -l)" -eq 2 ]]
}

binary_fingerprint() {
  (
    cd "$RELEASE_DIR"
    sha256sum flint3-full-factory.bin flint3-sysupgrade.bin
  ) | sha256sum | awk '{print $1}'
}

BASE_HEAD="$(remote_branch_head "$BASE_REPOSITORY" "$BASE_BRANCH" "$OPENWRT_COMMIT")"
OVERLAY_HEAD="$(remote_branch_head "$OVERLAY_REPOSITORY" "$OVERLAY_BRANCH" "$OPENWRT_COMMIT")"
PACKAGES_HEAD="$(remote_default_head "$PACKAGES_FEED_REPOSITORY" "$PACKAGES_FEED_COMMIT")"
LUCI_HEAD="$(remote_default_head "$LUCI_FEED_REPOSITORY" "$LUCI_FEED_COMMIT")"
FOOTSTRAP_HEAD="$(remote_default_head "$FOOTSTRAP_REPOSITORY" "$FOOTSTRAP_COMMIT")"

PATCH_SOURCE_HEADS=''
while IFS='|' read -r id repository branch policy; do
  [[ -n "$id" && "$id" != \#* ]] || continue
  policy="${policy:-optional}"
  head="$(remote_branch_head "$repository" "$branch" unavailable)"
  PATCH_SOURCE_HEADS+="${id}=${repository}@${head};policy=${policy}"$'\n'
done < "$PROJECT_ROOT/patch-sources.conf"

# Hash every firmware-relevant builder input. Tests and documentation are not
# included, but any build script, workflow, package, patch, or firmware-overlay
# change creates a new attempted fingerprint.
BUILDER_HASH="$({
  git -C "$PROJECT_ROOT" ls-files -s -- \
    build.env \
    config.seed \
    packages.required \
    source.required \
    source-overlays.conf \
    patch-sources.conf \
    patches \
    files \
    scripts/apply-curated-patches.sh \
    scripts/apply-source-overlays.sh \
    scripts/build.sh \
    scripts/check-mac80211-source.sh \
    scripts/nightly-build.sh \
    scripts/nightly-or-reuse.sh \
    scripts/privacy-audit.sh \
    scripts/refresh-patches.sh \
    .github/workflows/build.yml
} | sha256sum | awk '{print $1}')"

ATTEMPTED_FINGERPRINT="$({
  printf 'base=%s\n' "$BASE_HEAD"
  printf 'overlay=%s\n' "$OVERLAY_HEAD"
  printf 'packages=%s\n' "$PACKAGES_HEAD"
  printf 'luci=%s\n' "$LUCI_HEAD"
  printf 'footstrap=%s\n' "$FOOTSTRAP_HEAD"
  printf 'patch-sources=%s\n' "$PATCH_SOURCE_HEADS"
  printf 'builder=%s\n' "$BUILDER_HASH"
} | sha256sum | awk '{print $1}')"

PREVIOUS_TAG=''
PREVIOUS_BODY=''
PREVIOUS_ATTEMPTED=''
PREVIOUS_BUILD=''
PREVIOUS_STATUS=''
PREVIOUS_BASE=''
PREVIOUS_OVERLAY=''
PREVIOUS_PACKAGES=''
PREVIOUS_LUCI=''
PREVIOUS_FOOTSTRAP=''

if command -v gh >/dev/null 2>&1 && [[ -n "${GH_TOKEN:-}" ]]; then
  PREVIOUS_TAG="$(gh release list --limit 100 \
    --json tagName,isPrerelease,publishedAt \
    --jq '[.[] | select(.isPrerelease == true and (.tagName | startswith("nightly-")))] | sort_by(.publishedAt) | last | .tagName // ""' \
    2>/dev/null || true)"

  if [[ -n "$PREVIOUS_TAG" ]]; then
    PREVIOUS_BODY="$(gh release view "$PREVIOUS_TAG" --json body --jq .body 2>/dev/null || true)"
    PREVIOUS_ATTEMPTED="$(release_field "$PREVIOUS_BODY" attempted-fingerprint)"
    PREVIOUS_BUILD="$(release_field "$PREVIOUS_BODY" build-fingerprint)"
    PREVIOUS_STATUS="$(release_field "$PREVIOUS_BODY" build-status)"
    PREVIOUS_BASE="$(release_field "$PREVIOUS_BODY" base-source)"
    PREVIOUS_OVERLAY="$(release_field "$PREVIOUS_BODY" overlay-source)"
    [[ -n "$PREVIOUS_OVERLAY" ]] || PREVIOUS_OVERLAY="$(release_field "$PREVIOUS_BODY" patch-source)"
    PREVIOUS_PACKAGES="$(release_field "$PREVIOUS_BODY" packages-source)"
    PREVIOUS_LUCI="$(release_field "$PREVIOUS_BODY" luci-source)"
    PREVIOUS_FOOTSTRAP="$(release_field "$PREVIOUS_BODY" footstrap-source)"
  fi
fi

if [[ -n "$PREVIOUS_TAG" && "$PREVIOUS_ATTEMPTED" == "$ATTEMPTED_FINGERPRINT" ]]; then
  if download_release_assets "$PREVIOUS_TAG"; then
    CURRENT_BUILD_FINGERPRINT="$(binary_fingerprint)"
    [[ -n "$PREVIOUS_BUILD" ]] && CURRENT_BUILD_FINGERPRINT="$PREVIOUS_BUILD"
    write_release_env
    cat > "$PROJECT_ROOT/release-notes.md" <<NOTES
<!-- attempted-fingerprint: $ATTEMPTED_FINGERPRINT -->
<!-- build-fingerprint: $CURRENT_BUILD_FINGERPRINT -->
<!-- build-status: unchanged-reuse -->
<!-- base-source: $PREVIOUS_BASE -->
<!-- overlay-source: $PREVIOUS_OVERLAY -->
<!-- packages-source: $PREVIOUS_PACKAGES -->
<!-- luci-source: $PREVIOUS_LUCI -->
<!-- footstrap-source: $PREVIOUS_FOOTSTRAP -->

# Flint 3 integrated nightly — $DATE_DISPLAY

## Changelog

No firmware-relevant source, feed, theme, package, required overlay, curated patch, or monitored patch-source revision changed since \`$PREVIOUS_TAG\`. The previously validated binaries were reused instead of repeating the same OpenWrt compilation.

Previous nightly status: \`${PREVIOUS_STATUS:-unknown}\`.

Release assets contain only the full factory image and the sysupgrade image.
NOTES
    echo "No relevant inputs changed; reused binaries from $PREVIOUS_TAG."
    exit 0
  fi
fi

export DOWNLOAD_CACHE_DIR="$NIGHTLY_ROOT/dl"
export CCACHE_DIR="$NIGHTLY_ROOT/ccache"
export CCACHE_MAX_SIZE="${CCACHE_MAX_SIZE:-3G}"

if bash "$PROJECT_ROOT/scripts/nightly-build.sh"; then
  BUILD_FINGERPRINT="$(binary_fingerprint)"
  ORIGINAL_NOTES="$(cat "$PROJECT_ROOT/release-notes.md")"
  cat > "$PROJECT_ROOT/release-notes.md" <<NOTES
<!-- attempted-fingerprint: $ATTEMPTED_FINGERPRINT -->
<!-- build-fingerprint: $BUILD_FINGERPRINT -->
<!-- build-status: compiled -->

$ORIGINAL_NOTES
NOTES
  exit 0
fi

if [[ -n "$PREVIOUS_TAG" ]] && download_release_assets "$PREVIOUS_TAG"; then
  BUILD_FINGERPRINT="$(binary_fingerprint)"
  [[ -n "$PREVIOUS_BUILD" ]] && BUILD_FINGERPRINT="$PREVIOUS_BUILD"
  write_release_env
  cat > "$PROJECT_ROOT/release-notes.md" <<NOTES
<!-- attempted-fingerprint: $ATTEMPTED_FINGERPRINT -->
<!-- build-fingerprint: $BUILD_FINGERPRINT -->
<!-- build-status: reused-after-failure -->
<!-- base-source: $PREVIOUS_BASE -->
<!-- overlay-source: $PREVIOUS_OVERLAY -->
<!-- packages-source: $PREVIOUS_PACKAGES -->
<!-- luci-source: $PREVIOUS_LUCI -->
<!-- footstrap-source: $PREVIOUS_FOOTSTRAP -->

# Flint 3 integrated nightly — $DATE_DISPLAY

## Changelog

The newest required Kakatkar source and patch series, curated patches, selected base, and feeds did not pass the complete validation and compilation process. The last-known-good binaries from \`$PREVIOUS_TAG\` were reused.

This exact failed input fingerprint will not be rebuilt on every nightly run. It will be tried again when a monitored source, feed, theme, package, overlay, local patch, patch policy, or patch-source revision changes.

Release assets contain only the full factory image and the sysupgrade image.
NOTES
  echo "Newest inputs failed; reused last-known-good binaries from $PREVIOUS_TAG."
  exit 0
fi

echo "The newest candidates failed and no prior nightly release was available for reuse." >&2
exit 1
