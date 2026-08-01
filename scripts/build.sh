#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$PROJECT_ROOT/build.env"

WORK_ROOT="${WORK_ROOT:-$PROJECT_ROOT/work}"
OPENWRT_DIR="$WORK_ROOT/openwrt"
FOOTSTRAP_DIR="$WORK_ROOT/footstrap"
OUTPUT_DIR="${OUTPUT_DIR:-$PROJECT_ROOT/artifacts}"
JOBS="${JOBS:-$(nproc)}"

mkdir -p "$WORK_ROOT" "$OUTPUT_DIR"
rm -rf "$OPENWRT_DIR" "$FOOTSTRAP_DIR"

git clone --filter=blob:none --single-branch \
  --branch "$OPENWRT_BRANCH" \
  "https://github.com/$OPENWRT_REPOSITORY.git" "$OPENWRT_DIR"
git -C "$OPENWRT_DIR" checkout --detach "$OPENWRT_COMMIT"

git clone --filter=blob:none \
  "https://github.com/$FOOTSTRAP_REPOSITORY.git" "$FOOTSTRAP_DIR"
git -C "$FOOTSTRAP_DIR" checkout --detach "$FOOTSTRAP_COMMIT"

cd "$OPENWRT_DIR"
./scripts/feeds update -a
./scripts/feeds install -a

rm -rf package/luci-theme-footstrap
cp -a "$FOOTSTRAP_DIR/luci-theme-footstrap" package/luci-theme-footstrap
cp -a "$PROJECT_ROOT/files/." files/
cp "$PROJECT_ROOT/config.seed" .config

export FOOTSTRAP_VERSION
make defconfig
make download -j"$JOBS"
make -j"$JOBS" V=s || make -j1 V=sc

TARGET_DIR="$OPENWRT_DIR/bin/targets/qualcommbe/ipq53xx"
rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"

find "$TARGET_DIR" -maxdepth 1 -type f -name '*gl-be9300*factory.bin' -exec cp -v {} "$OUTPUT_DIR/" \;
find "$TARGET_DIR" -maxdepth 1 -type f -name '*gl-be9300*sysupgrade.bin' -exec cp -v {} "$OUTPUT_DIR/" \;
cp -v "$TARGET_DIR/sha256sums" "$OUTPUT_DIR/"
cp -v "$TARGET_DIR/profiles.json" "$OUTPUT_DIR/" 2>/dev/null || true
cp -v .config "$OUTPUT_DIR/build.config"
make package/index >/dev/null
find bin/packages -type f \( -name 'Packages.manifest' -o -name 'Packages' \) -exec cp -v {} "$OUTPUT_DIR/" \; 2>/dev/null || true

cat > "$OUTPUT_DIR/SOURCES.txt" <<SOURCES
OpenWrt repository: $OPENWRT_REPOSITORY
OpenWrt branch:     $OPENWRT_BRANCH
OpenWrt commit:     $OPENWRT_COMMIT
Footstrap repo:     $FOOTSTRAP_REPOSITORY
Footstrap commit:   $FOOTSTRAP_COMMIT
Footstrap version:  $FOOTSTRAP_VERSION
SOURCES

FACTORY_COUNT="$(find "$OUTPUT_DIR" -maxdepth 1 -type f -name '*factory.bin' | wc -l)"
SYSUPGRADE_COUNT="$(find "$OUTPUT_DIR" -maxdepth 1 -type f -name '*sysupgrade.bin' | wc -l)"

if [[ "$FACTORY_COUNT" -ne 1 || "$SYSUPGRADE_COUNT" -ne 1 ]]; then
  echo "Expected exactly one factory image and one sysupgrade image." >&2
  find "$OUTPUT_DIR" -maxdepth 1 -type f -printf '%f\n' >&2
  exit 1
fi

sha256sum "$OUTPUT_DIR"/*.bin | tee "$OUTPUT_DIR/IMAGE-SHA256SUMS"
ls -lh "$OUTPUT_DIR"
