#!/usr/bin/env bash
set -Eeuo pipefail

TARGET_DIR="${1:?usage: validate-artifacts.sh <target-directory> <release-directory>}"
RELEASE_DIR="${2:?usage: validate-artifacts.sh <target-directory> <release-directory>}"

for command_name in dumpimage file find sha256sum; do
  command -v "$command_name" >/dev/null || {
    echo "Missing dependency: $command_name" >&2
    exit 1
  }
done

test -d "$TARGET_DIR"
mkdir -p "$RELEASE_DIR"

mapfile -t factory_files < <(
  find "$TARGET_DIR" -maxdepth 1 -type f \
    -name '*gl-be9300*factory*.bin' -print | sort
)
mapfile -t sysupgrade_files < <(
  find "$TARGET_DIR" -maxdepth 1 -type f \
    -name '*gl-be9300*sysupgrade*.bin' -print | sort
)
mapfile -t initramfs_files < <(
  find "$TARGET_DIR" -maxdepth 1 -type f \
    -name '*gl-be9300*initramfs*' -print | sort
)

if (( ${#factory_files[@]} != 1 )); then
  printf 'Expected exactly one GL-BE9300 factory image; found %d.\n' \
    "${#factory_files[@]}" >&2
  printf '%s\n' "${factory_files[@]:-}" >&2
  exit 1
fi

if (( ${#sysupgrade_files[@]} != 1 )); then
  printf 'Expected exactly one GL-BE9300 sysupgrade image; found %d.\n' \
    "${#sysupgrade_files[@]}" >&2
  printf '%s\n' "${sysupgrade_files[@]:-}" >&2
  exit 1
fi

factory_file="${factory_files[0]}"
sysupgrade_file="${sysupgrade_files[0]}"

test -s "$factory_file"
test -s "$sysupgrade_file"

factory_hash="$(sha256sum "$factory_file" | awk '{print $1}')"
sysupgrade_hash="$(sha256sum "$sysupgrade_file" | awk '{print $1}')"
if [[ "$factory_hash" == "$sysupgrade_hash" ]]; then
  echo "Factory and sysupgrade images unexpectedly have the same SHA256." >&2
  exit 1
fi

install -m 0644 "$factory_file" "$RELEASE_DIR/$(basename "$factory_file")"
install -m 0644 "$sysupgrade_file" "$RELEASE_DIR/$(basename "$sysupgrade_file")"

for initramfs_file in "${initramfs_files[@]}"; do
  test -s "$initramfs_file"
  install -m 0644 "$initramfs_file" "$RELEASE_DIR/$(basename "$initramfs_file")"
done

dumpimage -l "$factory_file" > "$RELEASE_DIR/factory-fit.txt"
grep -Eiq 'hlos' "$RELEASE_DIR/factory-fit.txt"
grep -Eiq 'rootfs' "$RELEASE_DIR/factory-fit.txt"

{
  file "$factory_file"
  file "$sysupgrade_file"
  for initramfs_file in "${initramfs_files[@]}"; do
    file "$initramfs_file"
  done
} > "$RELEASE_DIR/firmware-file-types.txt"

mapfile -t released_firmware < <(
  find "$RELEASE_DIR" -maxdepth 1 -type f \
    \( -name '*.bin' -o -name '*.itb' \) -print | sort
)

if (( ${#released_firmware[@]} < 2 )); then
  echo "Fewer than two firmware images reached the release directory." >&2
  exit 1
fi

(
  cd "$RELEASE_DIR"
  firmware_names=()
  for firmware_path in "${released_firmware[@]}"; do
    firmware_names+=("$(basename "$firmware_path")")
  done
  sha256sum "${firmware_names[@]}" > SHA256SUMS
  sha256sum -c SHA256SUMS
)

printf 'Validated %d firmware images.\n' "${#released_firmware[@]}"
