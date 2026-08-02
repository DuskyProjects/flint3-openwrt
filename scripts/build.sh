#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/build.env"

WORK_ROOT="${WORK_ROOT:-$ROOT/work}"
OPENWRT_TREE="$WORK_ROOT/openwrt"
DOWNLOAD_DIR="$WORK_ROOT/dl"
RELEASE_DIR="${RELEASE_DIR:-$ROOT/release}"
JOBS="${JOBS:-4}"

rm -rf "$OPENWRT_TREE" "$RELEASE_DIR"
mkdir -p "$OPENWRT_TREE" "$DOWNLOAD_DIR" "$RELEASE_DIR"

git -C "$OPENWRT_TREE" init -q
git -C "$OPENWRT_TREE" remote add origin "https://github.com/$OPENWRT_REPOSITORY.git"
git -C "$OPENWRT_TREE" fetch --depth=1 --no-tags origin "$OPENWRT_COMMIT"
git -C "$OPENWRT_TREE" checkout --detach --force FETCH_HEAD

resolved_commit="$(git -C "$OPENWRT_TREE" rev-parse HEAD)"
if [[ "$resolved_commit" != "$OPENWRT_COMMIT" ]]; then
  echo "Expected Percival commit $OPENWRT_COMMIT, got $resolved_commit" >&2
  exit 1
fi

git -C "$OPENWRT_TREE" apply \
  "$ROOT/patches/openwrt/0900-ipq5332-gl-be9300-enable-usb-phy-mux.patch"

kernel_patch_dir="$OPENWRT_TREE/target/linux/qualcommbe/patches-6.18"
test -d "$kernel_patch_dir"
install -m 0644 \
  "$ROOT/patches/kernel/2989-dt-bindings-usb-qcom-document-multiplexed-phy.patch" \
  "$kernel_patch_dir/2989-dt-bindings-usb-qcom-document-multiplexed-phy.patch"
install -m 0644 \
  "$ROOT/patches/kernel/2990-usb-dwc3-qcom-flatten-ipq5332-and-select-phy-mux.patch" \
  "$kernel_patch_dir/2990-usb-dwc3-qcom-flatten-ipq5332-and-select-phy-mux.patch"

bash "$ROOT/scripts/prepare-backports.sh" "$OPENWRT_TREE" "$DOWNLOAD_DIR"

(
  cd "$OPENWRT_TREE"

  ./scripts/feeds update -a
  ./scripts/feeds install -a

  cp "$ROOT/config.seed" .config
  make defconfig

  grep -Fq 'CONFIG_TARGET_qualcommbe_ipq53xx_DEVICE_glinet_gl-be9300=y' .config
  grep -Fq 'CONFIG_PACKAGE_iperf3=y' .config
  grep -Fq 'CONFIG_PACKAGE_kmod-usb-dwc3-qcom=y' .config

  make download -j"$JOBS"
  make -j"$JOBS" V=s
)

target_dir="$OPENWRT_TREE/bin/targets/qualcommbe/ipq53xx"
test -d "$target_dir"

factory_file="$(find "$target_dir" -maxdepth 1 -type f \
  -name '*gl-be9300*factory*.bin' -print -quit)"
sysupgrade_file="$(find "$target_dir" -maxdepth 1 -type f \
  -name '*gl-be9300*sysupgrade*.bin' -print -quit)"

test -n "$factory_file"
test -n "$sysupgrade_file"
test -s "$factory_file"
test -s "$sysupgrade_file"

install -m 0644 "$factory_file" "$RELEASE_DIR/flint3-full-factory.bin"
install -m 0644 "$sysupgrade_file" "$RELEASE_DIR/flint3-sysupgrade.bin"

(
  cd "$RELEASE_DIR"
  sha256sum flint3-full-factory.bin flint3-sysupgrade.bin > SHA256SUMS
)

printf 'Built Percival %s with the Flint 3 USB fixes.\n' "$OPENWRT_COMMIT"
