#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
# shellcheck disable=SC1091
source "$PROJECT_ROOT/build.env"

NIGHTLY_ROOT="${NIGHTLY_ROOT:-$PROJECT_ROOT/nightly-work}"
RELEASE_DIR="$PROJECT_ROOT/release"
DATE_UTC="$(date -u +%Y%m%d)"
DATE_DISPLAY="$(date -u +%Y-%m-%d)"

mkdir -p "$NIGHTLY_ROOT/dl" "$NIGHTLY_ROOT/ccache"

release_field() {
  local body="$1" field="$2"
  printf '%s\n' "$body" | sed -n "s/^<!-- ${field}: \(.*\) -->$/\1/p" | head -n1
}

write_release_env() {
  cat > "$PROJECT_ROOT/nightly-release.env" <<ENV
RELEASE_TAG='nightly-$DATE_UTC'
RELEASE_TITLE='Flint 3 Perceival Build $DATE_DISPLAY'
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

BUILDER_HASH="$({
  git -C "$PROJECT_ROOT" ls-files -s -- \
    build.env \
    config.seed \
    packages.required \
    source.required \
    patches/qualcommbe-6.18 \
    patches/openwrt-source \
    files \
    scripts/apply-curated-patches.sh \
    scripts/build.sh \
    scripts/check-mac80211-source.sh \
    scripts/nightly-build.sh \
    scripts/nightly-or-reuse.sh \
    scripts/prepare-backports-source.sh \
    scripts/privacy-audit.sh \
    scripts/retain-flint3-ramoops.sh \
    .github/workflows/build.yml
} | sha256sum | awk '{print $1}')"

ATTEMPTED_FINGERPRINT="$({
  printf 'base=%s@%s\n' "$OPENWRT_REPOSITORY" "$OPENWRT_COMMIT"
  printf 'backports=%s@%s\n' "$BACKPORTS_REPOSITORY" "$BACKPORTS_COMMIT"
  printf 'linux=%s@%s\n' "$BACKPORTS_LINUX_REPOSITORY" "$BACKPORTS_LINUX_COMMIT"
  printf 'packages=%s@%s\n' "$PACKAGES_FEED_REPOSITORY" "$PACKAGES_FEED_COMMIT"
  printf 'luci=%s@%s\n' "$LUCI_FEED_REPOSITORY" "$LUCI_FEED_COMMIT"
  printf 'footstrap=%s@%s\n' "$FOOTSTRAP_REPOSITORY" "$FOOTSTRAP_COMMIT"
  printf 'builder=%s\n' "$BUILDER_HASH"
} | sha256sum | awk '{print $1}')"

previous_tag=''
previous_body=''
previous_attempted=''
previous_build=''

if command -v gh >/dev/null 2>&1 && [[ -n "${GH_TOKEN:-}" ]]; then
  previous_tag="$(gh release list --limit 100 \
    --json tagName,isPrerelease,publishedAt \
    --jq '[.[] | select(.isPrerelease == true and (.tagName | startswith("nightly-")))] | sort_by(.publishedAt) | last | .tagName // ""' \
    2>/dev/null || true)"

  if [[ -n "$previous_tag" ]]; then
    previous_body="$(gh release view "$previous_tag" --json body --jq .body 2>/dev/null || true)"
    previous_attempted="$(release_field "$previous_body" attempted-fingerprint)"
    previous_build="$(release_field "$previous_body" build-fingerprint)"
  fi
fi

if [[ -n "$previous_tag" && "$previous_attempted" == "$ATTEMPTED_FINGERPRINT" ]]; then
  if download_release_assets "$previous_tag"; then
    build_fingerprint="${previous_build:-$(binary_fingerprint)}"
    write_release_env
    cat > "$PROJECT_ROOT/release-notes.md" <<NOTES
<!-- attempted-fingerprint: $ATTEMPTED_FINGERPRINT -->
<!-- build-fingerprint: $build_fingerprint -->
<!-- build-status: unchanged-reuse -->
<!-- base-source: $OPENWRT_REPOSITORY@$OPENWRT_COMMIT -->
<!-- backports-generator: $BACKPORTS_REPOSITORY@$BACKPORTS_COMMIT -->
<!-- backports-linux: $BACKPORTS_LINUX_REPOSITORY@$BACKPORTS_LINUX_COMMIT -->
<!-- packages-source: $PACKAGES_FEED_REPOSITORY@$PACKAGES_FEED_COMMIT -->
<!-- luci-source: $LUCI_FEED_REPOSITORY@$LUCI_FEED_COMMIT -->
<!-- footstrap-source: $FOOTSTRAP_REPOSITORY@$FOOTSTRAP_COMMIT -->

# Flint 3 Perceival build — $DATE_DISPLAY

No firmware-relevant Perceival source, generated backports input, feed, package, curated USB patch, or builder input changed since `$previous_tag`. The previously validated binaries were reused.
NOTES
    echo "No relevant inputs changed; reused binaries from $previous_tag."
    exit 0
  fi
fi

export DOWNLOAD_CACHE_DIR="$NIGHTLY_ROOT/dl"
export CCACHE_DIR="$NIGHTLY_ROOT/ccache"
export CCACHE_MAX_SIZE="${CCACHE_MAX_SIZE:-3G}"

bash "$PROJECT_ROOT/scripts/nightly-build.sh"

build_fingerprint="$(binary_fingerprint)"
original_notes="$(cat "$PROJECT_ROOT/release-notes.md")"
cat > "$PROJECT_ROOT/release-notes.md" <<NOTES
<!-- attempted-fingerprint: $ATTEMPTED_FINGERPRINT -->
<!-- build-fingerprint: $build_fingerprint -->
<!-- build-status: compiled -->

$original_notes
NOTES
