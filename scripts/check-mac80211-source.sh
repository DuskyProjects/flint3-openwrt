#!/usr/bin/env bash
set -euo pipefail

SOURCE_TREE="${1:?usage: check-mac80211-source.sh <openwrt-tree> [--print-only|--cache <dir>]}"
MODE="${2:-check}"
MAKEFILE="$SOURCE_TREE/package/kernel/mac80211/Makefile"

[[ -f "$MAKEFILE" ]] || {
  echo "Missing mac80211 Makefile: $MAKEFILE" >&2
  exit 1
}

upstream_version="$(sed -n 's/^PKG_UPSTREAM_VERSION:=//p' "$MAKEFILE" | head -n1)"
package_version="$(sed -n 's/^PKG_VERSION:=//p' "$MAKEFILE" | head -n1)"
source_url="$(sed -n 's/^PKG_SOURCE_URL:=//p' "$MAKEFILE" | head -n1)"
source_file="$(sed -n 's/^PKG_SOURCE:=//p' "$MAKEFILE" | head -n1)"
source_hash="$(sed -n 's/^PKG_HASH:=//p' "$MAKEFILE" | head -n1)"

version="$package_version"
[[ -n "$upstream_version" ]] && version="$upstream_version"
[[ -n "$version" && -n "$source_url" && -n "$source_file" && -n "$source_hash" ]] || {
  echo "Could not resolve mac80211 source metadata." >&2
  exit 1
}

source_url="${source_url//\$\(PKG_UPSTREAM_VERSION\)/$upstream_version}"
source_url="${source_url//\$\(PKG_VERSION\)/$version}"
source_file="${source_file//\$\(PKG_UPSTREAM_VERSION\)/$upstream_version}"
source_file="${source_file//\$\(PKG_VERSION\)/$version}"
archive_url="${source_url%/}/$source_file"

printf '%s\n' "$archive_url"
[[ "$MODE" == --print-only ]] && exit 0

if [[ "$MODE" == --cache ]]; then
  cache_dir="${3:?--cache requires a download-cache directory}"
  archive="$cache_dir/$source_file"
  [[ -s "$archive" ]] || {
    echo "Cached mac80211 source archive is missing: $archive" >&2
    exit 1
  }
  actual_hash="$(sha256sum "$archive" | awk '{print $1}')"
  [[ "$actual_hash" == "$source_hash" ]] || {
    echo "Cached mac80211 source hash mismatch: expected $source_hash, found $actual_hash" >&2
    exit 1
  }
  echo "Verified cached mac80211 source: $archive"
  exit 0
fi

[[ "$MODE" == check ]] || {
  echo "Unknown mode: $MODE" >&2
  exit 1
}

case "$archive_url" in
  http://*|https://*) ;;
  *)
    echo "Skipping remote preflight for non-HTTP source URL: $archive_url" >&2
    exit 0
    ;;
esac

curl --fail --silent --show-error --location --head \
  --retry 2 --retry-delay 2 --connect-timeout 15 --max-time 60 \
  "$archive_url" >/dev/null
