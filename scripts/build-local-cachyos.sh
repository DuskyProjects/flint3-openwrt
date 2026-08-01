#!/usr/bin/env bash
set -Eeuo pipefail
umask 022

REPOSITORY="${REPOSITORY:-https://github.com/DuskyProjects/flint3-openwrt.git}"
BUILDER_REF="${BUILDER_REF:-main}"
STATE_ROOT="${STATE_ROOT:-$HOME/.cache/flint3-openwrt-local}"
BUILDER_DIR="$STATE_ROOT/builder"
NIGHTLY_ROOT="${NIGHTLY_ROOT:-$STATE_ROOT/nightly-work}"
EXPORT_DIR="${EXPORT_DIR:-/mnt/router/flint3-local-build}"
INSTALL_DEPS="${INSTALL_DEPS:-1}"
MIN_FREE_GIB="${MIN_FREE_GIB:-30}"

if (( EUID == 0 )); then
  echo "Do not run the OpenWrt build as root." >&2
  exit 1
fi

if [[ "$STATE_ROOT" == *' '* || "$BUILDER_DIR" == *' '* ]]; then
  echo "The OpenWrt build path must not contain spaces: $STATE_ROOT" >&2
  exit 1
fi

if ! command -v pacman >/dev/null 2>&1; then
  echo "This bootstrap script is for CachyOS/Arch systems using pacman." >&2
  exit 1
fi

if [[ "$INSTALL_DEPS" == 1 ]]; then
  # CachyOS uses zlib-ng-compat as the zlib ABI provider. Do not request the
  # conflicting Arch zlib package explicitly.
  sudo pacman -S --needed --noconfirm \
    base-devel bash bison ccache clang curl diffutils file findutils flex \
    gawk gettext git grep jq libelf ncurses openssl pahole patch perl \
    python python-pyelftools python-setuptools rsync sed swig tar unzip \
    util-linux wget which xz zstd
fi

required_commands=(
  awk bash bison ccache clang curl file findmnt flex gcc git jq make
  patch python3 rsync sha256sum swig tar unzip wget xz
)
for command_name in "${required_commands[@]}"; do
  command -v "$command_name" >/dev/null 2>&1 || {
    echo "Missing required command after dependency installation: $command_name" >&2
    exit 1
  }
done

mkdir -p "$STATE_ROOT" "$NIGHTLY_ROOT" "$STATE_ROOT/tmp"

available_kib="$(df -Pk "$STATE_ROOT" | awk 'NR == 2 { print $4 }')"
required_kib=$((MIN_FREE_GIB * 1024 * 1024))
if [[ -z "$available_kib" ]] || (( available_kib < required_kib )); then
  echo "At least ${MIN_FREE_GIB} GiB of free space is required under $STATE_ROOT." >&2
  exit 1
fi

if [[ "$EXPORT_DIR" == /mnt/router/* || "$EXPORT_DIR" == /mnt/router ]]; then
  if ! findmnt -T /mnt/router >/dev/null 2>&1; then
    echo "/mnt/router is not mounted. Mount the router share before building." >&2
    exit 1
  fi
fi
mkdir -p "$EXPORT_DIR"
test -w "$EXPORT_DIR" || {
  echo "Export directory is not writable: $EXPORT_DIR" >&2
  exit 1
}

if [[ -d "$BUILDER_DIR/.git" ]]; then
  git -C "$BUILDER_DIR" remote set-url origin "$REPOSITORY"
else
  rm -rf "$BUILDER_DIR"
  git clone --filter=blob:none --no-checkout "$REPOSITORY" "$BUILDER_DIR"
fi

git -C "$BUILDER_DIR" fetch --prune --depth=1 origin "$BUILDER_REF"
git -C "$BUILDER_DIR" checkout --detach --force FETCH_HEAD
git -C "$BUILDER_DIR" clean -ffd

unset SED GREP_OPTIONS
export TMPDIR="$STATE_ROOT/tmp"

if [[ -z "${JOBS:-}" ]]; then
  detected_jobs="$(nproc)"
  if (( detected_jobs > 8 )); then
    JOBS=8
  else
    JOBS="$detected_jobs"
  fi
fi

timestamp="$(date +%Y%m%d-%H%M%S)"
LOCAL_LOG="$STATE_ROOT/build-$timestamp.log"
FINAL_LOG="$EXPORT_DIR/build.log"

latest_attempt_log() {
  find "$NIGHTLY_ROOT/attempts" -mindepth 2 -maxdepth 2 -type f -name build.log \
    -printf '%T@\t%p\n' 2>/dev/null |
    sort -nr |
    head -n1 |
    cut -f2-
}

copy_log() {
  local source_log=''
  source_log="$(latest_attempt_log)"
  if [[ -z "$source_log" || ! -s "$source_log" ]]; then
    source_log="$LOCAL_LOG"
  fi
  if [[ -s "$source_log" ]]; then
    cp -f "$source_log" "$FINAL_LOG" 2>/dev/null || true
    chmod 0644 "$FINAL_LOG" 2>/dev/null || true
  fi
}
trap copy_log EXIT

set +e
(
  cd "$BUILDER_DIR"

  bash -n \
    scripts/apply-curated-patches.sh \
    scripts/build.sh \
    scripts/build-local-cachyos.sh \
    scripts/check-mac80211-source.sh \
    scripts/nightly-build.sh \
    scripts/nightly-or-reuse.sh \
    scripts/privacy-audit.sh \
    scripts/retain-flint3-ramoops.sh \
    scripts/self-test.sh \
    scripts/test-prepared-source-transfer.sh

  bash scripts/privacy-audit.sh
  bash scripts/self-test.sh
  bash scripts/test-prepared-source-transfer.sh

  env \
    JOBS="$JOBS" \
    NIGHTLY_ROOT="$NIGHTLY_ROOT" \
    DOWNLOAD_CACHE_DIR="$NIGHTLY_ROOT/dl" \
    CCACHE_DIR="$NIGHTLY_ROOT/ccache" \
    CCACHE_MAX_SIZE="${CCACHE_MAX_SIZE:-10G}" \
    bash scripts/nightly-build.sh
) 2>&1 | tee "$LOCAL_LOG"
build_status=${PIPESTATUS[0]}
set -e

copy_log

if (( build_status != 0 )); then
  echo "Build failed. Log saved to: $FINAL_LOG" >&2
  exit "$build_status"
fi

factory="$BUILDER_DIR/release/flint3-full-factory.bin"
sysupgrade="$BUILDER_DIR/release/flint3-sysupgrade.bin"
notes="$BUILDER_DIR/release-notes.md"

test -s "$factory"
test -s "$sysupgrade"
test -s "$notes"
test "$(find "$BUILDER_DIR/release" -maxdepth 1 -type f -name '*.bin' | wc -l)" -eq 2

install -m 0644 "$factory" "$EXPORT_DIR/flint3-full-factory.bin"
install -m 0644 "$sysupgrade" "$EXPORT_DIR/flint3-sysupgrade.bin"
install -m 0644 "$notes" "$EXPORT_DIR/release-notes.md"
(
  cd "$EXPORT_DIR"
  sha256sum flint3-full-factory.bin flint3-sysupgrade.bin > sha256sums.txt
)
chmod 0644 "$EXPORT_DIR/sha256sums.txt" "$FINAL_LOG"

echo
echo "Local Flint 3 build completed."
echo "Source:      Perceival Flint 3 tree plus curated USB/ramoops patches"
echo "Sysupgrade: $EXPORT_DIR/flint3-sysupgrade.bin"
echo "Factory:    $EXPORT_DIR/flint3-full-factory.bin"
echo "Checksums:  $EXPORT_DIR/sha256sums.txt"
echo "Log:        $FINAL_LOG"
echo
echo "Nothing was flashed and the router was not rebooted."
