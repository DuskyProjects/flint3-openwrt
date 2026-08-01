#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# A public firmware image must not contain a copied live-router configuration.
for path in \
  files/etc/config/wireless \
  files/etc/config/network \
  files/etc/config/dhcp \
  files/etc/config/firewall \
  files/etc/config/fstab \
  files/etc/config/samba4 \
  files/etc/config/upnpd
do
  if [[ -e "$PROJECT_ROOT/$path" ]]; then
    echo "Refusing to build with live router configuration file: $path" >&2
    exit 1
  fi
done

# Scan only content copied into the image, plus the package seed. The checks
# reject credentials, wireless identities, fixed client identifiers, account-
# scoped resolver URLs, private addressing and machine-specific mount paths.
PATTERNS=(
  'wireless\..*\.(ssid|key|macaddr)[[:space:]]*='
  '(^|[^[:alnum:]_])(ssid|psk|password|passphrase)[[:space:]]*='
  '([[:xdigit:]]{2}:){5}[[:xdigit:]]{2}'
  '(^|[^[:digit:]])10\.[[:digit:]]+\.[[:digit:]]+\.[[:digit:]]+'
  '(^|[^[:digit:]])192\.168\.[[:digit:]]+\.[[:digit:]]+'
  '(^|[^[:digit:]])172\.(1[6-9]|2[0-9]|3[01])\.[[:digit:]]+\.[[:digit:]]+'
  '(^|/)(mnt|media)/[^/]+/'
  '/tmp/[^/]*(mount|disk)[^/]*/'
  'https://[^[:space:]]*(dns|resolver)[^[:space:]]*/[[:alnum:]_-]{6,}'
)

failed=0
for pattern in "${PATTERNS[@]}"; do
  if grep -ERnIi -- "$pattern" \
      "$PROJECT_ROOT/config.seed" \
      "$PROJECT_ROOT/files" 2>/dev/null; then
    echo "Privacy audit matched a forbidden data pattern." >&2
    failed=1
  fi
done

if (( failed )); then
  echo "The firmware overlay contains user-specific data. Build stopped." >&2
  exit 1
fi

echo "Privacy audit passed: no live network or storage configuration is embedded."
