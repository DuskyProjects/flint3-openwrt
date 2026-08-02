#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/build.env"

OPENWRT_TREE="${1:?usage: prepare-backports.sh <openwrt-tree> <download-directory>}"
DOWNLOAD_DIR="${2:?usage: prepare-backports.sh <openwrt-tree> <download-directory>}"
MAC80211_MAKEFILE="$OPENWRT_TREE/package/kernel/mac80211/Makefile"
ARCHIVE_PATH="$DOWNLOAD_DIR/$BACKPORTS_ARCHIVE"

for command_name in git python3 sha256sum spatch tar zstd; do
  command -v "$command_name" >/dev/null || {
    echo "Missing dependency: $command_name" >&2
    exit 1
  }
done

test -f "$MAC80211_MAKEFILE"
upstream_version="$(sed -n 's/^PKG_UPSTREAM_VERSION:=//p' "$MAC80211_MAKEFILE" | head -n1)"
source_template="$(sed -n 's/^PKG_SOURCE:=//p' "$MAC80211_MAKEFILE" | head -n1)"
source_file="${source_template//\$\(PKG_UPSTREAM_VERSION\)/$upstream_version}"

test "$upstream_version" = "$BACKPORTS_KERNEL_VERSION"
test "$source_file" = "$BACKPORTS_ARCHIVE"

mkdir -p "$DOWNLOAD_DIR"

if [[ ! -s "$ARCHIVE_PATH" ]]; then
  temp_root="$(mktemp -d)"
  trap 'rm -rf "$temp_root"' EXIT

  backports_tree="$temp_root/backports"
  linux_tree="$temp_root/linux"
  output_root="$temp_root/output"
  generated_tree="$output_root/backports-$BACKPORTS_KERNEL_VERSION"

  git init -q "$backports_tree"
  git -C "$backports_tree" remote add origin "https://github.com/$BACKPORTS_REPOSITORY.git"
  git -C "$backports_tree" fetch --depth=1 --no-tags origin "$BACKPORTS_COMMIT"
  git -C "$backports_tree" checkout --detach --force FETCH_HEAD
  test "$(git -C "$backports_tree" rev-parse HEAD)" = "$BACKPORTS_COMMIT"

  git init -q "$linux_tree"
  git -C "$linux_tree" remote add origin "$BACKPORTS_LINUX_REPOSITORY"
  git -C "$linux_tree" fetch --depth=1 --no-tags origin "$BACKPORTS_LINUX_COMMIT"
  git -C "$linux_tree" checkout --detach --force FETCH_HEAD
  test "$(git -C "$linux_tree" rev-parse HEAD)" = "$BACKPORTS_LINUX_COMMIT"

  mkdir -p "$output_root"
  python3 "$backports_tree/gentree.py" --clean "$linux_tree" "$generated_tree"
  test -s "$generated_tree/Makefile"

  tar --sort=name --mtime='@0' --owner=0 --group=0 --numeric-owner \
    -C "$output_root" -cf - "backports-$BACKPORTS_KERNEL_VERSION" |
    zstd -q -10 -T0 -o "$ARCHIVE_PATH"
fi

archive_hash="$(sha256sum "$ARCHIVE_PATH" | awk '{print $1}')"
sed -i -E "s|^PKG_HASH:=.*$|PKG_HASH:=$archive_hash|" "$MAC80211_MAKEFILE"
grep -Fqx "PKG_HASH:=$archive_hash" "$MAC80211_MAKEFILE"

printf 'Prepared %s (%s)\n' "$BACKPORTS_ARCHIVE" "$archive_hash"
