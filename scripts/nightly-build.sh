#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
# shellcheck disable=SC1091
source "$PROJECT_ROOT/build.env"

NIGHTLY_ROOT="${NIGHTLY_ROOT:-$PROJECT_ROOT/nightly-work}"
SOURCE_ROOT="$NIGHTLY_ROOT/source"
ATTEMPT_ROOT="$NIGHTLY_ROOT/attempts"
CCACHE_ROOT="$NIGHTLY_ROOT/ccache"
RELEASE_DIR="$PROJECT_ROOT/release"
JOBS="${JOBS:-4}"
DATE_UTC="$(date -u +%Y%m%d)"
DATE_DISPLAY="$(date -u +%Y-%m-%d)"

rm -rf "$SOURCE_ROOT" "$ATTEMPT_ROOT" "$RELEASE_DIR"
mkdir -p "$SOURCE_ROOT" "$ATTEMPT_ROOT" "$CCACHE_ROOT" "$RELEASE_DIR"

repository_url() {
  local repository="$1"
  case "$repository" in
    http://*|https://*|file://*|/*) printf '%s\n' "$repository" ;;
    *) printf 'https://github.com/%s.git\n' "$repository" ;;
  esac
}

base_source="$SOURCE_ROOT/perceival"
prepared_source="$SOURCE_ROOT/prepared"
curated_manifest="$SOURCE_ROOT/CURATED-PATCHES.txt"
source_record="$SOURCE_ROOT/SOURCES.txt"
empty_ath12k_dir="$SOURCE_ROOT/no-extra-ath12k-patches"
attempt_dir="$ATTEMPT_ROOT/build-1"
output_dir="$attempt_dir/output"
log_file="$attempt_dir/build.log"

mkdir -p "$empty_ath12k_dir" "$attempt_dir"

git clone --filter=blob:none --single-branch --branch "$OPENWRT_BRANCH" \
  "$(repository_url "$OPENWRT_REPOSITORY")" "$base_source"
git -C "$base_source" checkout --detach "$OPENWRT_COMMIT"
[[ "$(git -C "$base_source" rev-parse HEAD)" == "$OPENWRT_COMMIT" ]] || {
  echo "Perceival source did not resolve to the pinned commit." >&2
  exit 1
}

# Transfer only the pinned source HEAD. No secondary tree, overlay branch, or
# external patch feed participates in this build.
mkdir -p "$prepared_source"
git -C "$prepared_source" init -q
git -C "$prepared_source" fetch --no-tags "$base_source" HEAD
git -C "$prepared_source" checkout --detach --force FETCH_HEAD
git -C "$prepared_source" config user.name 'DuskyProjects Builder'
git -C "$prepared_source" config user.email 'actions@users.noreply.github.com'

bash "$PROJECT_ROOT/scripts/check-mac80211-source.sh" "$prepared_source" >/dev/null
bash "$PROJECT_ROOT/scripts/apply-curated-patches.sh" \
  "$prepared_source" "$curated_manifest"

prepared_commit="$(git -C "$prepared_source" rev-parse HEAD)"
cat > "$source_record" <<SOURCES
Base repository:    $OPENWRT_REPOSITORY
Base branch:        $OPENWRT_BRANCH
Base commit:        $OPENWRT_COMMIT
Prepared commit:    $prepared_commit
Integration policy: Perceival source plus curated local USB/ramoops patches only
SOURCES

printf '%s\n' \
  '============================================================' \
  'Controlled Perceival-only build' \
  "Perceival source: $OPENWRT_COMMIT" \
  "Prepared source:  $prepared_commit" \
  'External overlays: disabled' \
  'External patch intake: disabled' \
  '============================================================'

if ! env \
  OPENWRT_LOCAL_SOURCE="$prepared_source" \
  OPENWRT_REPOSITORY="$OPENWRT_REPOSITORY" \
  OPENWRT_BRANCH="$OPENWRT_BRANCH" \
  OPENWRT_COMMIT="$prepared_commit" \
  PACKAGES_FEED_COMMIT="$PACKAGES_FEED_COMMIT" \
  LUCI_FEED_COMMIT="$LUCI_FEED_COMMIT" \
  FOOTSTRAP_COMMIT="$FOOTSTRAP_COMMIT" \
  FOOTSTRAP_VERSION="$FOOTSTRAP_VERSION" \
  FIRMWARE_BUILD_LABEL="perceival-usb" \
  MERGED_SOURCE_RECORD="$source_record" \
  ATH12K_PATCH_DIR="$empty_ath12k_dir" \
  WORK_ROOT="$attempt_dir/work" \
  OUTPUT_DIR="$output_dir" \
  DOWNLOAD_CACHE_DIR="${DOWNLOAD_CACHE_DIR:-$NIGHTLY_ROOT/dl}" \
  CCACHE_DIR="$CCACHE_ROOT" \
  CCACHE_MAX_SIZE="${CCACHE_MAX_SIZE:-10G}" \
  JOBS="$JOBS" \
  bash "$PROJECT_ROOT/scripts/build.sh" >"$log_file" 2>&1; then
  echo "Perceival-only build failed. Full log: $log_file" >&2
  tail -n 200 "$log_file" >&2 || true
  exit 1
fi

tail -n 80 "$log_file" || true

mapfile -t factory_images < <(find "$output_dir" -maxdepth 1 -type f -name '*factory.bin' -print)
mapfile -t sysupgrade_images < <(find "$output_dir" -maxdepth 1 -type f -name '*sysupgrade.bin' -print)
[[ ${#factory_images[@]} -eq 1 && ${#sysupgrade_images[@]} -eq 1 ]] || {
  echo "Build output did not contain exactly one factory and one sysupgrade image." >&2
  exit 1
}

install -m 0644 "${factory_images[0]}" "$RELEASE_DIR/flint3-full-factory.bin"
install -m 0644 "${sysupgrade_images[0]}" "$RELEASE_DIR/flint3-sysupgrade.bin"

cat > "$PROJECT_ROOT/nightly-release.env" <<ENV
RELEASE_TAG='nightly-$DATE_UTC'
RELEASE_TITLE='Flint 3 Perceival Build $DATE_DISPLAY'
FACTORY_FILE='$RELEASE_DIR/flint3-full-factory.bin'
SYSUPGRADE_FILE='$RELEASE_DIR/flint3-sysupgrade.bin'
ENV

cat > "$PROJECT_ROOT/release-notes.md" <<NOTES
<!-- base-source: $OPENWRT_REPOSITORY@$OPENWRT_COMMIT -->
<!-- packages-source: $PACKAGES_FEED_REPOSITORY@$PACKAGES_FEED_COMMIT -->
<!-- luci-source: $LUCI_FEED_REPOSITORY@$LUCI_FEED_COMMIT -->
<!-- footstrap-source: $FOOTSTRAP_REPOSITORY@$FOOTSTRAP_COMMIT -->

# Flint 3 Perceival build — $DATE_DISPLAY

## Source policy

This firmware is built from the pinned Perceival Flint 3 tree. No Kakatkar branch overlay, patch intake, source replacement, or secondary integration is used.

The only source changes added by this builder are the reviewed local IPQ5332 USB/DWC3 mux migration and ramoops retention patches.

## Assets

- \`flint3-full-factory.bin\`
- \`flint3-sysupgrade.bin\`
NOTES

sha256sum "$RELEASE_DIR"/*.bin
