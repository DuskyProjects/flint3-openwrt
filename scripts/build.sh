#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/build.env"

WORK_ROOT="${WORK_ROOT:-$ROOT/work}"
OPENWRT_TREE="$WORK_ROOT/openwrt"
RELEASE_DIR="${RELEASE_DIR:-$ROOT/release}"
PACKAGE_MANIFEST="${PACKAGE_MANIFEST:-$ROOT/config/dusky-full.packages}"
JOBS="${JOBS:-4}"

rm -rf "$OPENWRT_TREE" "$RELEASE_DIR"
mkdir -p "$OPENWRT_TREE" "$RELEASE_DIR"

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

usb_dts="$OPENWRT_TREE/target/linux/qualcommbe/dts/ipq5332-gl-be9300.dts"
test -f "$usb_dts"
grep -Fq '&usb {' "$usb_dts"
grep -Fq 'pinctrl-0 = <&usb_pins>;' "$usb_dts"
grep -Fq 'pinctrl-names = "default";' "$usb_dts"
grep -Fq 'qcom,multiplexed-phy;' "$usb_dts"

# IPQ5332 uses the built-in Qualcomm M31 USB PHY driver. There is no
# kmod-phy-qcom-uniphy-usb package in this source tree.
ipq53xx_kernel_config="$OPENWRT_TREE/target/linux/qualcommbe/ipq53xx/config-default"
test -f "$ipq53xx_kernel_config"
grep -Fqx 'CONFIG_PHY_QCOM_M31_USB=y' "$ipq53xx_kernel_config"

kernel_patch_dir="$OPENWRT_TREE/target/linux/qualcommbe/patches-6.18"
test -d "$kernel_patch_dir"
install -m 0644 \
  "$ROOT/patches/kernel/2989-dt-bindings-usb-qcom-document-multiplexed-phy.patch" \
  "$kernel_patch_dir/2989-dt-bindings-usb-qcom-document-multiplexed-phy.patch"
install -m 0644 \
  "$ROOT/patches/kernel/2990-usb-dwc3-qcom-flatten-ipq5332-and-select-phy-mux.patch" \
  "$kernel_patch_dir/2990-usb-dwc3-qcom-flatten-ipq5332-and-select-phy-mux.patch"

mac80211_makefile="$OPENWRT_TREE/package/kernel/mac80211/Makefile"
test -f "$mac80211_makefile"
grep -Fqx 'PKG_UPSTREAM_VERSION:=7.2-rc4' "$mac80211_makefile"
grep -Fqx 'PKG_HASH:=bd694978c0ae6cce318e02ca71189c28deb09e8d9ac3d3e8c18ca0ed264a728f' "$mac80211_makefile"

(
  cd "$OPENWRT_TREE"

  # OpenWrt feed hosts occasionally return transient 5xx errors. Re-running
  # the updater is safe: completed feeds are updated in place and a missing
  # feed (such as telephony after a failed clone) is cloned on the next pass.
  feed_attempts=4
  for attempt in $(seq 1 "$feed_attempts"); do
    echo "Updating OpenWrt feeds (attempt $attempt/$feed_attempts)..."
    if ./scripts/feeds update -a; then
      break
    fi

    if (( attempt == feed_attempts )); then
      echo "OpenWrt feeds still failed after $feed_attempts attempts." >&2
      exit 1
    fi

    delay=$((attempt * 15))
    echo "Feed update failed; retrying in ${delay}s..." >&2
    sleep "$delay"
  done

  ./scripts/feeds install -a

  cp "$ROOT/config.seed" .config
  bash "$ROOT/scripts/apply-package-manifest.sh" "$PACKAGE_MANIFEST" .config
  make defconfig
  bash "$ROOT/scripts/validate-package-manifest.sh" "$PACKAGE_MANIFEST" .config

  grep -Fq 'CONFIG_TARGET_qualcommbe_ipq53xx_DEVICE_glinet_gl-be9300=y' .config
  grep -Fq 'CONFIG_PACKAGE_iperf3=y' .config
  grep -Fq 'CONFIG_PACKAGE_kmod-usb-dwc3-qcom=y' .config

  # Enforce one implementation for each hardware/service role.
  forbidden_packages=(
    kmod-usb-dwc3-of-simple
    luci-app-samba4
    samba4-server
    luci-app-nextdns
    nextdns
  )

  for package in "${forbidden_packages[@]}"; do
    if grep -Eq "^CONFIG_PACKAGE_${package}=[ym]$" .config; then
      echo "Forbidden package selected: $package" >&2
      exit 1
    fi
  done

  # Use the archive and hash declared by Percival's source tree unchanged.
  make package/kernel/mac80211/download V=s
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
install -m 0644 "$PACKAGE_MANIFEST" "$RELEASE_DIR/dusky-full.packages"
install -m 0644 "$OPENWRT_TREE/.config" "$RELEASE_DIR/flint3-full.config"
(
  cd "$OPENWRT_TREE"
  ./scripts/diffconfig.sh > "$RELEASE_DIR/flint3-full.diffconfig"
)

(
  cd "$RELEASE_DIR"
  sha256sum flint3-full-factory.bin flint3-sysupgrade.bin > SHA256SUMS
)

printf 'Built Percival %s with Flint 3 USB power, ksmbd NAS, dnsproxy, and the validated Dusky package baseline.\n' "$OPENWRT_COMMIT"
