#!/usr/bin/env bash
set -Eeuo pipefail

manifest="${1:?usage: apply-package-manifest.sh MANIFEST [CONFIG]}"
config="${2:-.config}"

[[ -f "$manifest" ]] || {
  echo "Package manifest not found: $manifest" >&2
  exit 1
}

[[ -f "$config" ]] || {
  echo "OpenWrt configuration not found: $config" >&2
  exit 1
}

trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

packages=()
while IFS= read -r raw || [[ -n "$raw" ]]; do
  line="${raw%%#*}"
  line="$(trim "$line")"
  [[ -n "$line" ]] || continue

  if [[ ! "$line" =~ ^[A-Za-z0-9][A-Za-z0-9+._-]*$ ]]; then
    echo "Invalid package name in $manifest: $line" >&2
    exit 1
  fi

  packages+=("$line")
done < "$manifest"

if (( ${#packages[@]} == 0 )); then
  echo "Package manifest contains no packages: $manifest" >&2
  exit 1
fi

mapfile -t duplicates < <(printf '%s\n' "${packages[@]}" | sort | uniq -d)
if (( ${#duplicates[@]} > 0 )); then
  printf 'Duplicate package entries in %s:\n' "$manifest" >&2
  printf '  %s\n' "${duplicates[@]}" >&2
  exit 1
fi

for package in "${packages[@]}"; do
  symbol="CONFIG_PACKAGE_${package}"

  if grep -Fq "${symbol}=y" "$config"; then
    continue
  fi

  if grep -Fq "# ${symbol} is not set" "$config"; then
    sed -i "s|^# ${symbol} is not set$|${symbol}=y|" "$config"
    continue
  fi

  if grep -Eq "^${symbol}=" "$config"; then
    sed -i "s|^${symbol}=.*$|${symbol}=y|" "$config"
    continue
  fi

  printf '%s=y\n' "$symbol" >> "$config"
done

printf 'Enabled %d packages from %s.\n' "${#packages[@]}" "$manifest"
