#!/usr/bin/env bash
set -euo pipefail

SCRIPT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

configure_git() {
  git -C "$1" config user.name 'Self Test'
  git -C "$1" config user.email 'self-test@example.invalid'
}

# Test 1: three-way source overlays retain independent changes from both trees.
PROJECT="$TEST_ROOT/project"
REPO="$TEST_ROOT/overlay-repo"
mkdir -p "$PROJECT" "$REPO/package/kernel/rtl837x/src"
cp "$SCRIPT_ROOT/apply-source-overlays.sh" "$PROJECT/apply-source-overlays.sh"
cat > "$PROJECT/source-overlays.conf" <<'CFG'
required|package/kernel/rtl837x/src/rtl837x_dsa_ops.c
optional|target/linux/qualcommbe/ipq53xx/base-files/etc/hotplug.d/net/30-ppe-flowtable
CFG

git -C "$REPO" init -q
configure_git "$REPO"
cat > "$REPO/package/kernel/rtl837x/src/rtl837x_dsa_ops.c" <<'SRC'
line-one
line-two
line-three
SRC
git -C "$REPO" add .
git -C "$REPO" commit -qm ancestor
ANCESTOR="$(git -C "$REPO" rev-parse HEAD)"

git -C "$REPO" branch perceival
git -C "$REPO" branch kakatkar

git -C "$REPO" checkout -q perceival
sed -i 's/line-one/perceival-one/' "$REPO/package/kernel/rtl837x/src/rtl837x_dsa_ops.c"
git -C "$REPO" commit -qam 'perceival change'

git -C "$REPO" checkout -q kakatkar
sed -i 's/line-three/kakatkar-three/' "$REPO/package/kernel/rtl837x/src/rtl837x_dsa_ops.c"
git -C "$REPO" commit -qam 'kakatkar change'
KAKATKAR="$(git -C "$REPO" rev-parse HEAD)"

git -C "$REPO" checkout -q perceival
PROJECT_ROOT="$PROJECT" bash "$PROJECT/apply-source-overlays.sh" "$REPO" "$KAKATKAR" "$TEST_ROOT/overlay-manifest.txt"
grep -Fxq 'perceival-one' "$REPO/package/kernel/rtl837x/src/rtl837x_dsa_ops.c"
grep -Fxq 'kakatkar-three' "$REPO/package/kernel/rtl837x/src/rtl837x_dsa_ops.c"
grep -q '^MERGED' "$TEST_ROOT/overlay-manifest.txt"
grep -q '^MISSING-OPTIONAL' "$TEST_ROOT/overlay-manifest.txt"

# Test 2: a conflicting required overlay fails rather than choosing a side.
CONFLICT_REPO="$TEST_ROOT/conflict-repo"
git clone -q "$REPO" "$CONFLICT_REPO"
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
if PROJECT_ROOT="$PROJECT" bash "$PROJECT/apply-source-overlays.sh" "$CONFLICT_REPO" "$RIGHT" "$TEST_ROOT/conflict-manifest.txt"; then
  echo 'Expected the conflicting overlay test to fail.' >&2
  exit 1
fi
grep -q '^CONFLICT' "$TEST_ROOT/conflict-manifest.txt"

# Test 3: source URL parsing handles both version formats.
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

# Test 4: refreshed external patches are committed into the candidate tree.
PATCH_PROJECT="$TEST_ROOT/patch-project"
PATCH_SOURCE="$TEST_ROOT/patch-source"
PATCH_CANDIDATE="$TEST_ROOT/patch-candidate"
mkdir -p "$PATCH_PROJECT/patches/mac80211-ath12k" \
  "$PATCH_SOURCE/package/kernel/mac80211/patches/ath12k" \
  "$PATCH_CANDIDATE"
cp "$SCRIPT_ROOT/refresh-patches.sh" "$PATCH_PROJECT/refresh-patches.sh"
cat > "$PATCH_PROJECT/patch-sources.conf" <<CFG
local|file://$PATCH_SOURCE|main
CFG
cat > "$PATCH_SOURCE/package/kernel/mac80211/patches/ath12k/999-test.patch" <<'PATCH'
From: Self Test <self-test@example.invalid>
Subject: [PATCH] wifi: ath12k: test import

--- a/test.c
+++ b/test.c
@@ -1 +1 @@
-old
+new
PATCH

git -C "$PATCH_SOURCE" init -q -b main
configure_git "$PATCH_SOURCE"
git -C "$PATCH_SOURCE" add .
git -C "$PATCH_SOURCE" commit -qm 'add patch'

git -C "$PATCH_CANDIDATE" init -q -b main
configure_git "$PATCH_CANDIDATE"
touch "$PATCH_CANDIDATE/README"
git -C "$PATCH_CANDIDATE" add README
git -C "$PATCH_CANDIDATE" commit -qm base
PROJECT_ROOT="$PATCH_PROJECT" bash "$PATCH_PROJECT/refresh-patches.sh" \
  "$PATCH_CANDIDATE" "$TEST_ROOT/patch-cache" "$TEST_ROOT/patch-queue" "$TEST_ROOT/patch-manifest.txt"
git -C "$PATCH_CANDIDATE" ls-files --error-unmatch package/kernel/mac80211/patches/ath12k/999-test.patch >/dev/null
[[ "$(git -C "$PATCH_CANDIDATE" log -1 --format=%s)" == 'Import refreshed relevant upstream patches' ]]
grep -q '^IMPORTED' "$TEST_ROOT/patch-manifest.txt"

# Test 5: unavailable source fallback, integration, patch persistence, and payload.
FULL_PROJECT="$TEST_ROOT/full-project"
BASE_REMOTE="$TEST_ROOT/base-remote"
OVERLAY_REMOTE="$TEST_ROOT/overlay-remote"
PACKAGES_REMOTE="$TEST_ROOT/packages-remote"
LUCI_REMOTE="$TEST_ROOT/luci-remote"
FOOTSTRAP_REMOTE="$TEST_ROOT/footstrap-remote"
FULL_PATCH_REMOTE="$TEST_ROOT/full-patch-remote"
AVAILABLE_DIR="$TEST_ROOT/available"
mkdir -p "$FULL_PROJECT/scripts" "$FULL_PROJECT/patches/mac80211-ath12k" "$AVAILABLE_DIR"
cp "$SCRIPT_ROOT/apply-source-overlays.sh" \
   "$SCRIPT_ROOT/check-mac80211-source.sh" \
   "$SCRIPT_ROOT/nightly-build.sh" \
   "$SCRIPT_ROOT/refresh-patches.sh" \
   "$FULL_PROJECT/scripts/"
cp "$PROJECT/source-overlays.conf" "$FULL_PROJECT/source-overlays.conf"
: > "$FULL_PROJECT/patches/mac80211-ath12k/.keep"
touch "$AVAILABLE_DIR/backports-6.18.39.tar.zst"

mkdir -p "$BASE_REMOTE/package/kernel/mac80211" \
  "$BASE_REMOTE/package/kernel/rtl837x/src" \
  "$BASE_REMOTE/target/linux/qualcommbe/dts" \
  "$BASE_REMOTE/target/linux/qualcommbe/ipq53xx/base-files/etc/hotplug.d/net"
git -C "$BASE_REMOTE" init -q -b flint3-be9300
configure_git "$BASE_REMOTE"
cat > "$BASE_REMOTE/package/kernel/mac80211/Makefile" <<MK
PKG_VERSION:=6.18.39
PKG_SOURCE_URL:=file://$AVAILABLE_DIR
PKG_SOURCE:=backports-\$(PKG_VERSION).tar.zst
MK
cat > "$BASE_REMOTE/package/kernel/rtl837x/src/rtl837x_common.h" <<'SRC'
common-base
SRC
cat > "$BASE_REMOTE/package/kernel/rtl837x/src/rtl837x_dsa_ops.c" <<'SRC'
first
middle
last
SRC
cat > "$BASE_REMOTE/target/linux/qualcommbe/dts/ipq5332-gl-be9300.dts" <<'SRC'
dts-base
SRC
cat > "$BASE_REMOTE/target/linux/qualcommbe/ipq53xx/base-files/etc/hotplug.d/net/30-ppe-flowtable" <<'SRC'
ppe-base
SRC
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
git -C "$BASE_REMOTE" commit -qam 'later Flint base fix'
TEST_BASE_HEAD="$(git -C "$BASE_REMOTE" rev-parse HEAD)"

git clone -q "$BASE_REMOTE" "$OVERLAY_REMOTE"
configure_git "$OVERLAY_REMOTE"
git -C "$OVERLAY_REMOTE" checkout -q -B gl-be9300 "$COMMON_COMMIT"
sed -i 's/^last$/kakatkar-last/' "$OVERLAY_REMOTE/package/kernel/rtl837x/src/rtl837x_dsa_ops.c"
git -C "$OVERLAY_REMOTE" commit -qam 'secondary Flint fix'

mkdir -p "$PACKAGES_REMOTE" "$LUCI_REMOTE" "$FOOTSTRAP_REMOTE"
for repo in "$PACKAGES_REMOTE" "$LUCI_REMOTE" "$FOOTSTRAP_REMOTE"; do
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
Subject: [PATCH] wifi: ath12k: full flow test

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
local|file://$FULL_PATCH_REMOTE|main
CFG
cat > "$FULL_PROJECT/scripts/build.sh" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
[[ -d "$OPENWRT_LOCAL_SOURCE/.git" ]]
grep -Fxq 'perceival-first' "$OPENWRT_LOCAL_SOURCE/package/kernel/rtl837x/src/rtl837x_dsa_ops.c"
grep -Fxq 'kakatkar-last' "$OPENWRT_LOCAL_SOURCE/package/kernel/rtl837x/src/rtl837x_dsa_ops.c"
git -C "$OPENWRT_LOCAL_SOURCE" ls-files --error-unmatch package/kernel/mac80211/patches/ath12k/998-full-test.patch >/dev/null
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
MAX_BUILD_ATTEMPTS=3 \
NIGHTLY_ROOT="$TEST_ROOT/full-nightly" \
DOWNLOAD_CACHE_DIR="$TEST_ROOT/full-downloads" \
bash "$FULL_PROJECT/scripts/nightly-build.sh"

test -s "$FULL_PROJECT/release/flint3-full-factory.bin"
test -s "$FULL_PROJECT/release/flint3-sysupgrade.bin"
test "$(find "$FULL_PROJECT/release" -maxdepth 1 -type f -name '*.bin' | wc -l)" -eq 2
grep -Fq 'Source tier: `published-backports`' "$FULL_PROJECT/release-notes.md"
grep -Fq 'Patch tier: `refreshed`' "$FULL_PROJECT/release-notes.md"
grep -Fq 'MERGED' "$FULL_PROJECT/release-notes.md"
grep -Fq 'IMPORTED' "$FULL_PROJECT/release-notes.md"

echo 'All Flint 3 builder self-tests passed.'
