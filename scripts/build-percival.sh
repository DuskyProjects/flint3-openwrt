#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/source.lock"
# shellcheck disable=SC1090,SC1091
source "${SOURCE_ENV:-$ROOT/source.env}"

WORK_ROOT="${WORK_ROOT:-$ROOT/work}"
OPENWRT_TREE="${OPENWRT_TREE:-$WORK_ROOT/openwrt}"
DOWNLOAD_CACHE="${DOWNLOAD_CACHE:-$WORK_ROOT/dl}"
CCACHE_DIR="${CCACHE_DIR:-$WORK_ROOT/ccache}"
RELEASE_DIR="${RELEASE_DIR:-$ROOT/release}"
BUILD_JOBS="${BUILD_JOBS:-3}"
DOWNLOAD_JOBS="${DOWNLOAD_JOBS:-4}"
CCACHE_MAXSIZE="${CCACHE_MAXSIZE:-3G}"

export CCACHE_DIR CCACHE_MAXSIZE

for command_name in ccache find git grep make sha256sum; do
  command -v "$command_name" >/dev/null || {
    echo "Missing dependency: $command_name" >&2
    exit 1
  }
done

test -d "$OPENWRT_TREE/.git"
resolved_commit="$(git -C "$OPENWRT_TREE" rev-parse HEAD)"
if [[ "$resolved_commit" != "$SOURCE_COMMIT" ]]; then
  echo "Expected Percival commit $SOURCE_COMMIT, got $resolved_commit" >&2
  exit 1
fi

origin_url="$(git -C "$OPENWRT_TREE" remote get-url origin)"
expected_origin="https://github.com/${OPENWRT_REPOSITORY}.git"
if [[ "$origin_url" != "$expected_origin" ]]; then
  echo "Unexpected OpenWrt origin: $origin_url" >&2
  exit 1
fi

if ! git -C "$OPENWRT_TREE" diff --quiet --; then
  echo "Percival source has tracked modifications before the build." >&2
  exit 1
fi

rm -rf "$RELEASE_DIR"
mkdir -p "$RELEASE_DIR" "$DOWNLOAD_CACHE" "$CCACHE_DIR"
rm -rf "$OPENWRT_TREE/dl"
ln -s "$DOWNLOAD_CACHE" "$OPENWRT_TREE/dl"

retry_command() {
  local attempts="$1"
  local base_delay="$2"
  shift 2

  local attempt
  for ((attempt = 1; attempt <= attempts; attempt++)); do
    echo "Running attempt $attempt/$attempts: $*"
    if "$@"; then
      return 0
    fi

    if (( attempt == attempts )); then
      echo "Command failed after $attempts attempts: $*" >&2
      return 1
    fi

    sleep "$((attempt * base_delay))"
  done
}

(
  cd "$OPENWRT_TREE"

  retry_command 4 15 ./scripts/feeds update -a
  ./scripts/feeds install -a

  cp "$ROOT/configs/router.seed" .config
  make defconfig

  required_symbols=(
    CONFIG_TARGET_qualcommbe=y
    CONFIG_TARGET_qualcommbe_ipq53xx=y
    CONFIG_TARGET_qualcommbe_ipq53xx_DEVICE_glinet_gl-be9300=y
    CONFIG_TARGET_ROOTFS_SQUASHFS=y
    CONFIG_TARGET_ROOTFS_INITRAMFS=y
    CONFIG_PACKAGE_luci=y
    CONFIG_PACKAGE_iperf3=y
    CONFIG_PACKAGE_kmod-ramoops=y
  )

  for symbol in "${required_symbols[@]}"; do
    grep -Fqx "$symbol" .config || {
      echo "Required configuration symbol missing after defconfig: $symbol" >&2
      exit 1
    }
  done

  ./scripts/diffconfig.sh > "$RELEASE_DIR/flint3-build.diffconfig"

  : > "$RELEASE_DIR/feeds-lock.txt"
  for feed_path in feeds/*; do
    [[ -d "$feed_path/.git" ]] || continue
    printf '%s %s\n' \
      "$(basename "$feed_path")" \
      "$(git -C "$feed_path" rev-parse HEAD)" \
      >> "$RELEASE_DIR/feeds-lock.txt"
  done
  sort -o "$RELEASE_DIR/feeds-lock.txt" "$RELEASE_DIR/feeds-lock.txt"

  make download -j"$DOWNLOAD_JOBS"

  if find "$DOWNLOAD_CACHE" -type f -size 0 -print -quit | grep -q .; then
    echo "The download cache contains a zero-byte file." >&2
    find "$DOWNLOAD_CACHE" -type f -size 0 -print >&2
    exit 1
  fi

  while IFS= read -r -d '' downloaded_file; do
    if head -c 512 "$downloaded_file" | grep -Eiq '<!doctype[[:space:]]+html|<html'; then
      echo "Downloaded HTML instead of a source archive: $downloaded_file" >&2
      exit 1
    fi
  done < <(find "$DOWNLOAD_CACHE" -type f -print0)

  make -j"$BUILD_JOBS" V=s
)

if ! git -C "$OPENWRT_TREE" diff --quiet --; then
  echo "The build modified tracked files in Percival's source tree." >&2
  git -C "$OPENWRT_TREE" diff --stat >&2
  exit 1
fi

target_dir="$OPENWRT_TREE/bin/targets/qualcommbe/ipq53xx"
bash "$ROOT/scripts/validate-artifacts.sh" "$target_dir" "$RELEASE_DIR"

package_manifest="$(
  find "$target_dir" -maxdepth 1 -type f \
    -name '*gl-be9300*.manifest' -print -quit
)"
if [[ -n "$package_manifest" ]]; then
  install -m 0644 "$package_manifest" "$RELEASE_DIR/package-manifest.txt"
else
  echo "No target package manifest was produced." > "$RELEASE_DIR/package-manifest.txt"
fi

if [[ -f "$OPENWRT_TREE/README.md" ]]; then
  awk '
    /^## Known issues/ { capture = 1; next }
    capture && /^## / { exit }
    capture { print }
  ' "$OPENWRT_TREE/README.md" > "$RELEASE_DIR/upstream-known-issues.md"
fi

config_hash="$(sha256sum "$RELEASE_DIR/flint3-build.diffconfig" | awk '{print $1}')"

cat > "$RELEASE_DIR/SOURCE-COMMIT.txt" <<SOURCE
Repository: https://github.com/$OPENWRT_REPOSITORY
Expected branch: $OPENWRT_BRANCH
Source kind: $SOURCE_KIND
Source ref: $SOURCE_REF
Source tag: ${SOURCE_TAG:-none}
Source commit: $SOURCE_COMMIT
Source date: $SOURCE_DATE
Source title: $SOURCE_TITLE
SOURCE

cat > "$RELEASE_DIR/BUILD-MANIFEST.txt" <<MANIFEST
OpenWrt repository: $OPENWRT_REPOSITORY
OpenWrt branch policy: $OPENWRT_BRANCH
OpenWrt source kind: $SOURCE_KIND
OpenWrt source ref: $SOURCE_REF
OpenWrt source tag: ${SOURCE_TAG:-none}
OpenWrt source commit: $SOURCE_COMMIT
OpenWrt source date: $SOURCE_DATE
OpenWrt source title: $SOURCE_TITLE
Builder repository: ${GITHUB_REPOSITORY:-local}
Builder commit: ${GITHUB_SHA:-local}
Workflow run: ${GITHUB_RUN_ID:-local}
Runner OS: ${RUNNER_OS:-unknown}
Runner architecture: ${RUNNER_ARCH:-unknown}
Configuration SHA256: $config_hash
Build jobs: $BUILD_JOBS
Download jobs: $DOWNLOAD_JOBS
MANIFEST

ccache --show-stats || true
printf 'Built Percival %s without external patches.\n' "$SOURCE_COMMIT"
