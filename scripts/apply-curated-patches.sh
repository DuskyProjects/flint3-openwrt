#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
SOURCE_TREE="${1:?usage: apply-curated-patches.sh <openwrt-tree> <manifest>}"
MANIFEST="${2:?usage: apply-curated-patches.sh <openwrt-tree> <manifest>}"
SOURCE_PATCH_DIR="$PROJECT_ROOT/patches/openwrt-source"
KERNEL_PATCH_DIR="$PROJECT_ROOT/patches/qualcommbe-6.18"
KERNEL_TARGET_DIR="$SOURCE_TREE/target/linux/qualcommbe/patches-6.18"
RAMOOPS_HELPER="$PROJECT_ROOT/scripts/retain-flint3-ramoops.sh"
BOARD_DTS="$SOURCE_TREE/target/linux/qualcommbe/dts/ipq5332-gl-be9300.dts"

[[ -d "$SOURCE_TREE/.git" ]] || {
  echo "OpenWrt source is not a Git checkout: $SOURCE_TREE" >&2
  exit 1
}

mkdir -p "$(dirname "$MANIFEST")" "$KERNEL_TARGET_DIR"
: > "$MANIFEST"
printf 'CURATED PATCH MANIFEST\n' >> "$MANIFEST"
printf 'candidate-before=%s\n\n' "$(git -C "$SOURCE_TREE" rev-parse HEAD)" >> "$MANIFEST"

if [[ -s "$RAMOOPS_HELPER" ]]; then
  bash -n "$RAMOOPS_HELPER"
  bash "$RAMOOPS_HELPER" "$SOURCE_TREE" "$MANIFEST"
elif [[ -f "$BOARD_DTS" ]] && grep -Fq 'q6_caldb: q6-caldb@4d500000 {' "$BOARD_DTS"; then
  echo "Missing Flint 3 ramoops helper: $RAMOOPS_HELPER" >&2
  exit 1
else
  # The full orchestration self-test copies this script into a deliberately
  # minimal source tree without the complete Flint reserved-memory layout.
  printf 'RAMOOPS-SKIPPED\tminimal isolated test tree\n' >> "$MANIFEST"
fi

source_applied=0
source_already=0
kernel_installed=0
kernel_already=0

if compgen -G "$SOURCE_PATCH_DIR/*.patch" >/dev/null; then
  for patch in "$SOURCE_PATCH_DIR"/*.patch; do
    relative="${patch#$PROJECT_ROOT/}"
    hash="$(sha256sum "$patch" | awk '{print $1}')"

    if git -C "$SOURCE_TREE" apply --check "$patch"; then
      git -C "$SOURCE_TREE" apply --index "$patch"
      printf 'SOURCE-APPLIED\t%s\t%s\n' "$hash" "$relative" >> "$MANIFEST"
      source_applied=$((source_applied + 1))
    elif git -C "$SOURCE_TREE" apply --reverse --check "$patch"; then
      printf 'SOURCE-ALREADY\t%s\t%s\n' "$hash" "$relative" >> "$MANIFEST"
      source_already=$((source_already + 1))
    else
      printf 'SOURCE-CONFLICT\t%s\t%s\n' "$hash" "$relative" >> "$MANIFEST"
      echo "Curated OpenWrt source patch does not apply cleanly: $relative" >&2
      exit 1
    fi
  done
fi

if compgen -G "$KERNEL_PATCH_DIR/*.patch" >/dev/null; then
  for patch in "$KERNEL_PATCH_DIR"/*.patch; do
    relative="${patch#$PROJECT_ROOT/}"
    dest="$KERNEL_TARGET_DIR/$(basename "$patch")"
    hash="$(sha256sum "$patch" | awk '{print $1}')"

    # Kernel patches are copied into OpenWrt's quilt series and are not applied
    # at this stage. Parse them explicitly so malformed hunk counts fail before
    # an expensive kernel preparation or compilation begins.
    if ! git -C "$SOURCE_TREE" apply --numstat "$patch" >/dev/null; then
      printf 'KERNEL-CORRUPT\t%s\t%s\n' "$hash" "$relative" >> "$MANIFEST"
      echo "Curated kernel patch is malformed: $relative" >&2
      exit 1
    fi

    if [[ -e "$dest" ]]; then
      if ! cmp -s "$patch" "$dest"; then
        printf 'KERNEL-CONFLICT\t%s\t%s\n' "$hash" "$relative" >> "$MANIFEST"
        echo "A different kernel patch already uses $(basename "$patch")." >&2
        exit 1
      fi
      printf 'KERNEL-ALREADY\t%s\t%s\n' "$hash" "$relative" >> "$MANIFEST"
      kernel_already=$((kernel_already + 1))
      continue
    fi

    install -m 0644 "$patch" "$dest"
    git -C "$SOURCE_TREE" add -- "${dest#$SOURCE_TREE/}"
    printf 'KERNEL-INSTALLED\t%s\t%s\n' "$hash" "$relative" >> "$MANIFEST"
    kernel_installed=$((kernel_installed + 1))
  done
fi

if ! git -C "$SOURCE_TREE" diff --cached --quiet; then
  git -C "$SOURCE_TREE" config user.name 'DuskyProjects Builder'
  git -C "$SOURCE_TREE" config user.email 'actions@users.noreply.github.com'
  git -C "$SOURCE_TREE" commit -m 'Apply curated Flint 3 patches'
fi

printf '\nSUMMARY source-applied=%d source-already=%d kernel-installed=%d kernel-already=%d\n' \
  "$source_applied" "$source_already" "$kernel_installed" "$kernel_already" >> "$MANIFEST"
printf 'candidate-after=%s\n' "$(git -C "$SOURCE_TREE" rev-parse HEAD)" >> "$MANIFEST"

echo "Curated patches applied: source=$source_applied kernel=$kernel_installed"
