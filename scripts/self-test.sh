#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_ROOT/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

configure_git() {
  git -C "$1" config user.name 'Self Test'
  git -C "$1" config user.email 'self-test@example.invalid'
}

# The active builder has one source tree only. The old secondary-source
# configuration and scripts must remain absent.
test ! -e "$PROJECT_ROOT/patch-sources.conf"
test ! -e "$PROJECT_ROOT/source-overlays.conf"
test ! -e "$SCRIPT_ROOT/apply-source-overlays.sh"
test ! -e "$SCRIPT_ROOT/refresh-patches.sh"

grep -Fq 'perceival/openwrt-flint3' "$PROJECT_ROOT/build.env"
grep -Fq 'd90c181d96257c58ac370c19bbd640be7d9c0d76' "$PROJECT_ROOT/build.env"
grep -Fq 'd90c181d96257c58ac370c19bbd640be7d9c0d76' "$PROJECT_ROOT/source.required"
grep -Fq 'no-extra-ath12k-patches' "$SCRIPT_ROOT/nightly-build.sh"
grep -Fq 'External overlays: disabled' "$SCRIPT_ROOT/nightly-build.sh"
grep -Fq 'External patch intake: disabled' "$SCRIPT_ROOT/nightly-build.sh"

for path in \
  "$SCRIPT_ROOT/nightly-build.sh" \
  "$SCRIPT_ROOT/nightly-or-reuse.sh" \
  "$SCRIPT_ROOT/build-local-cachyos.sh"; do
  if grep -Eq 'KakatkarAkshay|OVERLAY_REPOSITORY|CONTROLLED_OVERLAY_COMMIT|patch-sources\.conf|source-overlays\.conf' "$path"; then
    echo "Secondary-source integration reference remains in $path" >&2
    exit 1
  fi
done

# mac80211 source URL parsing must support Perceival's upstream-version form.
source_tree="$TEST_ROOT/source"
mkdir -p "$source_tree/package/kernel/mac80211"
cat > "$source_tree/package/kernel/mac80211/Makefile" <<'MK'
PKG_UPSTREAM_VERSION:=7.2-rc4
PKG_VERSION:=$(subst -rc,_rc,$(PKG_UPSTREAM_VERSION))
PKG_SOURCE_URL:=https://github.com/openwrt/backports/releases/download/backports-v$(PKG_UPSTREAM_VERSION)
PKG_SOURCE:=backports-$(PKG_UPSTREAM_VERSION).tar.zst
MK
url="$(bash "$SCRIPT_ROOT/check-mac80211-source.sh" "$source_tree" --print-only)"
[[ "$url" == 'https://github.com/openwrt/backports/releases/download/backports-v7.2-rc4/backports-7.2-rc4.tar.zst' ]]

# Curated patches must migrate the board reference to the flat qcom DWC3 node
# and install only parseable kernel patches.
candidate="$TEST_ROOT/candidate"
mkdir -p "$candidate/target/linux/qualcommbe/dts"
git -C "$candidate" init -q -b main
configure_git "$candidate"
cat > "$candidate/target/linux/qualcommbe/dts/ipq5332-gl-be9300.dts" <<'DTS'
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
git -C "$candidate" add .
git -C "$candidate" commit -qm base

PROJECT_ROOT="$PROJECT_ROOT" bash "$SCRIPT_ROOT/apply-curated-patches.sh" \
  "$candidate" "$TEST_ROOT/curated-manifest.txt"

grep -q '^&usb {' "$candidate/target/linux/qualcommbe/dts/ipq5332-gl-be9300.dts"
grep -Fq 'qcom,multiplexed-phy;' "$candidate/target/linux/qualcommbe/dts/ipq5332-gl-be9300.dts"

binding_patch="$candidate/target/linux/qualcommbe/patches-6.18/2989-dt-bindings-usb-qcom-document-multiplexed-phy.patch"
usb_patch="$candidate/target/linux/qualcommbe/patches-6.18/2990-usb-dwc3-qcom-flatten-ipq5332-and-select-phy-mux.patch"
test -s "$binding_patch"
test -s "$usb_patch"
grep -Fq 'drivers/usb/dwc3/dwc3-qcom.c' "$usb_patch"
grep -Fq 'qcom,snps-dwc3' "$usb_patch"
grep -Fq 'regmap_write(tcsr, 0x10540, 0x1)' "$usb_patch"
! grep -Fq 'dwc3-qcom-legacy.c' "$usb_patch"

while IFS= read -r patch; do
  git -C "$candidate" apply --numstat "$patch" >/dev/null
done < <(find "$PROJECT_ROOT/patches" -type f -name '*.patch' -print | sort)

echo 'All Perceival-only builder self-tests passed.'
