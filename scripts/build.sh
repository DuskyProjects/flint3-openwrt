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
ATH12K_PATCH_DIR="${ATH12K_PATCH_DIR:-$PROJECT_ROOT/patches/mac80211-ath12k}"
SOURCE_REQUIRED_FILE="${SOURCE_REQUIRED_FILE:-$PROJECT_ROOT/source.required}"
BUILD_VARIANT="${BUILD_VARIANT:-pinned}"

mapfile -t REQUIRED_PACKAGES < <(
	awk 'NF && $1 !~ /^#/ { print $1 }' "$PROJECT_ROOT/packages.required"
)

[[ ${#REQUIRED_PACKAGES[@]} -gt 0 ]] || {
	echo "packages.required is empty." >&2
	exit 1
}

[[ -s "$SOURCE_REQUIRED_FILE" ]] || {
	echo "Required-source manifest is missing or empty: $SOURCE_REQUIRED_FILE" >&2
	exit 1
}

bash -n "$PROJECT_ROOT/scripts/build.sh" "$PROJECT_ROOT/scripts/privacy-audit.sh"
sh -n \
	"$PROJECT_ROOT/files/etc/init.d/flint3-pstore" \
	"$PROJECT_ROOT/files/etc/uci-defaults/90-flint3-generic-defaults" \
	"$PROJECT_ROOT/files/etc/uci-defaults/99-footstrap-default" \
	"$PROJECT_ROOT/files/etc/profile.d/50-flint3-country-warning.sh" \
	"$PROJECT_ROOT/files/usr/bin/flint3-set-country"

bash "$PROJECT_ROOT/scripts/privacy-audit.sh" | tee "$PROJECT_ROOT/privacy-audit.txt"

mkdir -p "$WORK_ROOT" "$OUTPUT_DIR"
rm -rf "$OPENWRT_DIR" "$FOOTSTRAP_DIR"

git clone --filter=blob:none --single-branch \
	--branch "$OPENWRT_BRANCH" \
	"https://github.com/$OPENWRT_REPOSITORY.git" "$OPENWRT_DIR"
git -C "$OPENWRT_DIR" checkout --detach "$OPENWRT_COMMIT"
[[ "$(git -C "$OPENWRT_DIR" rev-parse HEAD)" == "$OPENWRT_COMMIT" ]]

source_check="$PROJECT_ROOT/source-verification.txt"
: > "$source_check"
while IFS=$'\t' read -r commit description; do
	[[ -n "$commit" && "$commit" != \#* ]] || continue
	if git -C "$OPENWRT_DIR" merge-base --is-ancestor "$commit" HEAD; then
		printf 'OK  %s  %s\n' "$commit" "$description" | tee -a "$source_check"
	else
		printf 'MISSING  %s  %s\n' "$commit" "$description" | tee -a "$source_check" >&2
		exit 1
	fi
done < "$SOURCE_REQUIRED_FILE"

git clone --filter=blob:none \
	"https://github.com/$FOOTSTRAP_REPOSITORY.git" "$FOOTSTRAP_DIR"
git -C "$FOOTSTRAP_DIR" checkout --detach "$FOOTSTRAP_COMMIT"
[[ "$(git -C "$FOOTSTRAP_DIR" rev-parse HEAD)" == "$FOOTSTRAP_COMMIT" ]]

cd "$OPENWRT_DIR"

# Carry reviewed portable patches which are not yet in the selected source.
# An identical upstream copy is accepted and recorded; a conflicting file with
# the same name stops the build rather than being overwritten silently.
custom_patch_manifest="$PROJECT_ROOT/custom-patches.txt"
: > "$custom_patch_manifest"
if compgen -G "$ATH12K_PATCH_DIR/*.patch" >/dev/null; then
	mkdir -p package/kernel/mac80211/patches/ath12k
	for patch in "$ATH12K_PATCH_DIR"/*.patch; do
		dest="package/kernel/mac80211/patches/ath12k/$(basename "$patch")"
		if [[ -e "$dest" ]]; then
			if cmp -s "$patch" "$dest"; then
				printf 'UPSTREAM  ' | tee -a "$custom_patch_manifest"
				sha256sum "$patch" | tee -a "$custom_patch_manifest"
				continue
			fi
			echo "Conflicting upstream ath12k patch: $dest" >&2
			exit 1
		fi
		install -m 0644 "$patch" "$dest"
		cmp -s "$patch" "$dest" || {
			echo "Custom patch copy verification failed: $patch" >&2
			exit 1
		}
		printf 'APPLIED   ' | tee -a "$custom_patch_manifest"
		sha256sum "$patch" | tee -a "$custom_patch_manifest"
	done
fi

cat > feeds.conf <<FEEDS
src-git packages https://github.com/$PACKAGES_FEED_REPOSITORY.git^$PACKAGES_FEED_COMMIT
src-git luci https://github.com/$LUCI_FEED_REPOSITORY.git^$LUCI_FEED_COMMIT
FEEDS

./scripts/feeds update -a
./scripts/feeds install -a

[[ "$(git -C feeds/packages rev-parse HEAD)" == "$PACKAGES_FEED_COMMIT" ]] || {
	echo "Packages feed did not resolve to the selected commit." >&2
	exit 1
}
[[ "$(git -C feeds/luci rev-parse HEAD)" == "$LUCI_FEED_COMMIT" ]] || {
	echo "LuCI feed did not resolve to the selected commit." >&2
	exit 1
}

rm -rf package/luci-theme-footstrap
cp -a "$FOOTSTRAP_DIR/luci-theme-footstrap" package/luci-theme-footstrap

# GitHub's contents API creates files as 0644. Apply firmware-side modes before
# copying the overlay into the OpenWrt tree.
chmod 0755 \
	"$PROJECT_ROOT/files/etc/init.d/flint3-pstore" \
	"$PROJECT_ROOT/files/etc/uci-defaults/90-flint3-generic-defaults" \
	"$PROJECT_ROOT/files/etc/uci-defaults/99-footstrap-default" \
	"$PROJECT_ROOT/files/usr/bin/flint3-set-country"
chmod 0644 "$PROJECT_ROOT/files/etc/profile.d/50-flint3-country-warning.sh"

cp -a "$PROJECT_ROOT/files/." files/
cp "$PROJECT_ROOT/config.seed" .config

export FOOTSTRAP_VERSION
make defconfig

missing_config=0
for package in "${REQUIRED_PACKAGES[@]}"; do
	if ! grep -Fxq "CONFIG_PACKAGE_${package}=y" .config; then
		echo "Required package was not selected after make defconfig: $package" >&2
		missing_config=1
	fi
done
(( missing_config == 0 )) || exit 1

./scripts/diffconfig.sh | tee flint3-build.diffconfig

make download -j"$JOBS"
if find dl -type f -size 0 -print -quit | grep -q .; then
	echo "Zero-byte source downloads found:" >&2
	find dl -type f -size 0 -print >&2
	exit 1
fi

make -j"$JOBS" V=s || make -j1 V=sc

TARGET_DIR="$OPENWRT_DIR/bin/targets/qualcommbe/ipq53xx"
[[ -d "$TARGET_DIR" ]] || {
	echo "Missing output directory: $TARGET_DIR" >&2
	exit 1
}

mapfile -t FACTORY_IMAGES < <(
	find "$TARGET_DIR" -maxdepth 1 -type f -name '*gl-be9300*factory.bin' -print | sort
)
mapfile -t SYSUPGRADE_IMAGES < <(
	find "$TARGET_DIR" -maxdepth 1 -type f -name '*gl-be9300*sysupgrade.bin' -print | sort
)
mapfile -t IMAGE_MANIFESTS < <(
	find "$TARGET_DIR" -maxdepth 1 -type f -name '*gl-be9300*.manifest' -print | sort
)

if [[ ${#FACTORY_IMAGES[@]} -ne 1 || ${#SYSUPGRADE_IMAGES[@]} -ne 1 ]]; then
	echo "Expected exactly one factory image and one sysupgrade image." >&2
	find "$TARGET_DIR" -maxdepth 1 -type f -printf '%f\n' >&2
	exit 1
fi

if [[ ${#IMAGE_MANIFESTS[@]} -lt 1 ]]; then
	echo "No GL-BE9300 image package manifest was generated." >&2
	exit 1
fi

FACTORY="${FACTORY_IMAGES[0]}"
SYSUPGRADE="${SYSUPGRADE_IMAGES[0]}"
IMAGE_MANIFEST="${IMAGE_MANIFESTS[0]}"

DUMPIMAGE="$OPENWRT_DIR/staging_dir/host/bin/dumpimage"
[[ -x "$DUMPIMAGE" ]] || DUMPIMAGE="$OPENWRT_DIR/staging_dir/host/bin/mkimage"
[[ -x "$DUMPIMAGE" ]] || {
	echo "Could not find the host dumpimage/mkimage utility." >&2
	exit 1
}

FIT_LIST="$TARGET_DIR/gl-be9300-factory-fit.txt"
"$DUMPIMAGE" -l "$FACTORY" | tee "$FIT_LIST"
grep -Eq 'Image [0-9]+ \(hlos\)' "$FIT_LIST" || {
	echo "factory.bin lacks the required hlos payload." >&2
	exit 1
}
grep -Eq 'Image [0-9]+ \(rootfs\)' "$FIT_LIST" || {
	echo "factory.bin lacks the required rootfs payload." >&2
	exit 1
}

manifest_packages="$(mktemp)"
trap 'rm -f "$manifest_packages"' EXIT
awk 'NF { print $1 }' "$IMAGE_MANIFEST" | sort -u > "$manifest_packages"

missing_manifest=0
for package in "${REQUIRED_PACKAGES[@]}"; do
	if ! grep -Fxq "$package" "$manifest_packages"; then
		echo "Required package missing from finished image manifest: $package" >&2
		missing_manifest=1
	fi
done
(( missing_manifest == 0 )) || exit 1

rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"
cp -v "$FACTORY" "$SYSUPGRADE" "$OUTPUT_DIR/"
cp -v "$IMAGE_MANIFEST" "$OUTPUT_DIR/"
cp -v "$FIT_LIST" "$OUTPUT_DIR/"
cp -v "$TARGET_DIR/sha256sums" "$OUTPUT_DIR/"
cp -v "$TARGET_DIR/profiles.json" "$OUTPUT_DIR/" 2>/dev/null || true
cp -v .config "$OUTPUT_DIR/build.config"
cp -v flint3-build.diffconfig "$OUTPUT_DIR/"
cp -v feeds.conf "$OUTPUT_DIR/"
cp -v "$PROJECT_ROOT/packages.required" "$OUTPUT_DIR/"
cp -v "$SOURCE_REQUIRED_FILE" "$OUTPUT_DIR/source.required"
cp -v "$source_check" "$OUTPUT_DIR/"
cp -v "$custom_patch_manifest" "$OUTPUT_DIR/"
cp -v "$PROJECT_ROOT/privacy-audit.txt" "$OUTPUT_DIR/"

cat > "$OUTPUT_DIR/SOURCES.txt" <<SOURCES
Build variant:       $BUILD_VARIANT
OpenWrt repository: $OPENWRT_REPOSITORY
OpenWrt branch:     $OPENWRT_BRANCH
OpenWrt commit:     $OPENWRT_COMMIT
Packages feed:      $PACKAGES_FEED_REPOSITORY
Packages commit:    $PACKAGES_FEED_COMMIT
LuCI feed:          $LUCI_FEED_REPOSITORY
LuCI commit:        $LUCI_FEED_COMMIT
Footstrap repo:     $FOOTSTRAP_REPOSITORY
Footstrap commit:   $FOOTSTRAP_COMMIT
Footstrap version:  $FOOTSTRAP_VERSION
SOURCES

sha256sum "$OUTPUT_DIR"/*.bin | tee "$OUTPUT_DIR/IMAGE-SHA256SUMS"
ls -lh "$OUTPUT_DIR"
