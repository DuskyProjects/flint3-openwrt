#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
# shellcheck disable=SC1091
source "$PROJECT_ROOT/build.env"

SOURCE_TREE="${1:?usage: prepare-backports-source.sh <openwrt-tree> <download-cache> [manifest]}"
DOWNLOAD_CACHE="${2:?usage: prepare-backports-source.sh <openwrt-tree> <download-cache> [manifest]}"
MANIFEST="${3:-}"
MAKEFILE="$SOURCE_TREE/package/kernel/mac80211/Makefile"
ARCHIVE_PATH="$DOWNLOAD_CACHE/$BACKPORTS_ARCHIVE"
PROVENANCE_PATH="$ARCHIVE_PATH.provenance"
GENERATOR_VERSION=1

required_commands=(git python3 sha256sum spatch tar zstd)
for command_name in "${required_commands[@]}"; do
  command -v "$command_name" >/dev/null 2>&1 || {
    echo "Missing backports generation dependency: $command_name" >&2
    exit 1
  }
done

[[ -d "$SOURCE_TREE/.git" ]] || {
  echo "OpenWrt source is not a Git checkout: $SOURCE_TREE" >&2
  exit 1
}
[[ -f "$MAKEFILE" ]] || {
  echo "Missing mac80211 Makefile: $MAKEFILE" >&2
  exit 1
}

upstream_version="$(sed -n 's/^PKG_UPSTREAM_VERSION:=//p' "$MAKEFILE" | head -n1)"
source_file="$(sed -n 's/^PKG_SOURCE:=//p' "$MAKEFILE" | head -n1)"
source_file="${source_file//\$\(PKG_UPSTREAM_VERSION\)/$upstream_version}"

[[ "$upstream_version" == "$BACKPORTS_KERNEL_VERSION" ]] || {
  echo "Perceival mac80211 version changed: expected $BACKPORTS_KERNEL_VERSION, found $upstream_version" >&2
  exit 1
}
[[ "$source_file" == "$BACKPORTS_ARCHIVE" ]] || {
  echo "Perceival mac80211 archive changed: expected $BACKPORTS_ARCHIVE, found $source_file" >&2
  exit 1
}

mkdir -p "$DOWNLOAD_CACHE"

fingerprint="$({
  printf 'generator=%s\n' "$GENERATOR_VERSION"
  printf 'backports=%s@%s\n' "$BACKPORTS_REPOSITORY" "$BACKPORTS_COMMIT"
  printf 'linux=%s@%s\n' "$BACKPORTS_LINUX_REPOSITORY" "$BACKPORTS_LINUX_COMMIT"
  printf 'version=%s\n' "$BACKPORTS_KERNEL_VERSION"
} | sha256sum | awk '{print $1}')"

cache_valid=0
if [[ -s "$ARCHIVE_PATH" && -s "$PROVENANCE_PATH" ]]; then
  cached_fingerprint="$(sed -n 's/^fingerprint=//p' "$PROVENANCE_PATH" | head -n1)"
  [[ "$cached_fingerprint" == "$fingerprint" ]] && cache_valid=1
fi

if (( cache_valid == 0 )); then
  work_root="$(mktemp -d)"
  trap 'rm -rf "$work_root"' EXIT

  backports_tree="$work_root/backports"
  linux_tree="$work_root/linux"
  output_root="$work_root/output"
  generated_tree="$output_root/backports-$BACKPORTS_KERNEL_VERSION"
  temporary_archive="$work_root/$BACKPORTS_ARCHIVE"

  mkdir -p "$backports_tree" "$linux_tree" "$output_root"

  git -C "$backports_tree" init -q
  git -C "$backports_tree" remote add origin "https://github.com/$BACKPORTS_REPOSITORY.git"
  git -C "$backports_tree" fetch --depth=1 --no-tags origin "$BACKPORTS_COMMIT"
  git -C "$backports_tree" checkout --detach --force FETCH_HEAD
  [[ "$(git -C "$backports_tree" rev-parse HEAD)" == "$BACKPORTS_COMMIT" ]] || {
    echo "Backports generator did not resolve to the pinned commit." >&2
    exit 1
  }

  git -C "$linux_tree" init -q
  git -C "$linux_tree" remote add origin "$BACKPORTS_LINUX_REPOSITORY"
  git -C "$linux_tree" fetch --depth=1 --no-tags origin "$BACKPORTS_LINUX_COMMIT"
  git -C "$linux_tree" checkout --detach --force FETCH_HEAD
  [[ "$(git -C "$linux_tree" rev-parse HEAD)" == "$BACKPORTS_LINUX_COMMIT" ]] || {
    echo "Linux source did not resolve to the pinned commit." >&2
    exit 1
  }

  python3 "$backports_tree/gentree.py" --clean "$linux_tree" "$generated_tree"
  [[ -s "$generated_tree/Makefile" ]] || {
    echo "Backports generation did not produce a usable source tree." >&2
    exit 1
  }

  tar --sort=name --mtime='@0' --owner=0 --group=0 --numeric-owner \
    -C "$output_root" -cf - "backports-$BACKPORTS_KERNEL_VERSION" |
    zstd -q -19 -T0 -o "$temporary_archive"

  test -s "$temporary_archive"
  install -m 0644 "$temporary_archive" "$ARCHIVE_PATH"
  archive_hash="$(sha256sum "$ARCHIVE_PATH" | awk '{print $1}')"
  cat > "$PROVENANCE_PATH" <<PROVENANCE
fingerprint=$fingerprint
sha256=$archive_hash
backports=$BACKPORTS_REPOSITORY@$BACKPORTS_COMMIT
linux=$BACKPORTS_LINUX_REPOSITORY@$BACKPORTS_LINUX_COMMIT
version=$BACKPORTS_KERNEL_VERSION
PROVENANCE
  chmod 0644 "$PROVENANCE_PATH"
else
  archive_hash="$(sha256sum "$ARCHIVE_PATH" | awk '{print $1}')"
  recorded_hash="$(sed -n 's/^sha256=//p' "$PROVENANCE_PATH" | head -n1)"
  [[ "$archive_hash" == "$recorded_hash" ]] || {
    echo "Cached backports archive failed its provenance hash check." >&2
    exit 1
  }
fi

sed -i -E "s|^PKG_HASH:=.*$|PKG_HASH:=$archive_hash|" "$MAKEFILE"
grep -Fqx "PKG_HASH:=$archive_hash" "$MAKEFILE"

git -C "$SOURCE_TREE" add package/kernel/mac80211/Makefile
if ! git -C "$SOURCE_TREE" diff --cached --quiet; then
  git -C "$SOURCE_TREE" config user.name 'DuskyProjects Builder'
  git -C "$SOURCE_TREE" config user.email 'actions@users.noreply.github.com'
  git -C "$SOURCE_TREE" commit -m 'Use pinned generated backports source'
fi

if [[ -n "$MANIFEST" ]]; then
  mkdir -p "$(dirname "$MANIFEST")"
  cat > "$MANIFEST" <<MANIFEST_EOF
BACKPORTS SOURCE
archive=$BACKPORTS_ARCHIVE
sha256=$archive_hash
backports=$BACKPORTS_REPOSITORY@$BACKPORTS_COMMIT
linux=$BACKPORTS_LINUX_REPOSITORY@$BACKPORTS_LINUX_COMMIT
version=$BACKPORTS_KERNEL_VERSION
cache=$ARCHIVE_PATH
MANIFEST_EOF
fi

printf 'Prepared %s (%s)\n' "$BACKPORTS_ARCHIVE" "$archive_hash"
