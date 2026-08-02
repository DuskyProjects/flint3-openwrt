#!/usr/bin/env bash
set -Eeuo pipefail

manifest="${1:?usage: validate-package-manifest.sh MANIFEST [CONFIG]}"
config="${2:-.config}"

[[ -f "$manifest" ]] || {
  echo "Package manifest not found: $manifest" >&2
  exit 1
}

[[ -f "$config" ]] || {
  echo "Resolved OpenWrt configuration not found: $config" >&2
  exit 1
}

trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

missing=()
disabled=()
wrong_value=()
verified=0

while IFS= read -r raw || [[ -n "$raw" ]]; do
  line="${raw%%#*}"
  package="$(trim "$line")"
  [[ -n "$package" ]] || continue

  symbol="CONFIG_PACKAGE_${package}"

  if grep -Fqx "${symbol}=y" "$config"; then
    ((verified += 1))
  elif grep -Fqx "# ${symbol} is not set" "$config"; then
    disabled+=("$package")
  elif grep -Eq "^${symbol}=" "$config"; then
    value="$(grep -E "^${symbol}=" "$config" | tail -n1)"
    wrong_value+=("$package ($value)")
  else
    missing+=("$package")
  fi
done < "$manifest"

if (( ${#missing[@]} || ${#disabled[@]} || ${#wrong_value[@]} )); then
  echo "Dusky package validation failed." >&2

  if (( ${#missing[@]} )); then
    echo "Missing package symbols; the package may have been renamed, removed, or its feed was not installed:" >&2
    printf '  %s\n' "${missing[@]}" >&2
  fi

  if (( ${#disabled[@]} )); then
    echo "Packages resolved but were not selected:" >&2
    printf '  %s\n' "${disabled[@]}" >&2
  fi

  if (( ${#wrong_value[@]} )); then
    echo "Packages resolved to an unexpected value:" >&2
    printf '  %s\n' "${wrong_value[@]}" >&2
  fi

  exit 1
fi

printf 'Verified %d Dusky packages in %s.\n' "$verified" "$config"
