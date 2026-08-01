#!/usr/bin/env bash
set -euo pipefail

SCRIPT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_ROOT/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

configure_git() {
  git -C "$1" config user.name 'Self Test'
  git -C "$1" config user.email 'self-test@example.invalid'
}

# Test 1: three-way source overlays retain independent changes.
OVERLAY_PROJECT="$TEST_ROOT/overlay-project"
OVERLAY_REPO="$TEST_ROOT/overlay-repo"
mkdir -p "$OVERLAY_PROJECT" "$OVERLAY_REPO/package/kernel/rtl837x/src"
cp "$SCRIPT_ROOT/apply-source-overlays.sh" "$OVERLAY_PROJECT/apply-source-overlays.sh"
cat > "$OVERLAY_PROJECT/source-overlays.conf" <<'CFG'
required|package/kernel/rtl837x/src/rtl837x_dsa_ops.c
optional|target/linux/qualcommbe/ipq53xx/base-files/etc/hotplug.d/net/30-ppe-flowtable
CFG

git -C "$OVERLAY_REPO" init -q
configure_git "$OVERLAY_REPO"
cat > "$OVERLAY_REPO/package/kernel/rtl837x/src/rtl837x_dsa_ops.c" <<'SRC'
line-one
line-two
line-three
SRC
git -C "$OVERLAY_REPO" add .
git -C "$OVERLAY_REPO" commit -qm ancestor
ANCESTOR="$(git -C "$OVERLAY_REPO" rev-parse HEAD)"
git -C "$OVERLAY_REPO" branch perceival
git -C "$OVERLAY_REPO" branch kakatkar

git -C "$OVERLAY_REPO" checkout -q perceival
sed -i 's/line-one/perceival-one/' "$OVERLAY_REPO/package/kernel/rtl837x/src/rtl837x_dsa_ops.c"
git -C "$OVERLAY_REPO" commit -qam 'perceival change'

git -C "$OVERLAY_REPO" checkout -q kakatkar
sed -i 's/line-three/kakatkar-three/' "$OVERLAY_REPO/package/kernel/rtl837x/src/rtl837x_dsa_ops.c"
git -C "$OVERLAY_REPO" commit -qam 'kakatkar change'
KAKATKAR="$(git -C "$OVERLAY_REPO" rev-parse HEAD)"

git -C "$OVERLAY_REPO" checkout -q perceival
PROJECT_ROOT="$OVERLAY_PROJECT" bash "$OVERLAY_PROJECT/apply-source-overlays.sh" \
  "$OVERLAY_REPO" "$KAKATKAR" "$TEST_ROOT/overlay-manifest.txt"
grep -Fxq 'perceival-one' "$OVERLAY_REPO/package/kernel/rtl837x/src/rtl837x_dsa_ops.c"
grep -Fxq 'kakatkar-three' "$OVERLAY_REPO/package/kernel/rtl837x/src/rtl837x_dsa_ops.c"
grep -q '^MERGED' "$TEST_ROOT/overlay-manifest.txt"

# Test 2: conflicting required overlays fail.
CONFLICT_REPO="$TEST_ROOT/conflict-repo"
git clone -q "$OVERLAY_REPO" "$CONFLICT_REPO"
configure_git "$CONFLICT_REPO"
git -C "$CONFLICT_REPO" checkout -q "$ANCESTOR"
git -C "$CONFLICT_REPO" branch -f left "$ANCESTOR"
git -C "$CONFLICT_REPO" branch -f right "$ANCESTOR"
git -C "$CONFLICT_REPO" checkout -q left
sed -i 's/line-two/left-two/' "$CONFLICT_REPO/package/kernel/rtl837x/src/rtl837x_dsa_ops.c"
git -C "$CONFLICT_REPO" commit -qam left
git -C "$CONFLICT_REPO" checkout -q right
sed -i 's/line-two/right-two/' "$CONFLICT_REPO/package/kernel/rtl837x/src/rtl837x_dsa_ops.c"
git -C "$CONFLICT_REPO" commit -qam right
RIGHT="$(git -C "$CONFLICT_REPO" rev-parse HEAD)"
git -C "$CONFLICT_REPO" checkout -q left
if PROJECT_ROOT="$OVERLAY_PROJECT" bash "$OVERLAY_PROJECT/apply-source-overlays.sh" \
  "$CONFLICT_REPO" "$RIGHT" "$TEST_ROOT/conflict-manifest.txt"; then
  echo 'Expected the conflicting overlay test to fail.' >&2
  exit 1
fi
grep -q '^CONFLICT' "$TEST_ROOT/conflict-manifest.txt"

# Test 3: mac80211 source URL parsing handles both version formats.
SOURCE_ONE="$TEST_ROOT/source-one"
mkdir -p "$SOURCE_ONE/package/kernel/mac80211"
cat > "$SOURCE_ONE/package/kernel/mac80211/Makefile" <<'MK'
PKG_UPSTREAM_VERSION:=7.2-rc4
PKG_VERSION:=$(subst -rc,_rc,$(PKG_UPSTREAM_VERSION))
PKG_SOURCE_URL:=https://github.com/openwrt/backports/releases/download/backports-v$(PKG_UPSTREAM_VERSION)
PKG_SOURCE:=backports-$(PKG_UPSTREAM_VERSION).tar.zst
MK
URL_ONE="$(bash "$SCRIPT_ROOT/check-mac80211-source.sh" "$SOURCE_ONE" --print-only)"
[[ "$URL_ONE" == 'https://github.com/openwrt/backports/releases/download/backports-v7.2-rc4/backports-7.2-rc4.tar.zst' ]]

SOURCE_TWO="$TEST_ROOT/source-two"
mkdir -p "$SOURCE_TWO/package/kernel/mac80211"
cat > "$SOURCE_TWO/package/kernel/mac80211/Makefile" <<'MK'
PKG_VERSION:=6.18.39
PKG_SOURCE_URL:=https://github.com/openwrt/backports/releases/download/backports-v$(PKG_VERSION)
PKG_SOURCE:=backports-$(PKG_VERSION).tar.zst
MK
URL_TWO="$(bash "$SCRIPT_ROOT/check-mac80211-source.sh" "$SOURCE_TWO" --print-only)"
[[ "$URL_TWO" == 'https://github.com/openwrt/backports/releases/download/backports-v6.18.39/backports-6.18.39.tar.zst' ]]

# Test 4: required patch sources replace older same-path revisions, while
# disabled optional sources are not imported.
PATCH_PROJECT="$TEST_ROOT/patch-project"
REQUIRED_SOURCE="$TEST_ROOT/required-source"
OPTIONAL_SOURCE="$TEST_ROOT/optional-source"
PATCH_CANDIDATE="$TEST_ROOT/patch-candidate"
mkdir -p "$PATCH_PROJECT/patches/mac80211-ath12k" \
  "$REQUIRED_SOURCE/target/linux/qualcommbe/patches-6.18" \
  "$OPTIONAL_SOURCE/target/linux/qualcommbe/patches-6.18" \
  "$PATCH_CANDIDATE/target/linux/qualcommbe/patches-6.18"
cp "$SCRIPT_ROOT/refresh-patches.sh" "$PATCH_PROJECT/refresh-patches.sh"
cat > "$PATCH_PROJECT/patch-sources.conf" <<CFG
required-local|file://$REQUIRED_SOURCE|main|required
optional-local|file://$OPTIONAL_SOURCE|main|optional
CFG
cat > "$PATCH_CANDIDATE/target/linux/qualcommbe/patches-6.18/0500-ppe-test.patch" <<'PATCH'
From: Self Test <self-test@example.invalid>
Subject: [PATCH] net: ppe: old required revision

--- a/test.c
+++ b/test.c
@@ -1 +1 @@
-old
+older
PATCH
cat > "$REQUIRED_SOURCE/target/linux/qualcommbe/patches-6.18/0500-ppe-test.patch" <<'PATCH'
From: Self Test <self-test@example.invalid>
Subject: [PATCH] net: ppe: current required revision

--- a/test.c
+++ b/test.c
@@ -1 +1 @@
-old
+current
PATCH
cat > "$OPTIONAL_SOURCE/target/linux/qualcommbe/patches-6.18/0600-ppe-optional.patch" <<'PATCH'
From: Self Test <self-test@example.invalid>
Subject: [PATCH] net: ppe: optional revision

--- a/optional.c
+++ b/optional.c
@@ -1 +1 @@
-old
+optional
PATCH
for repo in "$REQUIRED_SOURCE" "$OPTIONAL_SOURCE"; do
  git -C "$repo" init -q -b main
  configure_git "$repo"
  git -C "$repo" add .
  git -C "$repo" commit -qm patch
done
git -C "$PATCH_CANDIDATE" init -q -b main
configure_git "$PATCH_CANDIDATE"
git -C "$PATCH_CANDIDATE" add .
git -C "$PATCH_CANDIDATE" commit -qm base
PROJECT_ROOT="$PATCH_PROJECT" REFRESH_OPTIONAL_PATCHES=0 \
  bash "$PATCH_PROJECT/refresh-patches.sh" \
    "$PATCH_CANDIDATE" "$TEST_ROOT/patch-cache" "$TEST_ROOT/patch-queue" \
    "$TEST_ROOT/patch-manifest.txt"
grep -q '^REPLACED-REQUIRED' "$TEST_ROOT/patch-manifest.txt"
grep -q '^SOURCE-SKIPPED.*optional-local' "$TEST_ROOT/patch-manifest.txt"
grep -q '^+current$' "$PATCH_CANDIDATE/target/linux/qualcommbe/patches-6.18/0500-ppe-test.patch"
test ! -e "$PATCH_CANDIDATE/target/linux/qualcommbe/patches-6.18/0600-ppe-optional.patch"

# Test 5: curated patches target the current qcom glue, flatten IPQ5332, and
# never patch dwc3-qcom-legacy.
CURATED_CANDIDATE="$TEST_ROOT/curated-candidate"
mkdir -p "$CURATED_CANDIDATE/target/linux/qualcommbe/dts"
git -C "$CURATED_CANDIDATE" init -q -b main
configure_git "$CURATED_CANDIDATE"
cat > "$CURATED_CANDIDATE/target/linux/qualcommbe/dts/ipq5332-gl-be9300.dts" <<'DTS'
&pcs1 {
	status = "okay";
};

&usb_dwc {
	status = "okay";
};

&usbphy0 {
	status = "okay";
};
DTS
git -C "$CURATED_CANDIDATE" add .
git -C "$CURATED_CANDIDATE" commit -qm base
PROJECT_ROOT="$PROJECT_ROOT" bash "$SCRIPT_ROOT/apply-curated-patches.sh" \
  "$CURATED_CANDIDATE" "$TEST_ROOT/curated-manifest.txt"
grep -q '^&usb {' "$CURATED_CANDIDATE/target/linux/qualcommbe/dts/ipq5332-gl-be9300.dts"
CURATED_KERNEL="$CURATED_CANDIDATE/target/linux/qualcommbe/patches-6.18/0900-usb-dwc3-qcom-flatten-ipq5332-and-select-phy-mux.patch"
test -s "$CURATED_KERNEL"
grep -Fq 'drivers/usb/dwc3/dwc3-qcom.c' "$CURATED_KERNEL"
grep -Fq 'qcom,snps-dwc3' "$CURATED_KERNEL"
grep -Fq 'regmap_write(tcsr, 0x10540, 0x1)' "$CURATED_KERNEL"
! grep -Fq 'dwc3-qcom-legacy.c' "$CURATED_KERNEL"

# Test 6: full orchestration falls back from unavailable backports, preserves
# required Kakatkar integration, applies curated patches, and emits two images.
FULL_PROJECT="$TEST_ROOT/full-project"
BASE_REMOTE="$TEST_ROOT/base-remote"
OVERLAY_REMOTE="$TEST_ROOT/full-overlay-remote"
PACKAGES_REMOTE="$TEST_ROOT/packages-remote"
LUCI_REMOTE="$TEST_ROOT/luci-remote"
FOOTSTRAP_REMOTE="$TEST_ROOT/footstrap-remote"
FULL_PATCH_REMOTE="$TEST_ROOT/full-patch-remote"
AVAILABLE_DIR="$TEST_ROOT/available"
mkdir -p "$FULL_PROJECT/scripts" "$FULL_PROJECT/patches/mac80211-ath12k" \
  "$FULL_PROJECT/patches/openwrt-source" "$FULL_PROJECT/patches/qualcommbe-6.18" \
  "$AVAILABLE_DIR"
cp "$SCRIPT_ROOT/apply-curated-patches.sh" \
   "$SCRIPT_ROOT/apply-source-overlays.sh" \
   "$SCRIPT_ROOT/check-mac80211-source.sh" \
   "$SCRIPT_ROOT/nightly-build.sh" \
   "$SCRIPT_ROOT/refresh-patches.sh" \
   "$FULL_PROJECT/scripts/"
cp -a "$PROJECT_ROOT/patches/openwrt-source/." "$FULL_PROJECT/patches/openwrt-source/"
cp -a "$PROJECT_ROOT/patches/qualcommbe-6.18/." "$FULL_PROJECT/patches/qualcommbe-6.18/"
cat > "$FULL_PROJECT/source-overlays.conf" <<'CFG'
required|package/kernel/rtl837x/src/rtl837x_dsa_ops.c
CFG
: > "$FULL_PROJECT/patches/mac80211-ath12k/.keep"
touch "$AVAILABLE_DIR/backports-6.18.39.tar.zst"

mkdir -p "$BASE_REMOTE/package/kernel/mac80211" \
  "$BASE_REMOTE/package/kernel/rtl837x/src" \
  "$BASE_REMOTE/target/linux/qualcommbe/dts"
git -C "$BASE_REMOTE" init -q -b flint3-be9300
configure_git "$BASE_REMOTE"
cat > "$BASE_REMOTE/package/kernel/mac80211/Makefile" <<MK
PKG_VERSION:=6.18.39
PKG_SOURCE_URL:=file://$AVAILABLE_DIR
PKG_SOURCE:=backports-\$(PKG_VERSION).tar.zst
MK
cat > "$BASE_REMOTE/package/kernel/rtl837x/src/rtl837x_dsa_ops.c" <<'SRC'
first
middle
last
SRC
cat > "$BASE_REMOTE/target/linux/qualcommbe/dts/ipq5332-gl-be9300.dts" <<'DTS'
&pcs1 {
	status = "okay";
};

&usb_dwc {
	status = "okay";
};

&usbphy0 {
	status = "okay";
};
DTS
git -C "$BASE_REMOTE" add .
git -C "$BASE_REMOTE" commit -qm ancestor
COMMON_COMMIT="$(git -C "$BASE_REMOTE" rev-parse HEAD)"

cat > "$BASE_REMOTE/package/kernel/mac80211/Makefile" <<'MK'
PKG_UPSTREAM_VERSION:=7.2-rc4
PKG_VERSION:=$(subst -rc,_rc,$(PKG_UPSTREAM_VERSION))
PKG_SOURCE_URL:=https://127.0.0.1:9/releases/backports-v$(PKG_UPSTREAM_VERSION)
PKG_SOURCE:=backports-$(PKG_UPSTREAM_VERSION).tar.zst
MK
git -C "$BASE_REMOTE" add package/kernel/mac80211/Makefile
git -C "$BASE_REMOTE" commit -qm 'unavailable backports bump'
TEST_BACKPORTS_BUMP="$(git -C "$BASE_REMOTE" rev-parse HEAD)"
sed -i 's/^first$/perceival-first/' "$BASE_REMOTE/package/kernel/rtl837x/src/rtl837x_dsa_ops.c"
git -C "$BASE_REMOTE" commit -qam 'later base fix'
TEST_BASE_HEAD="$(git -C "$BASE_REMOTE" rev-parse HEAD)"

git clone -q "$BASE_REMOTE" "$OVERLAY_REMOTE"
configure_git "$OVERLAY_REMOTE"
git -C "$OVERLAY_REMOTE" checkout -q -B gl-be9300 "$COMMON_COMMIT"
sed -i 's/^last$/kakatkar-last/' "$OVERLAY_REMOTE/package/kernel/rtl837x/src/rtl837x_dsa_ops.c"
git -C "$OVERLAY_REMOTE" commit -qam 'required Kakatkar fix'

for repo in "$PACKAGES_REMOTE" "$LUCI_REMOTE" "$FOOTSTRAP_REMOTE"; do
  mkdir -p "$repo"
  git -C "$repo" init -q -b main
  configure_git "$repo"
  touch "$repo/README"
  git -C "$repo" add README
  git -C "$repo" commit -qm init
done
TEST_PACKAGES_HEAD="$(git -C "$PACKAGES_REMOTE" rev-parse HEAD)"
TEST_LUCI_HEAD="$(git -C "$LUCI_REMOTE" rev-parse HEAD)"
TEST_FOOTSTRAP_HEAD="$(git -C "$FOOTSTRAP_REMOTE" rev-parse HEAD)"

mkdir -p "$FULL_PATCH_REMOTE/package/kernel/mac80211/patches/ath12k"
git -C "$FULL_PATCH_REMOTE" init -q -b main
configure_git "$FULL_PATCH_REMOTE"
cat > "$FULL_PATCH_REMOTE/package/kernel/mac80211/patches/ath12k/998-full-test.patch" <<'PATCH'
From: Self Test <self-test@example.invalid>
Subject: [PATCH] wifi: ath12k: required full-flow test

--- a/full.c
+++ b/full.c
@@ -1 +1 @@
-old
+new
PATCH
git -C "$FULL_PATCH_REMOTE" add .
git -C "$FULL_PATCH_REMOTE" commit -qm patch

cat > "$FULL_PROJECT/build.env" <<ENV
: "\${OPENWRT_REPOSITORY:=file://$BASE_REMOTE}"
: "\${OPENWRT_BRANCH:=flint3-be9300}"
: "\${OPENWRT_COMMIT:=$TEST_BASE_HEAD}"
: "\${PACKAGES_FEED_REPOSITORY:=file://$PACKAGES_REMOTE}"
: "\${PACKAGES_FEED_COMMIT:=$TEST_PACKAGES_HEAD}"
: "\${LUCI_FEED_REPOSITORY:=file://$LUCI_REMOTE}"
: "\${LUCI_FEED_COMMIT:=$TEST_LUCI_HEAD}"
: "\${FOOTSTRAP_REPOSITORY:=file://$FOOTSTRAP_REMOTE}"
: "\${FOOTSTRAP_COMMIT:=$TEST_FOOTSTRAP_HEAD}"
: "\${FOOTSTRAP_VERSION:=test}"
ENV
cat > "$FULL_PROJECT/patch-sources.conf" <<CFG
kakatkar-test|file://$FULL_PATCH_REMOTE|main|required
CFG
cat > "$FULL_PROJECT/scripts/build.sh" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
[[ -d "$OPENWRT_LOCAL_SOURCE/.git" ]]
grep -Fxq 'perceival-first' "$OPENWRT_LOCAL_SOURCE/package/kernel/rtl837x/src/rtl837x_dsa_ops.c"
grep -Fxq 'kakatkar-last' "$OPENWRT_LOCAL_SOURCE/package/kernel/rtl837x/src/rtl837x_dsa_ops.c"
grep -q '^&usb {' "$OPENWRT_LOCAL_SOURCE/target/linux/qualcommbe/dts/ipq5332-gl-be9300.dts"
git -C "$OPENWRT_LOCAL_SOURCE" ls-files --error-unmatch \
  package/kernel/mac80211/patches/ath12k/998-full-test.patch >/dev/null
git -C "$OPENWRT_LOCAL_SOURCE" ls-files --error-unmatch \
  target/linux/qualcommbe/patches-6.18/0900-usb-dwc3-qcom-flatten-ipq5332-and-select-phy-mux.patch >/dev/null
mkdir -p "$OUTPUT_DIR"
printf factory > "$OUTPUT_DIR/mock-factory.bin"
printf upgrade > "$OUTPUT_DIR/mock-sysupgrade.bin"
MOCK
chmod +x "$FULL_PROJECT/scripts/build.sh"

PROJECT_ROOT="$FULL_PROJECT" \
BASE_REPOSITORY="file://$BASE_REMOTE" \
BASE_BRANCH=flint3-be9300 \
OVERLAY_REPOSITORY="file://$OVERLAY_REMOTE" \
OVERLAY_BRANCH=gl-be9300 \
BACKPORTS_BUMP_COMMIT="$TEST_BACKPORTS_BUMP" \
MAX_HISTORY=1 \
MAX_OVERLAY_HISTORY=1 \
MAX_BUILD_ATTEMPTS=4 \
NIGHTLY_ROOT="$TEST_ROOT/full-nightly" \
DOWNLOAD_CACHE_DIR="$TEST_ROOT/full-downloads" \
bash "$FULL_PROJECT/scripts/nightly-build.sh"

test -s "$FULL_PROJECT/release/flint3-full-factory.bin"
test -s "$FULL_PROJECT/release/flint3-sysupgrade.bin"
test "$(find "$FULL_PROJECT/release" -maxdepth 1 -type f -name '*.bin' | wc -l)" -eq 2
grep -Fq 'Source tier: `published-backports`' "$FULL_PROJECT/release-notes.md"
grep -Fq 'Required Kakatkar changes' "$FULL_PROJECT/release-notes.md"
grep -Eq 'REPLACED-REQUIRED|IMPORTED' "$FULL_PROJECT/release-notes.md"
grep -Fq 'KERNEL-INSTALLED' "$FULL_PROJECT/release-notes.md"

echo 'All Flint 3 builder self-tests passed.'
